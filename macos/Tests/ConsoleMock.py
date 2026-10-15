"""Local RFB fixtures. All listeners are private Unix sockets; no VM is launched."""

from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import time

HARNESS = sys.argv[1]
WORK = Path(sys.argv[2])
TEST_FILTER = sys.argv[3] if len(sys.argv) > 3 else None


class Peer:
    def __init__(self, connection):
        self.connection = connection
        connection.settimeout(8)

    def read(self, count):
        data = b""
        while len(data) < count:
            chunk = self.connection.recv(count - len(data))
            assert chunk, "Client unexpectedly disconnected"
            data += chunk
        return data

    def send(self, data):
        # Fragment headers and pixel rows to exercise exact reads.
        for offset in range(0, len(data), 3):
            self.connection.sendall(data[offset : offset + 3])

    def handshake(self, version=8, width=2, height=2, expect_initial_request=True):
        banner = f"RFB 003.{version:03}\n".encode()
        self.send(banner)
        assert self.read(12) == banner
        if version == 3:
            self.send(struct.pack(">I", 1))
        else:
            self.send(b"\x02\x02\x01")
            assert self.read(1) == b"\x01", "Client did not choose None authentication"
            if version == 8:
                self.send(bytes(4))
        assert self.read(1) == b"\x01", "Expected shared ClientInit"
        self.send(struct.pack(">HH", width, height) + bytes(16) + struct.pack(">I", 4) + b"test")
        assert self.read(20) == bytes(
            [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        ), "Wrong client RGB888 pixel format"
        assert self.read(16) == struct.pack(">BBHiii", 2, 0, 3, 0, -223, -224
        ), "Wrong advertised encodings"
        if expect_initial_request:
            self.request(width, height, incremental=False)

    def request(self, width, height, incremental=True):
        assert self.read(10) == struct.pack(">BBHHHH", 3, int(incremental), 0, 0, width, height
        ), "Framebuffer request has the wrong size/incremental flag"

    def update(self, rectangles):
        self.send(struct.pack(">BBH", 0, 0, len(rectangles)) + b"".join(rectangles))

    def eof(self):
        assert self.connection.recv(1) == b"", "Client failed to close its display socket"

    def cancelled_initial_request(self, width, height):
        # onReady is emitted after complete protocol negotiation, immediately
        # before the initial update request. Cancellation can win that race, or
        # interrupt the write. Permit only a valid request prefix followed by
        # EOF here; all handshake reads and every other fixture remain strict.
        expected = struct.pack(">BBHHHH", 3, 0, 0, 0, width, height)
        received = b""
        while True:
            chunk = self.connection.recv(len(expected) + 1 - len(received))
            if not chunk:
                return
            received += chunk
            assert expected.startswith(received), "Unexpected bytes during initial-request cancellation"


def rectangle(x, y, width, height, encoding, pixels=b""):
    return struct.pack(">HHHHi", x, y, width, height, encoding) + pixels


def listener(path):
    path.unlink(missing_ok=True)
    server = socket.socket(socket.AF_UNIX)
    server.settimeout(10)
    server.bind(str(path))
    server.listen(1)
    return server


def run_fixture(name, mode, fixture, *arguments):
    if TEST_FILTER and TEST_FILTER != name:
        return
    path = WORK / f"{name}.sock"
    server = listener(path)
    errors = []

    def serve():
        try:
            connection, _ = server.accept()
            with connection:
                fixture(Peer(connection))
        except BaseException as error:
            errors.append(error)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        try:
            result = subprocess.run(
                [HARNESS, mode, str(path), *arguments], capture_output=True, text=True, timeout=15
            )
        except subprocess.TimeoutExpired:
            # A failed native precondition may spend time producing a crash
            # backtrace. Preserve the peer's earlier causal wire mismatch.
            if errors:
                raise AssertionError(f"{name}: {errors!r}") from None
            raise
        thread.join(timeout=9)
        assert not thread.is_alive(), f"{name}: mock server did not finish"
        assert not errors, f"{name}: {errors!r}"
        assert result.returncode == 0, f"{name}: {result.stderr}"
        print(f"{name}: {result.stdout.strip()}", flush=True)
    finally:
        server.close()
        path.unlink(missing_ok=True)


def protocol(peer, version):
    peer.handshake(version)
    raw = bytes([0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0])
    peer.update([
        rectangle(0, 0, 2, 1, 0, raw[:8]),
        rectangle(0, 1, 2, 1, 0, raw[8:]),  # Full-width contiguous read at a nonzero row.
        rectangle(1, 0, 1, 2, 0, raw[4:8] + raw[12:16]),  # Partial-width row stride.
    ])
    events = set()
    while len(events) < 6:
        kind = peer.read(1)[0]
        if kind == 3:
            assert peer.read(9) == bytes([1, 0, 0, 0, 0, 0, 2, 0, 2])
            events.add("request")
        elif kind == 4:
            message = peer.read(7)
            assert message[1:] == bytes([0, 0, 0, 0, 255, 13])
            events.add("key-down" if message[0] else "key-up")
        elif kind == 5:
            message = peer.read(5)
            assert message[1:] == bytes([0, 1, 0, 1])
            events.add("mouse-down" if message[0] else "mouse-up")
        elif kind == 6:
            assert peer.read(7) == bytes([0, 0, 0, 0, 0, 0, 5])
            assert peer.read(5) == b"hello"
            events.add("clipboard")
        else:
            raise AssertionError(f"Unexpected client message {kind}")
    peer.update([
        rectangle(0, 0, 3, 1, -223),
        rectangle(1, 0, 1, 1, 0, bytes([7, 8, 9, 0])),
        rectangle(0, 0, 0, 0, -224),
    ])
    peer.request(3, 1, incremental=False)
    peer.send(bytes([3, 0, 0, 0]) + struct.pack(">I", 5) + b"guest")
    peer.eof()


for rfb_version in (8, 7, 3):
    run_fixture(f"RFB-3.{rfb_version}", "protocol", lambda peer, v=rfb_version: protocol(peer, v))

bad_messages = [
    ("dimensions", struct.pack(">BBH", 0, 0, 1) + rectangle(0, 0, 65535, 65535, -223)),
    ("bounds", struct.pack(">BBH", 0, 0, 1) + rectangle(1, 0, 2, 2, 0)),
    ("encoding", struct.pack(">BBH", 0, 0, 1) + rectangle(0, 0, 2, 2, 16)),
    ("clipboard", bytes([3, 0, 0, 0]) + struct.pack(">I", 1024 * 1024 + 1)),
]
for expected, payload in bad_messages:
    def bad(peer, message=payload):
        peer.handshake()
        peer.send(message)
        peer.eof()
    run_fixture(f"reject-{expected}", "bad", bad, expected)


def cancel(peer):
    peer.handshake(expect_initial_request=False)
    peer.cancelled_initial_request(2, 2)


def check_cancel_reader():
    expected = struct.pack(">BBHHHH", 3, 0, 0, 0, 2, 2)
    for payload, valid in [(b"", True), (expected[:4], True), (expected, True),
                           (b"\x03\x01", False), (expected + b"\x00", False)]:
        receiver, sender = socket.socketpair(socket.AF_UNIX)
        with receiver, sender:
            sender.sendall(payload)
            sender.shutdown(socket.SHUT_WR)
            rejected = False
            try:
                Peer(receiver).cancelled_initial_request(2, 2)
            except AssertionError:
                rejected = True
            assert rejected != valid, "Cancellation reader accepted malformed data or rejected a valid prefix"
    receiver, sender = socket.socketpair(socket.AF_UNIX)
    with receiver, sender:
        sender.sendall(b"\x03")
        sender.shutdown(socket.SHUT_WR)
        try:
            Peer(receiver).read(2)
        except AssertionError as error:
            assert "unexpectedly disconnected" in str(error)
        else:
            raise AssertionError("Strict reads stopped rejecting unexpected EOF")


check_cancel_reader()


run_fixture("cancel", "bad", cancel, "cancel")


def focus(peer):
    peer.handshake(width=4, height=4)
    peer.update([rectangle(0, 0, 4, 4, 0, bytes(64))])
    events = set()
    while len(events) < 7:
        kind = peer.read(1)[0]
        if kind == 3:
            assert peer.read(9) == struct.pack(">BHHHH", 1, 0, 0, 4, 4)
            events.add("request")
        elif kind == 4:
            message = peer.read(7)
            down, _, _, keysym = struct.unpack(">BBB I", message)
            assert keysym in (ord("a"), 0xFFE3), f"Wrong focus test keysym {keysym}"
            events.add((keysym, bool(down)))
        elif kind == 5:
            buttons, x, y = struct.unpack(">BHH", peer.read(5))
            # A square 4x4 guest is letterboxed into a 300x200 view. Window point
            # (90,150) maps to top-origin guest pixel (0,1), not bounds-scaled (1,1).
            assert (x, y) == (0, 1), "Aspect-fit pointer coordinates or vertical origin are wrong"
            assert buttons in (0, 1)
            events.add(("pointer", buttons))
        else:
            raise AssertionError(f"Unexpected focus client message {kind}")
    peer.update([rectangle(0, 0, 3, 1, -223)])
    peer.request(3, 1, incremental=False)
    peer.eof()


run_fixture("focus", "focus", focus)


def modifier_events(peer, expected):
    peer.handshake(width=4, height=4)
    peer.update([rectangle(0, 0, 4, 4, 0, bytes(64))])
    received = []
    while len(received) < len(expected):
        kind = peer.read(1)[0]
        if kind == 3:
            assert peer.read(9) == struct.pack(">BHHHH", 1, 0, 0, 4, 4)
            continue
        assert kind == 4, f"Unexpected modifier client message {kind}"
        down, _, _, keysym = struct.unpack(">BBBI", peer.read(7))
        received.append((keysym, bool(down)))
        assert received[-1] == expected[len(received) - 1], (
            f"Wrong modifier wire sequence: expected {expected}, received {received}"
        )
    peer.update([rectangle(0, 0, 3, 1, -223)])
    # Any extra/duplicate key event here fails the framebuffer request check.
    peer.request(3, 1, incremental=False)
    peer.eof()


LC, RC, C, X = 0xFFE3, 0xFFE4, ord("c"), ord("x")
control_chord = [(LC, True), (C, True), (C, False), (LC, False)]
modifier_scenarios = {
    "missing-control": control_chord,
    "missing-release": control_chord + [(X, True), (X, False)],
    "normal-duplicate": control_chord,
    "late-flags": control_chord,
    "left-right": [(LC, True), (RC, True), (LC, False), (C, True), (C, False), (RC, False)],
    "right-without-flags": [(RC, True), (C, True), (C, False), (RC, False)],
    "handoff-right": [(LC, True), (C, True), (RC, True), (LC, False), (C, False), (RC, False)],
    "aggregate-both-duplicate": [(LC, True), (RC, True), (C, True), (C, False), (LC, False), (RC, False)],
    "all-sides": [
        event
        for left, right in [(0xFFE1, 0xFFE2), (LC, RC), (0xFFE9, 0xFFEA), (0xFFEB, 0xFFEC)]
        for event in [(left, True), (right, True), (left, False), (X, True), (X, False), (right, False)]
    ],
    "focus-fallback": control_chord,
    "all-modifiers": [
        event
        for modifier, letter in [(LC, X), (0xFFE1, ord("X")), (0xFFE9, X), (0xFFEB, X)]
        for event in [(modifier, True), (letter, True), (letter, False), (modifier, False)]
    ],
}
for scenario, sequence in modifier_scenarios.items():
    run_fixture("modifiers-" + scenario, "modifiers", lambda peer, expected=sequence: modifier_events(peer, expected), scenario)


def run_reconnect():
    path = WORK / "reconnect.sock"
    initial = listener(path)
    errors = []

    def serve():
        replacement = None
        try:
            connection, _ = initial.accept()
            with connection:
                peer = Peer(connection)
                peer.handshake(width=2, height=1)
                peer.update([rectangle(0, 0, 2, 1, 0, bytes(8))])
                peer.request(2, 1)
                time.sleep(0.15)
            initial.close()
            path.unlink()
            # Make the first reconnect fail against a missing path, as when QEMU
            # is stopped and its replacement has not opened its VNC socket yet.
            time.sleep(1.3)
            replacement = listener(path)
            connection, _ = replacement.accept()
            with connection:
                peer = Peer(connection)
                peer.handshake(width=3, height=1)
                peer.update([rectangle(0, 0, 3, 1, 0, bytes(12))])
                peer.request(3, 1)
                peer.eof()
        except BaseException as error:
            errors.append(error)
        finally:
            if replacement:
                replacement.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        result = subprocess.run(
            [HARNESS, "reconnect", str(path)], capture_output=True, text=True, timeout=15
        )
        thread.join(timeout=9)
        assert not thread.is_alive(), "Reconnect server did not finish"
        assert result.returncode == 0, result.stderr
        assert not errors, repr(errors)
        print(result.stdout.strip(), flush=True)
    finally:
        initial.close()
        path.unlink(missing_ok=True)


if TEST_FILTER is None or TEST_FILTER == "reconnect":
    run_reconnect()
if TEST_FILTER is None or TEST_FILTER == "drawing":
    subprocess.run([HARNESS, "drawing"], check=True, timeout=10)
print("All native console tests passed.", flush=True)

"""Local RFB fixtures. All listeners are private Unix sockets; no VM is launched."""

from pathlib import Path
import json
import os
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
        assert self.read(20) == struct.pack(">BBHiiii", 2, 0, 4, 0, -223, -224, -308
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


def run_fixture(name, mode, fixture, *arguments, input_diagnostics=False):
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
        environment = os.environ.copy()
        if input_diagnostics:
            environment["PERPENDICULAR_INPUT_DIAGNOSTICS"] = "1"
        try:
            result = subprocess.run(
                [HARNESS, mode, str(path), *arguments], capture_output=True, text=True, timeout=15, env=environment
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
        if input_diagnostics:
            check_input_diagnostics(result.stderr)
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
    ("layout", struct.pack(">BBH", 0, 0, 1) + rectangle(0, 0, 2, 2, -308, bytes([17, 0, 0, 0]))),
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
    "synthetic-option-shortcut": [(0xFFE9, True), (ord("f"), True), (ord("f"), False), (0xFFE9, False)],
    "synthetic-option-tap": [(0xFFE9, True), (0xFFE9, False)],
    "control-symbol": [(LC, True), (ord("/"), True), (ord("/"), False), (LC, False)],
    "right-shift-symbol": [(0xFFE2, True), (ord("7"), True), (ord("7"), False), (0xFFE2, False)],
}
for scenario, sequence in modifier_scenarios.items():
    run_fixture("modifiers-" + scenario, "modifiers", lambda peer, expected=sequence: modifier_events(peer, expected), scenario)


def application_release_events(peer, expected, flood=False):
    peer.handshake(width=4, height=4)
    peer.update([rectangle(0, 0, 4, 4, 0, bytes(64))])
    stopped = threading.Event()
    flood_errors = []
    def send_frames():
        try:
            for _ in range(300):
                if stopped.is_set(): break
                peer.update([rectangle(0, 0, 1, 1, 0, bytes([0, 0, 255, 0]))])
                time.sleep(0.001)
        except BaseException as error: flood_errors.append(error)
    sender = threading.Thread(target=send_frames, daemon=True) if flood else None
    if sender: sender.start()
    received = []
    try:
        while len(received) < len(expected):
            kind = peer.read(1)[0]
            if kind == 3:
                assert peer.read(9) == struct.pack(">BHHHH", 1, 0, 0, 4, 4)
                continue
            assert kind == 4, f"Unexpected input client message {kind}"
            down, _, _, keysym = struct.unpack(">BBBI", peer.read(7))
            received.append((keysym, bool(down)))
            assert received[-1] == expected[len(received)-1], (expected, received)
    finally:
        stopped.set()
        if sender: sender.join(timeout=2)
    assert not flood_errors and (sender is None or not sender.is_alive()), flood_errors
    peer.update([rectangle(0, 0, 3, 1, -223)])
    while True:
        assert peer.read(1) == b"\x03", "Duplicate or additional key event after the expected text"
        request = peer.read(9)
        if request == struct.pack(">BHHHH", 0, 0, 0, 3, 1): break
        assert request == struct.pack(">BHHHH", 1, 0, 0, 4, 4)
    peer.eof()


command_r = [(0xFFEB, True), (ord("r"), True), (ord("r"), False), (0xFFEB, False)]
burst = list(command_r)
for character in "powershell.exe -NoProfile":
    if character.isupper(): burst.append((0xFFE1, True))
    burst += [(ord(character), True), (ord(character), False)]
    if character.isupper(): burst.append((0xFFE1, False))
burst += [(0xFFE1, True), (0xFFE3, True), (0xFF0D, True), (0xFF0D, False), (0xFFE1, False), (0xFFE3, False)]
for scenario, sequence in {"command-release": command_r, "window-scope": command_r,
                           "duplicate-release": [(ord("r"), True), (ord("r"), False)], "text-burst": burst}.items():
    run_fixture("application-"+scenario, "application-release",
                lambda peer, expected=sequence, flood=scenario=="text-burst": application_release_events(peer, expected, flood), scenario)


def recorded_keyboard_sequence(layout):
    # Normative Windows key locations, independent of the Swift lookup table.
    # These cover every symbol from the approved real CUA capture. In Italian,
    # slash is Shift+7, star is Shift+plus, and brackets use the e-grave/plus
    # physical locations with Right Alt rather than QEMU's ambiguous XKB aliases.
    shift, right_alt = 0xFFE1, 0xFFEA
    if layout == "it":
        symbols = [(ord("7"), [shift]), (ord("+"), [shift]),
                   (0xE8, [shift, right_alt]), (ord("+"), [shift, right_alt]),
                   (0xE8, [right_alt]), (ord("+"), [right_alt]),
                   (0xF2, [right_alt]), (0xE0, [right_alt]),
                   (ord("5"), []), (ord("2"), [shift])]
    else:
        symbols = [(ord("/"), []), (ord("8"), [shift]),
                   (ord("["), [shift]), (ord("]"), [shift]),
                   (ord("["), []), (ord("]"), []),
                   (ord("2"), [shift]), (ord("3"), [shift]),
                   (ord("5"), []), (ord("'"), [shift])]
    sequence = list(burst)
    for index, (base, modifiers) in enumerate(symbols):
        # There is no space between the final 5 and double quote.
        if index and index != len(symbols)-1:
            sequence += [(ord(" "), True), (ord(" "), False)]
        sequence += [(modifier, True) for modifier in modifiers]
        sequence += [(base, True), (base, False)]
        sequence += [(modifier, False) for modifier in reversed(modifiers)]
    sequence += [(0xFFEB, True), (ord("q"), True), (ord("q"), False), (0xFFEB, False)]
    return sequence


def check_input_diagnostics(stderr):
    reports = [json.loads(line.removeprefix("input_diagnostics "))
               for line in stderr.splitlines() if line.startswith("input_diagnostics ")]
    assert reports, "Opt-in input summaries were never emitted"
    allowed = {"generation", "duration_ms", "application_down", "application_up", "application_flags",
               "responder_down", "responder_up", "responder_flags", "responder_repeat", "unmatched_up",
               "accepted_down", "accepted_up", "written_down", "written_up", "queue_overflow",
               "queue_peak_messages", "queue_peak_bytes", "queue_max_wait_us", "pointer_coalesced",
               "application_min_gap_us", "application_max_gap_us", "wire_min_gap_us", "wire_max_gap_us"}
    for report in reports:
        assert set(report).issubset(allowed), "Input diagnostics exposed non-metric fields"
        assert all(type(value) is int and value >= 0 for value in report.values()), "Input diagnostics exposed non-numeric data"
    def total(field): return sum(report.get(field, 0) for report in reports)
    recording = json.loads(Path(__file__).with_name("KeyboardEventFixtures.json").read_text())["events"]
    expected = recorded_keyboard_sequence("it")
    assert total("responder_down") == sum(event["kind"] == 10 for event in recording)
    assert total("application_up") == total("responder_up") == sum(event["kind"] == 11 for event in recording)
    assert total("responder_flags") == sum(event["kind"] == 12 for event in recording)
    # This fixture deliberately calls down/flags directly while actual key-ups
    # pass through NSApplication. Diagnostics must retain that distinction.
    assert total("application_down") == 0 and total("application_flags") == 0
    assert total("accepted_down") == total("written_down") == sum(down for _, down in expected)
    assert total("accepted_up") == total("written_up") == sum(not down for _, down in expected)
    assert total("unmatched_up") == total("queue_overflow") == 0


for layout in ("it", "en-us"):
    run_fixture("recorded-keyboard-" + layout, "recorded-keyboard",
                lambda peer, expected=recorded_keyboard_sequence(layout): application_release_events(peer, expected),
                str(Path(__file__).with_name("KeyboardEventFixtures.json")), layout)

run_fixture("input-diagnostics", "recorded-keyboard",
            lambda peer: application_release_events(peer, recorded_keyboard_sequence("it")),
            str(Path(__file__).with_name("KeyboardEventFixtures.json")), "it", input_diagnostics=True)


def rapid_keyboard(peer):
    peer.handshake()
    count = 440
    arrivals = []
    for index in range(count):
        assert peer.read(1) == b"\x04", "Input writer reordered or dropped a key transition"
        down, _, _, keysym = struct.unpack(">BBBI", peer.read(7))
        assert (keysym, bool(down)) == (ord("5"), index % 2 == 0), "Burst lost an ordered down/up"
        arrivals.append(time.monotonic())
    # QEMU 11.1.2 ui/input.c bounds its delayed queue at 1024 nodes. Each queued
    # key transition occupies EVENT + SYNC + DELAY, serviced at the default VNC
    # key-delay-ms=10. Model that finite bottleneck from actual socket arrivals;
    # this is a source-derived regression, not a claim of guest runtime success.
    pending, next_service, dropped, peak = 0, arrivals[0], 0, 0
    for arrived in arrivals:
        while pending and next_service <= arrived:
            pending -= 1
            next_service += 0.010
        if not pending:
            next_service = max(next_service, arrived)
        if pending * 3 >= 1024:
            dropped += 1
        else:
            pending += 1
            peak = max(peak, pending)
    assert dropped == 0, f"Rapid input overflowed the QEMU delayed-queue model: {dropped} transitions dropped"
    elapsed = arrivals[-1] - arrivals[0]
    assert elapsed >= (count-1) * 0.0095, f"Key writer bypassed the 10 ms device rate ({elapsed:.3f}s total)"
    peer.send(bytes([3, 0, 0, 0]) + struct.pack(">I", 0))
    peer.eof()
    print(f"rapid-keyboard: {count} ordered transitions, {elapsed:.3f}s, finite-queue peak {peak}, no modeled drops", flush=True)


run_fixture("rapid-keyboard", "rapid-keyboard", rapid_keyboard)


def input_overflow(peer):
    peer.handshake()
    # A protocol-only acknowledgement avoids racing the reader's initial
    # framebuffer request; no system clipboard is accessed by either peer.
    peer.send(bytes([3, 0, 0, 0]) + struct.pack(">I", 0))
    # The native harness holds its private writer before filling the queue.
    # An overflow must shut down the connection; no accepted subset may leak
    # out later when that writer is released during cleanup.
    peer.eof()


for scenario in ("messages", "bytes"):
    run_fixture("input-overflow-" + scenario, "input-overflow", input_overflow, scenario)


def pointer_coalescing(peer):
    peer.handshake()
    def acknowledge():
        peer.send(bytes([3, 0, 0, 0]) + struct.pack(">I", 2) + b"ok")
    def pointer(x, y, buttons):
        return struct.pack(">BBHH", 5, buttons, x, y)
    acknowledge()
    expected = b"".join([
        pointer(9999, 10, 0), pointer(100, 20, 1), pointer(9999, 30, 1),
        struct.pack(">BBHI", 4, 1, 0, 65), struct.pack(">BBHI", 4, 0, 0, 65),
        pointer(499, 40, 1), pointer(500, 50, 0), pointer(699, 60, 0),
        struct.pack(">B3xI", 6, 7) + b"barrier", pointer(799, 70, 0),
        pointer(800, 80, 8), pointer(800, 80, 8), pointer(800, 80, 0),
        pointer(899, 90, 0), pointer(900, 100, 2), pointer(999, 110, 2),
        pointer(1000, 120, 0),
    ])
    assert len(expected) == 115
    assert peer.read(len(expected)) == expected, "Coalescing reordered or lost a motion/barrier/edge"
    acknowledge()
    assert peer.read(6) == pointer(1001, 121, 0), "Drained motion run swallowed subsequent input"
    acknowledge()
    peer.eof()


run_fixture("pointer-coalescing", "pointer-coalescing", pointer_coalescing)


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
if TEST_FILTER is None or TEST_FILTER == "presenter-fallback":
    subprocess.run([HARNESS, "presenter-fallback"], check=True, timeout=10)
print("All native console tests passed.", flush=True)

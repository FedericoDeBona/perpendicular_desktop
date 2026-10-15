#!/usr/bin/env python3
"""Real isolated QEMU/RFB/QMP/qtest loop. Diskless, no guest OS or live VM."""
import argparse
from pathlib import Path
import select
import socket
import struct
import subprocess
import json
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]


def connect(path, process):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("Owned test QEMU exited before opening its test socket")
        peer = socket.socket(socket.AF_UNIX)
        try:
            peer.connect(str(path))
            peer.settimeout(3)
            return peer
        except (FileNotFoundError, ConnectionRefusedError):
            peer.close()
            time.sleep(0.01)
    raise TimeoutError("Owned test socket did not open")


class QMP:
    def __init__(self, peer):
        self.peer, self.lines, self.sequence = peer, peer.makefile("rb"), 0
        assert "QMP" in self.read()
        self.command("qmp_capabilities")

    def read(self):
        line = self.lines.readline()
        assert line, "QMP unexpectedly disconnected"
        return json.loads(line)

    def command(self, command, arguments=None, allow_error=False):
        self.sequence += 1
        identifier = self.sequence
        request = {"execute": command, "id": identifier}
        if arguments is not None:
            request["arguments"] = arguments
        self.peer.sendall(json.dumps(request).encode() + b"\n")
        while True:
            result = self.read()
            if result.get("id") == identifier:
                if allow_error:
                    return result
                assert "error" not in result, result.get("error")
                return result.get("return")

    def visible(self):
        return self.command("qom-get", {"path": "/machine/peripheral/keyboard", "property": "x-input-test-visible-mask"})

    def rebind(self, head, allow_error=False):
        return self.command("qom-set", {"path": "/machine/peripheral/keyboard", "property": "x-input-test-rebind", "value": head}, allow_error)

    def pending(self):
        return self.command("qom-get", {"path": "/machine/peripheral/keyboard", "property": "x-input-test-pending"})

    def poll(self):
        value = self.command("qom-get", {"path": "/machine/peripheral/keyboard", "property": "x-input-test-poll"})
        return value.to_bytes(8, "big")


class QTest:
    def __init__(self, peer):
        self.peer, self.lines = peer, peer.makefile("rb")

    def step(self):
        self.peer.sendall(b"clock_step 10000000\n")
        line = self.lines.readline()
        assert line.startswith(b"OK"), line


class RFB:
    def __init__(self, peer):
        self.peer = peer
        banner = self.read(12)
        assert banner.startswith(b"RFB 003.")
        peer.sendall(b"RFB 003.008\n")
        count = self.read(1)[0]
        assert 1 in self.read(count)
        peer.sendall(b"\x01")
        assert self.read(4) == bytes(4)
        peer.sendall(b"\x01")
        initial = self.read(24)
        self.width, self.height = struct.unpack(">HH", initial[:4])
        assert self.width and self.height
        self.read(struct.unpack(">I", initial[20:24])[0])
        peer.sendall(bytes([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]))
        peer.sendall(struct.pack(">BBHii", 2, 0, 2, 0, -223))

    def read(self, count):
        data = b""
        while len(data) < count:
            chunk = self.peer.recv(count - len(data))
            assert chunk, "RFB unexpectedly disconnected"
            data += chunk
        return data

    def keys(self, events):
        self.peer.sendall(b"".join(struct.pack(">BBHI", 4, int(down), 0, keysym) for keysym, down in events))

    def extended(self, events):
        self.peer.sendall(b"".join(struct.pack(">BBHII", 255, 0, int(down), symbol, scan) for symbol, scan, down in events))

    def request(self):
        self.peer.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, self.width, self.height))

    def frame(self):
        assert self.read(1) == b"\x00", "Expected a framebuffer response"
        header = self.read(3)
        rectangles = struct.unpack(">H", header[1:])[0]
        assert rectangles <= 512
        total = 0
        for _ in range(rectangles):
            x, y, width, height, encoding = struct.unpack(">HHHHi", self.read(12))
            if encoding == 0:
                assert x + width <= self.width and y + height <= self.height
                self.read(width * height * 4)
                total += width * height
            elif encoding == -223:
                self.width, self.height = width, height
            else:
                raise AssertionError("Unexpected framebuffer encoding " + str(encoding))
        return total


def pump(qmp, qtest, condition, timeout=5):
    reports = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        qtest.step()
        if qmp.pending():
            reports.append(qmp.poll())
        time.sleep(0.003)
        if condition(reports):
            return reports
    raise TimeoutError("Real event loop did not complete the bounded test operation")


def keyboard_state(report):
    return report[0], set(report[2:]) - {0}


def cpu_seconds(pid):
    text = subprocess.check_output(["ps", "-p", str(pid), "-o", "time="], text=True).strip()
    parts = [float(part) for part in text.split(":")]
    return sum(part * 60 ** index for index, part in enumerate(reversed(parts)))


def clear_host_events():
    shift = 0xFFE1
    events = []
    for character in "Clear-Host ":
        if character.isupper():
            events.append((shift, True))
        events += [(ord(character), True), (ord(character), False)]
        if character.isupper():
            events.append((shift, False))
    assert len(events) == 26
    return events


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--production-smoke", action="store_true", help="Only probe absence and real framebuffer on probe-free binary")
    parser.add_argument("--source", type=Path, default=REPO / ".tools/input-backpressure/full-source")
    options = parser.parse_args()
    binary = options.binary.resolve()
    private = (REPO / ".tools/input-backpressure").resolve()
    assert private in binary.parents, "Only the newly built isolated binary is allowed"
    with tempfile.TemporaryDirectory(prefix="prp-rfb-real-", dir="/tmp") as directory:
        work = Path(directory)
        log_path = work / "qemu.log"
        arguments = [str(binary), "-machine", "virt", "-accel", "qtest", "-cpu", "cortex-a72",
                     "-m", "128M", "-nodefaults", "-display", "none", "-monitor", "none", "-serial", "none",
                     "-L", str(options.source / "pc-bios"), "-device", "qemu-xhci,id=usb",
                     "-device", "usb-kbd,id=keyboard,bus=usb.0",
                     "-device", "virtio-gpu-pci,id=gpu,max_outputs=2", "-k", "it",
                     "-vnc", "unix:" + str(work / "vnc.sock"),
                     "-qmp", "unix:" + str(work / "qmp.sock") + ",server=on,wait=off",
                     "-qtest", "unix:" + str(work / "qtest.sock") + ",server=on,wait=off", "-qtest-log", "/dev/null"]
        peers = []
        with log_path.open("wb") as log:
            process = subprocess.Popen(arguments, stdout=log, stderr=log)
            qmp = None
            try:
                qmp_peer = connect(work / "qmp.sock", process)
                peers.append(qmp_peer)
                qmp = QMP(qmp_peer)
                qt_peer = connect(work / "qtest.sock", process)
                peers.append(qt_peer)
                qt = QTest(qt_peer)
                qmp.command("cont")
                qmp.command("trace-event-set-state", {"name": "hid_kbd_queue_full", "enable": True})
                a = RFB(connect(work / "vnc.sock", process))
                peers.append(a.peer)
                if options.production_smoke:
                    result = qmp.command("qom-get", {"path": "/machine/peripheral/keyboard", "property": "x-input-test-pending"}, allow_error=True)
                    assert "error" in result, "QA-only probe leaked into production overlay binary"
                    assert b"x-input-test-" not in binary.read_bytes()
                    a.request()
                    time.sleep(0.08)
                    for _ in range(5):
                        qt.step()
                    assert a.frame() > 0
                    qmp.command("quit")
                    process.wait(timeout=3)
                    assert process.returncode == 0
                    print("Probe-free full linked binary: real QMP/RFB framebuffer and clean shutdown PASS", flush=True)
                    return
                a.request()
                a.keys(clear_host_events())
                time.sleep(0.05)
                for _ in range(8):
                    qt.step()
                assert qmp.pending() == 1, "More than the first transition bypassed suspended guest polling"
                # Leave output unread and add more input after suspension. A
                # jobs-buffer flush must retain the input-disabled watch mask.
                a.request()
                before = cpu_seconds(process.pid)
                time.sleep(0.3)
                after = cpu_seconds(process.pid)
                assert after - before < 0.15, "Suspended ingress spun on G_IO_IN while output was blocked"
                assert a.frame() > 0, "RFB output stopped during keyboard backpressure"
                assert qmp.pending() == 1
                barrier = [False]
                def complete(reports):
                    if select.select([a.peer], [], [], 0)[0]:
                        a.frame()
                        barrier[0] = True
                    return barrier[0] and qmp.pending() == 0 and reports and keyboard_state(reports[-1]) == (0, set())
                reports = pump(qmp, qt, complete)
                previous, pressed = set(), []
                for report in reports:
                    current = keyboard_state(report)[1]
                    pressed += sorted(current - previous)
                    previous = current
                assert pressed == [0x06, 0x0F, 0x08, 0x04, 0x15, 0x38, 0x0B, 0x12, 0x16, 0x17, 0x2C], pressed
                assert "hid_kbd_queue_full" not in log_path.read_text(errors="replace")
                print("Real server: suspended poll, bounded ingress without spin, jobs/frame output and all 26 transitions after resume PASS", flush=True)

                b = RFB(connect(work / "vnc.sock", process))
                peers.append(b.peer)
                def key_and_poll(client, key, down):
                    client.keys([(key, down)])
                    found = pump(qmp, qt, lambda result: bool(result))
                    return found[-1]
                key_and_poll(a, ord("a"), True)
                report = key_and_poll(b, ord("b"), True)
                assert keyboard_state(report)[1] == {0x04, 0x05}
                a.keys([(ord("h"), True), (ord("a"), False)])
                for _ in range(20):
                    qt.step()
                    time.sleep(0.003)
                    if qmp.pending():
                        break
                assert qmp.pending() == 1, {"pending": qmp.pending(), "report": list(report)}
                a.peer.close()
                reports = pump(qmp, qt, lambda result: result and keyboard_state(result[-1]) == (0, {0x05}) and qmp.pending() == 0)
                assert reports and process.poll() is None
                key_and_poll(b, ord("b"), False)
                assert keyboard_state(qmp.poll()) == (0, set())
                print("Real two-client RFB: HUP cancels retained release, only closed owner's keys released; survivor remains usable PASS", flush=True)

                # The actual extended-message parser must retain every byte of
                # a fragmented packet and preserve E0/E1 scancode prefixes.
                qt.step()
                time.sleep(0.02)
                packet = struct.pack(">BBHII", 255, 0, 1, 0xFFEA, 0xB8)
                b.peer.sendall(packet[:11])
                time.sleep(0.03)
                assert qmp.pending() == 0
                b.peer.sendall(packet[11:])
                for _ in range(20):
                    qt.step()
                    time.sleep(0.003)
                    if qmp.pending():
                        break
                assert qmp.pending() == 2, "Complete right-Alt transition did not retain E0 prefix"
                b.extended([(0xFFEA, 0xB8, False), (0xFF13, 0xC6, True), (0xFF13, 0xC6, False)])
                first = qmp.poll()
                assert qmp.pending() == 1 and keyboard_state(first)[0] == 0
                for _ in range(5):
                    qt.step()
                    time.sleep(0.012)
                assert qmp.pending() == 1, "Next RFB transition entered between E0 prefix and scan"
                second = qmp.poll()
                assert keyboard_state(second)[0] == 0x40
                b.request()
                prefix_barrier = [False]
                def prefixed_complete(result):
                    if select.select([b.peer], [], [], 0)[0]:
                        b.frame()
                        prefix_barrier[0] = True
                    return prefix_barrier[0] and qmp.pending() == 0 and result and keyboard_state(result[-1]) == (0, set())
                prefix_reports = [first, second] + pump(qmp, qt, prefixed_complete)
                assert len(prefix_reports) == 10, len(prefix_reports)
                assert any(0x48 in keyboard_state(item)[1] for item in prefix_reports), "Pause E1 sequence was lost"
                print("Real extended parser: fragmented message, atomic E0/E1 transitions and final modifier release PASS", flush=True)

                # A real public display rebind must reject before changing any
                # listener/auth state. An unrelated client can still connect.
                assert qmp.visible() == 1
                key_and_poll(b, ord("a"), True)
                denied = qmp.rebind(1, allow_error=True)
                assert "error" in denied and "pending" in denied["error"]["desc"]
                assert qmp.visible() == 1
                c = RFB(connect(work / "vnc.sock", process))
                peers.append(c.peer)
                c.peer.close()
                key_and_poll(b, ord("a"), False)
                for _ in range(5):
                    qt.step()
                    time.sleep(0.012)
                qmp.rebind(1)
                assert qmp.visible() == 2
                qmp.rebind(0)
                assert qmp.visible() == 1
                print("Real public display rebind: rejects owned input without losing listener; idle rebind restores safely PASS", flush=True)

                # Ctrl-Alt-2 must defer the actual console switch while Ctrl/
                # Alt releases are retained and until their HID scans drain.
                b.keys([(0xFFE3, True), (0xFFE9, True), (ord("2"), True),
                        (ord("2"), False), (0xFFE9, False), (0xFFE3, False)])
                time.sleep(0.04)
                assert qmp.visible() == 1
                switched = pump(qmp, qt, lambda result: qmp.visible() == 2 and qmp.pending() == 0)
                assert switched and keyboard_state(switched[-1]) == (0, set())
                qmp.rebind(0)
                assert qmp.visible() == 1
                print("Real console-switch shortcut: retained releases drain on original device before listener switches PASS", flush=True)

                # Cause control on the same test device only: qtest-only probe
                # bypasses FIFO readiness, leaving all production parser/timers.
                qmp.command("qom-set", {"path": "/machine/peripheral/keyboard", "property": "x-input-test-ignore-ready", "value": True})
                baseline_start = log_path.stat().st_size
                b.keys(clear_host_events())
                for _ in range(70):
                    qt.step()
                    time.sleep(0.01)
                assert qmp.pending() == 16
                dropped = log_path.read_text(errors="replace")[baseline_start:].count("hid_kbd_queue_full")
                assert dropped == 10, dropped
                print("Real-server causal control: bypassing only HID readiness reproduces exactly 10 FIFO drops PASS", flush=True)
                qmp.command("trace-event-set-state", {"name": "hid_kbd_queue_full", "enable": False})
            except BaseException:
                print(log_path.read_text(errors="replace")[-3000:])
                raise
            finally:
                if process.poll() is None:
                    try:
                        if qmp is not None:
                            qmp.command("quit")
                    except (OSError, AssertionError):
                        pass
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.terminate()  # Only the subprocess created above.
                    process.wait(timeout=3)
                for peer in peers:
                    peer.close()
        assert process.returncode == 0, "Owned isolated QEMU did not exit cleanly"


if __name__ == "__main__":
    main()

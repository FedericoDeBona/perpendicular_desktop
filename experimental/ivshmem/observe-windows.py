#!/usr/bin/env python3
"""Mac half of MappingProbe.cs; run before starting the isolated Windows VM.

Creates a fresh backing file, blocks on the notification socket, checks two
patterns, and deliberately retains the first slot for two seconds. No frames,
GPU capture, production pacing or idle polling are implemented here.
"""
import argparse
import ctypes
import hashlib
import json
import mmap
import os
from pathlib import Path
import signal
import socket
import struct
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backing', required=True, type=Path)
    parser.add_argument('--socket', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    for p in [args.backing, args.socket, args.report]:
        if p.resolve().is_relative_to(repo):
            raise ValueError('Generated artifacts must be outside the repository')
    if args.socket.exists() or args.report.exists():
        raise ValueError('Socket and report paths must be new')
    # Refuse to reset memory that may still be owned by QEMU or a consumer.
    fd = os.open(args.backing, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    fence = ctypes.CDLL('/usr/lib/libSystem.B.dylib').OSMemoryBarrier
    fence.restype = None
    events = []
    def stop(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, stop)
    try:
        os.ftruncate(fd, 64 * 1024 * 1024)
        with mmap.mmap(fd, 0) as memory, socket.socket(socket.AF_UNIX) as server:
            memory[4096:8192] = bytes((i * 17 + 3) % 256 for i in range(4096))
            fence()
            server.bind(str(args.socket))
            args.socket.chmod(0o600)
            server.listen(1)
            print('Observer ready; start the isolated VM and run MappingProbe.cs', flush=True)
            connection, _ = server.accept()
            with connection:
                while True:
                    wake = connection.recv(4096)
                    if not wake:
                        break
                    sequence = struct.unpack_from('<I', memory, 64)[0]
                    fence()
                    event = {'wakeBytes': len(wake), 'sequence': sequence, 'time': time.time()}
                    if sequence:
                        data = memory[8192:12288]
                        expected = bytes((i * 31 + 7 + sequence) % 256 for i in range(4096))
                        event.update(complete=data == expected, sha256=hashlib.sha256(data).hexdigest())
                        if sequence == 1:
                            time.sleep(2)  # Deliberate ownership check, not a receive polling loop.
                            event['unchangedWhileHeld'] = memory[8192:12288] == data
                        if not event['complete'] or event.get('unchangedWhileHeld') is False:
                            raise RuntimeError('Published pattern incomplete or overwritten')
                        fence()
                        struct.pack_into('<I', memory, 72, sequence)
                    events.append(event)
                    args.report.write_text(json.dumps(events, indent=2) + '\n')
                    args.report.chmod(0o600)
                    print('Notification sequence', sequence, flush=True)
    finally:
        os.close(fd)
        if args.socket.exists():
            args.socket.unlink()


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""One real QEMU/HVF mapping+notification check, without Windows or disks."""
import argparse
import hashlib
import json
import mmap
import re
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    report = {'Windows_verified': False, 'checks': [], 'qemu_sha256': hashlib.sha256(args.qemu.read_bytes()).hexdigest()}
    with tempfile.TemporaryDirectory(prefix='perp-ivshmem-', dir='/tmp') as folder:
        root = Path(folder)
        # Unix-domain socket paths must fit Darwin's sockaddr_un.
        root = root.resolve()
        notify = root / 'wake'
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(notify))
        listener.listen(1)
        listener.settimeout(5)
        backing = root / 'memory'
        with backing.open('w+b') as store, (root / 'qemu.log').open('w+b') as log:
            backing.chmod(0o600)
            store.truncate(64 * 1024 * 1024)
            shared = mmap.mmap(store.fileno(), 0)
            command = [str(args.qemu.resolve()), '-machine', 'virt,gic-version=3,highmem=on',
                '-accel', 'hvf,ipa-granule-size=4096', '-cpu', 'host', '-m', '128',
                '-S', '-nodefaults', '-display', 'none', '-monitor', 'none', '-serial', 'none',
                '-qtest', f'unix:{root}/qtest,server=on,wait=off',
                '-qmp', f'unix:{root}/qmp,server=on,wait=off',
                '-object', f'memory-backend-file,id=shared,size=64M,mem-path={backing},share=on',
                '-chardev', f'socket,id=wake,path={notify}',
                '-device', 'perp-ivshmem-plain,memdev=shared,host-notify=wake,addr=0x1']
            report['command'] = command
            process = subprocess.Popen(command, stdout=log, stderr=log)
            try:
                wake, _ = listener.accept()
                wake.settimeout(3)
                assert wake.recv(1) == b'\x01', 'Missing initial scan notification'
                qtest = socket.socket(socket.AF_UNIX)
                qtest.settimeout(3)
                deadline = time.monotonic() + 5
                while True:
                    try:
                        qtest.connect(str(root / 'qtest'))
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        if process.poll() is not None or time.monotonic() > deadline:
                            raise
                        time.sleep(0.02)
                stream = qtest.makefile('rwb', buffering=0)
                def request(text):
                    qtest.sendall((text + '\n').encode())
                    line = stream.readline().decode().strip()
                    assert line.startswith('OK'), line
                    return line
                qmp = socket.socket(socket.AF_UNIX)
                qmp.settimeout(3)
                qmp.connect(str(root / 'qmp'))
                qf = qmp.makefile('rwb', buffering=0)
                json.loads(qf.readline())
                def control(execute, arguments=None):
                    qf.write((json.dumps({'execute': execute, 'arguments': arguments or {}}) + '\n').encode())
                    while True:
                        reply = json.loads(qf.readline())
                        if 'event' not in reply:
                            assert 'return' in reply, reply
                            return reply['return']
                control('qmp_capabilities')
                tree = control('human-monitor-command', {'command-line': 'info mtree'})
                report['memory_tree'] = tree
                ranges = re.findall(r'([0-9a-f]+)-[0-9a-f]+ .*?pcie-ecam', tree)
                assert len(set(ranges)) == 1, ranges
                ecam = int(ranges[0], 16) + 0x8000  # slot 1
                assert int(request(f'readl {ecam}').split()[1], 0) == 0x11101af4
                request(f'writel {ecam + 0x10} 0x10000000')
                request(f'writel {ecam + 0x18} 0x20000000')
                request(f'writel {ecam + 0x1c} 0')
                request(f'writew {ecam + 4} 2')
                assert int(request('readl 0x10000010').split()[1], 0) == 0x50525001
                report['checks'].append('PCI 1af4:1110, BAR0 and extension signature')
                challenge = bytes((i * 17 + 3) % 256 for i in range(4096))
                shared[:4096] = challenge
                assert bytes.fromhex(request('read 0x20000000 4096').split()[1][2:]) == challenge
                response = bytes((i * 31 + 7) % 256 for i in range(4096))
                for offset in range(0, 4096, 512):
                    request(f'write {0x20001000 + offset} 512 0x' + response[offset:offset + 512].hex())
                request('writel 0x1000000c 0')
                assert wake.recv(1) == b'\x01', 'Missing MMIO notification'
                assert shared[4096:8192] == response, 'Payload incomplete at wake'
                report['checks'].append('MAP_SHARED and guest-address BAR2 see identical 4096-byte patterns both ways')
                report['checks'].append('MMIO write wakes Unix socket, payload visible at receipt')
                report['response_sha256'] = hashlib.sha256(response).hexdigest()
                # No periodic scanning is used: the receiver slept in recv().
                stream.close()
                qtest.close()
                wake.close()
                control('quit')
                process.wait(timeout=5)
                qf.close()
                qmp.close()
                assert process.returncode == 0, process.returncode
                report['checks'].append('QMP shutdown without guest disks')
                report['ok'] = True
            except Exception as exc:
                report['ok'] = False
                report['error'] = repr(exc)
                raise
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                shared.close()
                listener.close()
                log.flush()
                log.seek(0)
                report['qemu_log'] = log.read().decode(errors='replace')
                args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ('qemu_log', 'command', 'memory_tree')}, indent=2))


if __name__ == '__main__':
    main()

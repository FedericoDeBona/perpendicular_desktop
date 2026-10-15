"""Raw full-frame transport benchmark against a private mock, never a user VM."""

import json
from pathlib import Path
import socket
import statistics
import struct
import subprocess
import sys
import threading

executable = sys.argv[1]
work = Path(sys.argv[2])
width, height, frame_count = 1920, 1080, 60
pixel_data = bytes([10, 40, 80, 0]) * (width * height)
frame_header = struct.pack(">BBHHHHHi", 0, 0, 1, 0, 0, width, height, 0)
results = []

for run in range(5):
    path = work / f"benchmark-{run}.sock"
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(path))
    server.listen(1)
    errors = []

    def serve():
        try:
            connection, _ = server.accept()
            with connection:
                connection.settimeout(30)

                def read(count):
                    data = b""
                    while len(data) < count:
                        chunk = connection.recv(count - len(data))
                        assert chunk
                        data += chunk
                    return data

                connection.sendall(b"RFB 003.008\n")
                read(12)
                connection.sendall(b"\x01\x01")
                read(1)
                connection.sendall(bytes(4))
                read(1)
                connection.sendall(struct.pack(">HH", width, height) + bytes(16) + struct.pack(">I", 4) + b"test")
                read(20)
                read(16)
                for _ in range(frame_count):
                    read(10)
                    connection.sendall(frame_header)
                    connection.sendall(pixel_data)
                read(10)
                connection.sendall(bytes([3, 0, 0, 0]) + struct.pack(">I", 4) + b"done")
                assert connection.recv(1) == b""
        except BaseException as error:
            errors.append(error)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    result = subprocess.run([executable, str(path)], capture_output=True, text=True, timeout=35)
    thread.join(timeout=31)
    server.close()
    path.unlink(missing_ok=True)
    assert result.returncode == 0, result.stderr
    assert not errors, repr(errors)
    sample = json.loads(result.stdout)
    assert sample["frames"] == frame_count
    results.append(sample)

print(json.dumps({
    "workload": "60 raw 1920x1080 full frames; latest immutable frame retained",
    "runs": results,
    "median_elapsed_seconds": statistics.median(row["elapsed_seconds"] for row in results),
    "median_cpu_seconds": statistics.median(row["cpu_seconds"] for row in results),
    "median_raw_mib_per_second": statistics.median(row["raw_mib_per_second"] for row in results),
}, indent=2))

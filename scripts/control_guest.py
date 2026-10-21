#!/usr/bin/env python3
"""Use the running Mac app's private bridge; no token or extra TCP port.

Examples:
  control_guest.py status
  control_guest.py execute --timeout-seconds 30 'C:\\Windows\\System32\\cmd.exe' -- /c ver
  control_guest.py geometry_snapshot
"""

import argparse
import json
import os
from pathlib import Path
import socket
import stat
import struct
import sys

REQUEST_LIMIT = 16_384
RESPONSE_LIMIT = 1_048_576


def receive_exact(connection, count):
    chunks = bytearray()
    while len(chunks) < count:
        chunk = connection.recv(count - len(chunks))
        if not chunk:
            raise RuntimeError("The Mac app closed local control before replying.")
        chunks.extend(chunk)
    return bytes(chunks)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", type=Path, default=Path.home() / "Library/Application Support/Perpendicular Restart/Control/control.sock")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("status", "display_info", "driver_info", "graphics_info", "geometry_snapshot"):
        commands.add_parser(name)
    execute = commands.add_parser("execute", help="Run an executable as the connected Windows user, without elevation.")
    execute.add_argument("--timeout-seconds", type=int, default=15, choices=range(1, 61), metavar="1..60")
    execute.add_argument("executable", help="Absolute Windows executable path.")
    execute.add_argument("args", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    request = {"command": options.command}
    if options.command == "execute":
        arguments = options.args[1:] if options.args[:1] == ["--"] else options.args
        request.update(executable=options.executable, args=arguments, timeoutSeconds=options.timeout_seconds)
    data = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(data) > REQUEST_LIMIT:
        raise RuntimeError("The local request exceeds 16 KiB.")
    directory = options.socket.parent.lstat()
    endpoint = options.socket.lstat()
    if (not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.geteuid()
            or stat.S_IMODE(directory.st_mode) != 0o700 or not stat.S_ISSOCK(endpoint.st_mode)
            or endpoint.st_uid != os.geteuid() or stat.S_IMODE(endpoint.st_mode) != 0o600):
        raise RuntimeError("Local control must use this user's private directory (0700) and socket (0600).")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(70)
        connection.connect(str(options.socket))
        connection.sendall(struct.pack("<I", len(data)) + data)
        count, = struct.unpack("<I", receive_exact(connection, 4))
        if not 0 < count <= RESPONSE_LIMIT:
            raise RuntimeError("The Mac app returned an invalid response length.")
        reply = json.loads(receive_exact(connection, count))
    if not isinstance(reply, dict) or not isinstance(reply.get("ok"), bool):
        raise RuntimeError("The Mac app returned an invalid response.")
    print(json.dumps(reply, ensure_ascii=False, indent=2))
    if not reply["ok"]:
        return 1
    if options.command == "execute":
        result = reply.get("result", {})
        if result.get("timedOut"):
            return 124
        code = result.get("exitCode")
        if code != 0:
            return code if isinstance(code, int) and 1 <= code <= 125 else 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        sys.exit(1)

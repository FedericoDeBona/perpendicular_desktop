#!/usr/bin/env python3
"""Remove only Finder decoration attributes from our generated app bundle."""
import os
from pathlib import Path
import sys
import subprocess

root = Path(sys.argv[1]).resolve()
if root.suffix != ".app" or not (root / "Contents/Info.plist").is_file():
    raise SystemExit("Expected a generated application bundle")
for directory, folders, files in os.walk(root):
    for name in ["", *folders, *files]:
        path = Path(directory) / name
        attributes = subprocess.check_output(["/usr/bin/xattr", "-s", str(path)], text=True).splitlines()
        for attribute in ("com.apple.FinderInfo", "com.apple.ResourceFork"):
            if attribute in attributes:
                subprocess.run(["/usr/bin/xattr", "-s", "-d", attribute, str(path)], check=True)

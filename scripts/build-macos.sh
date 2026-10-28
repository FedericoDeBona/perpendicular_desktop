#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app="$PWD/.build/Perpendicular.app"
runtime_app="${PERPENDICULAR_RUNTIME_APP:-/Applications/Perpendicular.app}"
guest="$PWD/guest/target/aarch64-pc-windows-msvc/release/perpendicular-guest.exe"
[[ -f "$guest" ]] || { print -u2 'Build the ARM64 guest first with scripts/build-guest.sh'; exit 1; }
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Guest"
cp macos/Info.plist "$app/Contents/Info.plist"
# Retain this computer's explicit VM selection when reusing its installed app.
# Only the path is copied; machine settings, disks and credentials stay private.
python3 - "$app/Contents/Info.plist" "$runtime_app/Contents/Info.plist" <<'PY'
import os
from pathlib import Path
import plistlib
import sys
target, reference = map(Path, sys.argv[1:])
directory = os.environ.get('PERPENDICULAR_MACHINE_DIRECTORY')
if directory is None and reference.is_file():
    directory = plistlib.loads(reference.read_bytes()).get('PerpendicularMachineDirectory')
if directory is not None:
    if not isinstance(directory, str) or not Path(directory).is_absolute():
        raise ValueError('The selected Windows machine directory must be an absolute path')
    info = plistlib.loads(target.read_bytes())
    info['PerpendicularMachineDirectory'] = directory
    target.write_bytes(plistlib.dumps(info, sort_keys=False))
PY
xcrun clang -O2 -target arm64-apple-macosx14.0 -c macos/NativeTransport/ndt.c -o .build/native-transport.o
xcrun clang -O2 -target arm64-apple-macosx14.0 -c macos/NativeTransport/gpu-receiver.c -o .build/gpu-receiver.o
xcrun swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macosx14.0 \
    -import-objc-header macos/NativeTransport/bridge.h .build/native-transport.o .build/gpu-receiver.o \
    macos/RuntimeStore.swift macos/NativeWindowFrames.swift macos/NativeGraphics.swift macos/NativeDisplay.swift macos/DesktopConnection.swift macos/DesktopWindow.swift \
    macos/VirtualMachine.swift macos/SharedFolders.swift macos/SambaServer.swift macos/SharedFolderIntegration.swift macos/MachineControl.swift macos/MachineSettings.swift macos/MachineSettingsPanel.swift macos/MemoryControl.swift macos/GuestBridge.swift macos/GuestFrameSurface.swift macos/MacLocalControl.swift macos/DisplayTopology.swift macos/SharedDisplay.swift \
    macos/WindowGeometry.swift macos/WindowRenderer.swift macos/WindowTransitionView.swift macos/ApplicationContent.swift macos/ApplicationWindow.swift macos/LauncherLibrary.swift macos/Launcher.swift macos/GuestApplicationState.swift macos/App.swift \
    -o "$app/Contents/MacOS/Perpendicular"
cp "$guest" guest/install.ps1 guest/install.cmd "$app/Contents/Resources/Guest/"
cp guest/apply-shared-folders.ps1 guest/configure-shared-folders.ps1 guest/connect-shared-folders.ps1 guest/retire-shared-files.ps1 guest/configure-smb-cache.ps1 guest/install-shared-folders.ps1 "$app/Contents/Resources/Guest/"
zsh scripts/package-app-icon.sh "$app"
if [[ "${SKIP_RUNTIME:-0}" != 1 ]]; then
    python3 scripts/copy-main-runtime.py --from-app "$runtime_app" --to-app "$app"
fi
if [[ "${SKIP_RUNTIME:-0}" == 1 && -d .build/Native3D ]]; then
    # RuntimeStore preserves the running VM's immutable copy. Always refresh
    # the next build; an existing bundle must not silently keep an old renderer.
    rm -rf "$app/Contents/Resources/Native3D"
    cp -R .build/Native3D "$app/Contents/Resources/Native3D"
fi
python3 scripts/prepare-build-dependencies.py --app "$app"
rm -rf "$app/Contents/Resources/Display2D"
codesign --force --sign - "$app"
"$app/Contents/Resources/QEMU/bin/qemu-system-aarch64" --version | head -1
"$app/Contents/Resources/QEMU/bin/swtpm" --version | head -1
print "$app"

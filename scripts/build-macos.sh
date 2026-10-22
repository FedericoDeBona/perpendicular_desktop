#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app="$PWD/.build/Perpendicular.app"
guest="$PWD/guest/target/aarch64-pc-windows-msvc/release/perpendicular-guest.exe"
[[ -f "$guest" ]] || { print -u2 'Build the ARM64 guest first with scripts/build-guest.sh'; exit 1; }
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Guest"
cp macos/Info.plist "$app/Contents/Info.plist"
xcrun clang -O2 -target arm64-apple-macosx14.0 -c macos/NativeTransport/ndt.c -o .build/native-transport.o
xcrun swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macosx14.0 \
    -import-objc-header macos/NativeTransport/ndt.h .build/native-transport.o \
    macos/RuntimeStore.swift macos/NativeGraphics.swift macos/NativeDisplay.swift macos/DesktopConnection.swift macos/DesktopWindow.swift \
    macos/VirtualMachine.swift macos/MachineControl.swift macos/GuestBridge.swift macos/GuestFrameSurface.swift macos/MacLocalControl.swift macos/DisplayTopology.swift macos/SharedDisplay.swift \
    macos/WindowGeometry.swift macos/WindowRenderer.swift macos/ApplicationContent.swift macos/ApplicationWindow.swift macos/Launcher.swift macos/App.swift \
    -o "$app/Contents/MacOS/Perpendicular"
cp "$guest" guest/install.ps1 guest/install.cmd "$app/Contents/Resources/Guest/"
if [[ "${SKIP_RUNTIME:-0}" != 1 ]]; then
    python3 scripts/package-runtime.py "$app"
fi
if [[ -d .build/Native3D ]]; then
    # RuntimeStore preserves the running VM's immutable copy. Always refresh
    # the next build; an existing bundle must not silently keep an old renderer.
    rm -rf "$app/Contents/Resources/Native3D"
    cp -R .build/Native3D "$app/Contents/Resources/Native3D"
fi
rm -rf "$app/Contents/Resources/Display2D"
codesign --force --sign - "$app"
"$app/Contents/Resources/QEMU/bin/qemu-system-aarch64" --version | head -1
"$app/Contents/Resources/QEMU/bin/swtpm" --version | head -1
print "$app"

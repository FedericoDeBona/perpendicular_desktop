#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app="$PWD/.build/Perpendicular.app"
guest="$PWD/guest/target/aarch64-pc-windows-msvc/release/perpendicular-guest.exe"
[[ -f "$guest" ]] || { print -u2 'Build the ARM64 guest first with scripts/build-guest.sh'; exit 1; }
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Guest"
cp macos/Info.plist "$app/Contents/Info.plist"
xcrun swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macosx14.0 \
    macos/VirtualMachine.swift macos/MachineControl.swift macos/GuestBridge.swift \
    macos/ApplicationContent.swift macos/ApplicationWindow.swift macos/App.swift \
    -o "$app/Contents/MacOS/Perpendicular"
cp "$guest" guest/install.ps1 guest/install.cmd "$app/Contents/Resources/Guest/"
if [[ "${SKIP_RUNTIME:-0}" != 1 ]]; then
    python3 scripts/package-runtime.py "$app"
fi
codesign --force --sign - "$app"
"$app/Contents/Resources/QEMU/bin/qemu-system-aarch64" --version | head -1
"$app/Contents/Resources/QEMU/bin/swtpm" --version | head -1
print "$app"

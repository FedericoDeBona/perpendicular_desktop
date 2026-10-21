#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
app="$repo_dir/.build/FreeRDP/DisplayConnect.app"
"$repo_dir/experimental/rdp-display/build-probe.sh"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macosx14.0 \
  -framework AppKit "$repo_dir/experimental/rdp-display/ConnectDisplay.swift" \
  -o "$app/Contents/MacOS/DisplayConnect"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.perpendicular.display-connect</string>
<key>CFBundleName</key><string>DisplayConnect</string>
<key>CFBundleExecutable</key><string>DisplayConnect</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.perpendicular.display-connect "$app"
codesign --verify --strict "$app"
printf '%s\n' "Built $app (not launched)"

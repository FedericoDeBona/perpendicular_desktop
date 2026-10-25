#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app="${1:?Pass the app bundle path}"
output="$PWD/.build/brand-native"
mkdir -p "$output" "$app/Contents/Resources"

# Compile the layered document, rather than ship only its flattened preview.
xcrun actool design/brand/Perpendicular.icon \
    --compile "$output" --platform macosx --minimum-deployment-target 14.0 \
    --target-device mac --app-icon Perpendicular \
    --output-partial-info-plist "$output/icon-info.plist" \
    --output-format human-readable-text --warnings --notices
swift design/brand/export.swift
cp "$output/Assets.car" "$app/Contents/Resources/Assets.car"
cp .build/brand/Perpendicular.icns "$app/Contents/Resources/Perpendicular.icns"
cp .build/brand/Perpendicular.png "$app/Contents/Resources/BrandMark.png"

# Keep the bundle's icon declaration consistent with the compiler's output.
python3 - "$app/Contents/Info.plist" "$output/icon-info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path
path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
icons = plistlib.loads(Path(sys.argv[2]).read_bytes())
for key in ('CFBundleIconFile', 'CFBundleIconName'):
    info[key] = icons[key]
path.write_bytes(plistlib.dumps(info, sort_keys=False))
PY

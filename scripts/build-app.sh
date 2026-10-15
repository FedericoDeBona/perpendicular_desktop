#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
APP="$ROOT/build/Perpendicular Desktop.app"
if [[ ! -x "$CARGO" ]]; then
  echo "Install Rust with rustup or set CARGO to the cargo executable." >&2
  exit 1
fi
"$CARGO" build --manifest-path "$ROOT/engine/Cargo.toml" --release --locked
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/engine/target/release/perpendicular-engine" "$APP/Contents/Resources/perpendicular-engine"
xcrun swiftc -swift-version 6 -O -parse-as-library \
  -target arm64-apple-macosx14.0 -sdk "$(xcrun --show-sdk-path)" \
  "$ROOT"/macos/PerpendicularDesktop/*.swift \
  -o "$APP/Contents/MacOS/Perpendicular Desktop"
if [[ "${PERPENDICULAR_BUNDLE_RUNTIME:-1}" == 1 ]]; then
  "${PYTHON:-python3}" "$ROOT/scripts/bundle-runtime.py" "$APP" "$ROOT/.tools/qemu"
fi
"${PYTHON:-python3}" "$ROOT/scripts/clean-build-metadata.py" "$APP"
codesign --force --sign - --entitlements "$ROOT/macos/Hypervisor.entitlements" "$APP/Contents/Resources/perpendicular-engine"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"

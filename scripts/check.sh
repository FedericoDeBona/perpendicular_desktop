#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
OUTPUT="$ROOT/.build/checks"
mkdir -p "$OUTPUT"
"$CARGO" fmt --manifest-path "$ROOT/engine/Cargo.toml" --check
"$CARGO" clippy --manifest-path "$ROOT/engine/Cargo.toml" --locked --all-targets -- -D warnings
"$CARGO" test --manifest-path "$ROOT/engine/Cargo.toml" --locked
"$ROOT/macos/Tests/run-console-tests.sh"
for pair in 'Engine.swift EngineClientCheck.swift' 'WindowPresentation.swift WindowPresentationCheck.swift'; do
  read -r source test <<< "$pair"
  check_sources=("$ROOT/macos/PerpendicularDesktop/$source")
  if [[ "$source" == Engine.swift ]]; then
    check_sources+=("$ROOT/macos/PerpendicularDesktop/GuestTools.swift")
  fi
  xcrun swiftc -parse-as-library -target arm64-apple-macosx14.0 -swift-version 6 \
    "${check_sources[@]}" "$ROOT/macos/Tests/$test" -o "$OUTPUT/${test%.swift}"
  "$OUTPUT/${test%.swift}"
done
xcrun swiftc -parse-as-library -target arm64-apple-macosx14.0 -swift-version 6 \
  "$ROOT/macos/PerpendicularDesktop/Engine.swift" \
  "$ROOT/macos/PerpendicularDesktop/GuestTools.swift" \
  "$ROOT/macos/Tests/GuestToolsCheck.swift" -o "$OUTPUT/GuestToolsCheck"
"$OUTPUT/GuestToolsCheck"
xcrun swiftc -parse-as-library -D PERPENDICULAR_UI_RENDER \
  -target arm64-apple-macosx14.0 -swift-version 6 \
  "$ROOT"/macos/PerpendicularDesktop/*.swift \
  "$ROOT/macos/Tests/DiskExportCheck.swift" -o "$OUTPUT/DiskExportCheck"
"$OUTPUT/DiskExportCheck"
python3 -m unittest discover -s "$ROOT/scripts/tests" -p 'test_secure_boot_dbx.py'
if [[ -n "${PERPENDICULAR_POWERSHELL:-}" ]]; then
  "$PERPENDICULAR_POWERSHELL" -NoProfile -File "$ROOT/guest-tools/windows/tests/Test-AgentCore.ps1"
  "$PERPENDICULAR_POWERSHELL" -NoProfile -File "$ROOT/guest-tools/windows/tests/Test-GuestToolsInstaller.ps1"
fi
echo "Rust engine and native console/client/window checks passed."

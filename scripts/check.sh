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
  xcrun swiftc -parse-as-library -target arm64-apple-macosx14.0 -swift-version 6 \
    "$ROOT/macos/PerpendicularDesktop/$source" "$ROOT/macos/Tests/$test" -o "$OUTPUT/${test%.swift}"
  "$OUTPUT/${test%.swift}"
done
echo "Rust engine and native console/client/window checks passed."

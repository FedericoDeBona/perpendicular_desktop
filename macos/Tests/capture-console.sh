#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../.." && pwd)"
test_work_dir="$(mktemp -d /tmp/perpendicular-capture.XXXXXX)"
trap 'rm -rf "$test_work_dir"' EXIT
cat "$repo_dir/macos/PerpendicularDesktop/VMConsole.swift" \
    "$test_dir/CaptureConsole.swift" > "$test_work_dir/Capture.swift"
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 \
    "$test_work_dir/Capture.swift" -o "$test_work_dir/capture-console"
"$test_work_dir/capture-console" "$@"

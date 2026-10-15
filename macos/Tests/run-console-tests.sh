#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../.." && pwd)"
# Unix-domain paths on macOS must fit in 104 bytes. The user TMPDIR may already
# consume most of that budget; use a private mktemp directory directly in /tmp.
test_work_dir="$(mktemp -d /tmp/perpendicular-console.XXXXXX)"
trap 'rm -rf "$test_work_dir"' EXIT

# The test declarations share one temporary source file with the console, so
# production protocol internals can stay private. Tests are outside the app's
# PerpendicularDesktop/*.swift build glob.
cat "$repo_dir/macos/PerpendicularDesktop/VMConsole.swift" \
    "$test_dir/ConsoleHarness.swift" > "$test_work_dir/Harness.swift"
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 \
    "$test_work_dir/Harness.swift" -o "$test_work_dir/console-harness"
python3 "$test_dir/ConsoleMock.py" "$test_work_dir/console-harness" "$test_work_dir"

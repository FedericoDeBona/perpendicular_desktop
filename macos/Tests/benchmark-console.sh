#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../.." && pwd)"
test_work_dir="$(mktemp -d /tmp/perpendicular-benchmark.XXXXXX)"
trap 'rm -rf "$test_work_dir"' EXIT
cat "$repo_dir/macos/PerpendicularDesktop/VMKeyboardText.swift" \
    "$repo_dir/macos/PerpendicularDesktop/RFBDesktopResize.swift" \
    "$repo_dir/macos/PerpendicularDesktop/VMDisplayPresenter.swift" \
    "$repo_dir/macos/PerpendicularDesktop/VMConsole.swift" \
    "$test_dir/BenchmarkConsole.swift" > "$test_work_dir/Benchmark.swift"
swiftc -O -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 \
    "$test_work_dir/Benchmark.swift" -o "$test_work_dir/benchmark-console"
python3 "$test_dir/BenchmarkConsole.py" "$test_work_dir/benchmark-console" "$test_work_dir"

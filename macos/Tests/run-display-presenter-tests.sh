#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../.." && pwd)"
test_work_dir="$(mktemp -d /tmp/perpendicular-display.XXXXXX)"
trap 'rm -rf "$test_work_dir"' EXIT
swiftc -O -parse-as-library -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 \
    "$repo_dir/macos/PerpendicularDesktop/VMDisplayPresenter.swift" \
    "$test_dir/DisplayPresenterCheck.swift" -o "$test_work_dir/display-check"
"$test_work_dir/display-check" "$@"

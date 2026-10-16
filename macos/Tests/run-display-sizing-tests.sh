#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../.." && pwd)"
test_work_dir="$(mktemp -d /tmp/prp-size.XXXXXX)"
trap 'rm -rf "$test_work_dir"' EXIT
cat "$repo_dir/macos/PerpendicularDesktop/VMKeyboardText.swift" \
    "$repo_dir/macos/PerpendicularDesktop/NativeDisplayEndpoint.swift" \
    "$repo_dir/macos/PerpendicularDesktop/RFBDesktopResize.swift" \
    "$repo_dir/macos/PerpendicularDesktop/VMDisplayPresenter.swift" \
    "$repo_dir/macos/PerpendicularDesktop/RFBCursor.swift" \
    "$repo_dir/macos/PerpendicularDesktop/RFBCursorPresentation.swift" \
    "$repo_dir/macos/PerpendicularDesktop/VMConsole.swift" \
    "$repo_dir/macos/PerpendicularDesktop/Engine.swift" \
    "$repo_dir/macos/PerpendicularDesktop/GuestTools.swift" \
    "$repo_dir/macos/PerpendicularDesktop/DisplaySizing.swift" \
    "$test_dir/DisplaySizingHarness.swift" > "$test_work_dir/Harness.swift"
swiftc -parse-as-library -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 \
    "$test_work_dir/Harness.swift" -o "$test_work_dir/sizing-check"
python3 "$test_dir/DisplaySizingMock.py" "$test_work_dir/sizing-check" "$test_work_dir" "$@"

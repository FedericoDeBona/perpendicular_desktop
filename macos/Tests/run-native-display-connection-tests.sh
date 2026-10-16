#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../.." && pwd)"
transport_dir="$repo_dir/experimental/native-display-transport"
test_work_dir="$(mktemp -d /tmp/perpendicular-native-receiver.XXXXXX)"
trap 'rm -rf "$test_work_dir"' EXIT
xcrun clang -target arm64-apple-macosx14.0 -std=c17 -Wall -Wextra -Werror -O1 "$transport_dir/ndt.c" "$transport_dir/fixture.c" -o "$test_work_dir/ndt-producer"
xcrun clang -target arm64-apple-macosx14.0 -std=c17 -Wall -Wextra -Werror -O1 -I "$transport_dir" "$transport_dir/ndt.c" "$test_dir/NativeDisplayFixture.c" -o "$test_work_dir/controlled-producer"
xcrun clang -target arm64-apple-macosx14.0 -std=c17 -Wall -Wextra -Werror -O1 -c "$transport_dir/ndt.c" -o "$test_work_dir/ndt.o"
swiftc -O -parse-as-library -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 \
    -D PERPENDICULAR_NATIVE_DISPLAY -import-objc-header "$transport_dir/ndt.h" \
    "$repo_dir/macos/PerpendicularDesktop/NativeDisplayEndpoint.swift" \
    "$repo_dir/macos/PerpendicularDesktop/VMDisplayPresenter.swift" \
    "$repo_dir/macos/PerpendicularDesktop/NativeDisplayConnection.swift" \
    "$test_dir/NativeDisplayConnectionCheck.swift" "$test_work_dir/ndt.o" -o "$test_work_dir/receiver-check"
"$test_work_dir/receiver-check" "$test_work_dir/ndt-producer" "$test_work_dir/controlled-producer" "$@"

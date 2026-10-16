#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=$(mktemp -d /tmp/perp-ndt-build-XXXXXX)
trap 'rm -rf "$OUTPUT"' EXIT HUP INT TERM
xcrun clang -std=c17 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
  "$ROOT/ndt.c" "$ROOT/fixture.c" -o "$OUTPUT/fixture"
"$OUTPUT/fixture"
xcrun clang -std=c17 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
  -Drecvmsg=ndt_fixture_recvmsg -Dsendmsg=ndt_fixture_sendmsg -c "$ROOT/ndt.c" -o "$OUTPUT/ndt.o"
xcrun clang -std=c17 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
  "$OUTPUT/ndt.o" "$ROOT/fixture.c" -o "$OUTPUT/partial-fixture"
"$OUTPUT/partial-fixture" --case normal
"$OUTPUT/partial-fixture" --case forcedctrunc
xcrun swiftc -typecheck -import-objc-header "$ROOT/ndt.h" "$ROOT/BindingCheck.swift"

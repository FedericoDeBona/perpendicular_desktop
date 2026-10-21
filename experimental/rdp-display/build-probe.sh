#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="$repo_dir/.build/FreeRDP/install"
openssl_root="${OPENSSL_ROOT_DIR:-$(brew --prefix openssl@3)}"
test -f "$prefix/include/freerdp3/freerdp/freerdp.h" || {
  echo "Build the experimental FreeRDP libraries first." >&2; exit 1;
}
xcrun clang -std=c11 -Wall -Wextra -Werror=implicit-function-declaration \
  -Wno-deprecated-declarations \
  "$repo_dir/experimental/rdp-display/display-probe.c" \
  -I"$prefix/include/freerdp3" -I"$prefix/include/winpr3" -I"$openssl_root/include" \
  -L"$prefix/lib" -L"$openssl_root/lib" \
  -lfreerdp-client3 -lfreerdp3 -lwinpr3 -lssl -lcrypto -lpthread \
  -Wl,-rpath,"$prefix/lib" -o "$repo_dir/.build/FreeRDP/display-probe"
"$repo_dir/.build/FreeRDP/display-probe" --self-check

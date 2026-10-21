#!/bin/bash
set -euo pipefail

# Deliberately separate from the ordinary app build. Never installs prerequisites
# or connects to Windows; all downloaded/generated files stay under .build.
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
manifest="$repo_dir/experimental/rdp-display/freerdp-source.json"
build_root="$repo_dir/.build/FreeRDP"
cmake_bin="${CMAKE_BIN:-cmake}"
command -v "$cmake_bin" >/dev/null || { echo "CMake is required; no dependencies were installed." >&2; exit 1; }
openssl_root="${OPENSSL_ROOT_DIR:-$(brew --prefix openssl@3)}"
test -f "$openssl_root/include/openssl/ssl.h"
mkdir -p "$build_root"
version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$manifest")"
url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"])' "$manifest")"
expected_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$manifest")"
archive="$build_root/FreeRDP-$version.tar.gz"
if ! test -f "$archive"; then
  curl -fL --retry 1 "$url" -o "$archive.part"
  mv "$archive.part" "$archive"
fi
actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
if test "$actual_sha" != "$expected_sha"; then
  echo "FreeRDP archive SHA256 mismatch; refusing to extract." >&2
  exit 1
fi
source_dir="$build_root/FreeRDP-$version"
if ! test -f "$source_dir/CMakeLists.txt"; then
  tar -xzf "$archive" -C "$build_root"
fi
prefix="$build_root/install"
flags=()
while IFS= read -r flag; do flags+=("$flag"); done < <(
  python3 - "$manifest" "$source_dir" <<'PY'
import json,pathlib,sys
m=json.load(open(sys.argv[1]))
print('\n'.join(m['cmake_flags']))
enabled=set(m['client_channels'])
for p in sorted((pathlib.Path(sys.argv[2])/'channels').glob('*/ChannelOptions.cmake')):
    print('-DCHANNEL_'+p.parent.name.upper()+'='+('ON' if p.parent.name in enabled else 'OFF'))
PY
)
"$cmake_bin" -S "$source_dir" -B "$build_root/build" -G "Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$prefix" -DOPENSSL_ROOT_DIR="$openssl_root" "${flags[@]}"
"$cmake_bin" --build "$build_root/build" --parallel "${BUILD_JOBS:-6}"
"$cmake_bin" --install "$build_root/build"

# Keep upstream notices with the private build before any future packaging work.
mkdir -p "$prefix/share/licenses/FreeRDP"
cp "$source_dir/LICENSE" "$prefix/share/licenses/FreeRDP/LICENSE"
if test -f "$source_dir/NOTICE"; then cp "$source_dir/NOTICE" "$prefix/share/licenses/FreeRDP/NOTICE"; fi
cp "$manifest" "$prefix/share/licenses/FreeRDP/source-manifest.json"

cat > "$build_root/context-smoke.c" <<'C'
#include <stdio.h>
#include <freerdp/freerdp.h>
int main(void) {
    freerdp* instance = freerdp_new();
    if (!instance) return 1;
    if (!freerdp_context_new(instance)) { freerdp_free(instance); return 2; }
    printf("FreeRDP %s: context initialized; no connection attempted\n", freerdp_get_version_string());
    freerdp_context_free(instance);
    freerdp_free(instance);
    return 0;
}
C
xcrun clang "$build_root/context-smoke.c" \
  -I"$prefix/include/freerdp3" -I"$prefix/include/winpr3" \
  -L"$prefix/lib" -lfreerdp3 -lwinpr3 -Wl,-rpath,"$prefix/lib" \
  -o "$build_root/context-smoke"
"$build_root/context-smoke"

#!/bin/zsh
set -eu
cd "${0:A:h:h}"
sdk="${XWIN_CACHE_DIR:-$HOME/.local/share/perpendicular-build-tools/windows-sdk}/xwin/sdk/lib/um/aarch64"
output="$PWD/.build/window-hook"
mkdir -p "$output"
clang -target aarch64-pc-windows-msvc -O2 -fno-stack-protector -c guest/native/window_hook.c -o "$output/window-hook.obj"
linker="$(rustc --print sysroot)/lib/rustlib/aarch64-apple-darwin/bin/rust-lld"
"$linker" -flavor link /dll /noentry /machine:arm64 /timestamp:0 "/out:$output/perpendicular-window-hook.dll" "$output/window-hook.obj" \
  "$sdk/User32.Lib" "$sdk/kernel32.Lib" "$sdk/dwmapi.lib"

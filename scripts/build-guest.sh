#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export PATH="$HOME/.local/share/perpendicular-build-tools/bin:$HOME/.cargo/bin:$PATH"
export XWIN_ARCH=aarch64
export XWIN_CACHE_DIR="${XWIN_CACHE_DIR:-$HOME/.local/share/perpendicular-build-tools/windows-sdk}"
export RUSTFLAGS='-C target-feature=+crt-static'
zsh scripts/build-window-hook.sh
export PERP_WINDOW_HOOK_DLL="$PWD/.build/window-hook/perpendicular-window-hook.dll"
cargo-xwin build --manifest-path guest/Cargo.toml --release --target aarch64-pc-windows-msvc --locked

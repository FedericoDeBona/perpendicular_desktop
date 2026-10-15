#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
QEMU_VERSION=11.1.2
QEMU_SHA256=731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "An Apple Silicon Mac is required." >&2; exit 1; }
xcode-select -p >/dev/null || { echo "Install Apple Command Line Tools first: xcode-select --install" >&2; exit 1; }
command -v brew >/dev/null || { echo "Install Homebrew from https://brew.sh, then rerun this script." >&2; exit 1; }
mkdir -p "$TOOLS/downloads" "$TOOLS/src" "$TOOLS/qemu-build"
if [[ ! -x "$HOME/.cargo/bin/cargo" ]] && ! command -v cargo >/dev/null; then
  RUSTUP="$TOOLS/downloads/rustup-init"
  curl --fail --location --proto '=https' --tlsv1.2 https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init -o "$RUSTUP"
  RUSTUP_HASH="$(curl --fail --silent --proto '=https' --tlsv1.2 https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init.sha256 | awk '{print $1}')"
  [[ "$(shasum -a 256 "$RUSTUP" | awk '{print $1}')" == "$RUSTUP_HASH" ]] || { echo 'Rustup checksum failed.' >&2; exit 1; }
  chmod +x "$RUSTUP"
  "$RUSTUP" -y --profile minimal --default-toolchain stable --no-modify-path
fi
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install python@3.14 pkgconf glib pixman libusb gnutls swtpm
PYTHON="$(brew --prefix python@3.14)/bin/python3.14"
"$PYTHON" -m venv "$TOOLS/build-venv"
"$TOOLS/build-venv/bin/python" -m pip install 'meson==1.12.1' 'ninja==1.13.2'
export PATH="$TOOLS/build-venv/bin:$HOME/.cargo/bin:$PATH"
ARCHIVE="$TOOLS/downloads/qemu-$QEMU_VERSION.tar.xz"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz" -o "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$QEMU_SHA256" ]] || { echo 'QEMU checksum failed.' >&2; exit 1; }
if [[ ! -d "$TOOLS/src/qemu-$QEMU_VERSION" ]]; then
  tar -xf "$ARCHIVE" -C "$TOOLS/src"
fi
cd "$TOOLS/qemu-build"
"$TOOLS/src/qemu-$QEMU_VERSION/configure" --prefix="$TOOLS/qemu" \
  --target-list=aarch64-softmmu --python="$TOOLS/build-venv/bin/python" \
  --enable-hvf --enable-vnc --enable-slirp --enable-tpm --enable-tools \
  --disable-docs --disable-werror --disable-gtk --disable-sdl --disable-cocoa \
  --disable-rust --disable-vnc-jpeg --disable-vnc-sasl --disable-slirp-smbd \
  --disable-pvg
ninja -j "${PERPENDICULAR_BUILD_JOBS:-6}"
ninja install
for attribute in com.apple.FinderInfo com.apple.ResourceFork; do
  if /usr/bin/xattr -p "$attribute" "$TOOLS/qemu/bin/qemu-system-aarch64" >/dev/null 2>&1; then
    /usr/bin/xattr -d "$attribute" "$TOOLS/qemu/bin/qemu-system-aarch64"
  fi
done
codesign --force --sign - --entitlements "$ROOT/macos/Hypervisor.entitlements" "$TOOLS/qemu/bin/qemu-system-aarch64"
echo "Runtime installed in $TOOLS/qemu"
echo "Secure ARM firmware must also be provisioned; see scripts/provision-secure-firmware.sh."

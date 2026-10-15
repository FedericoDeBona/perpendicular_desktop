#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/.tools/edk2/output}"
DESTINATION="$ROOT/.tools/qemu/share/qemu"
for name in edk2-aarch64-secure-code.fd edk2-arm-secure-vars.fd edk2-licenses.txt; do
  [[ -f "$SOURCE/$name" ]] || { echo "Missing $SOURCE/$name. Build firmware with scripts/build-secure-firmware.sh or supply an explicit source directory." >&2; exit 1; }
done
mkdir -p "$DESTINATION"
for name in edk2-aarch64-secure-code.fd edk2-arm-secure-vars.fd; do
  cp "$SOURCE/$name" "$DESTINATION/$name"
done
cp "$SOURCE/edk2-licenses.txt" "$DESTINATION/edk2-secure-licenses.txt"
if [[ -f "$SOURCE/build-manifest.json" ]]; then
  cp "$SOURCE/build-manifest.json" "$DESTINATION/secure-firmware-build-manifest.json"
fi
if [[ -f "$SOURCE/enrolled-variable-summary.json" ]]; then
  cp "$SOURCE/enrolled-variable-summary.json" "$DESTINATION/enrolled-variable-summary.json"
fi
shasum -a 256 "$DESTINATION/edk2-aarch64-secure-code.fd" "$DESTINATION/edk2-arm-secure-vars.fd"
echo "Provisioned secure ARM firmware; its notices and available build provenance are retained beside the files."
echo "See scripts/build-secure-firmware.sh for the verified QEMU/EDK2 source build."

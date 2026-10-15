#!/bin/bash
# Test helper only: build one ARM64 EFI application, not firmware or an app.
set -euo pipefail
PERP_PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PERP_PROBE_SOURCE="$PERP_PROBE_ROOT/.tools/edk2/source"
[[ -f "$PERP_PROBE_SOURCE/ArmVirtPkg/ArmVirtQemu.dsc" ]] || { echo "Build the pinned secure firmware first." >&2; exit 1; }
python3 - "$PERP_PROBE_ROOT" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
root=Path(sys.argv[1]);source=root/'.tools/edk2/source';module=source/'PerpendicularDbxAuthProbe'
lock=json.loads((root/'scripts/secure-boot-dbx-sources.json').read_text())
artifact=lock['sources']['signed_dbx'];payload=(root/'.tools/downloads/microsoft-dbx'/artifact['filename']).read_bytes()
if hashlib.sha256(payload).hexdigest()!=artifact['sha256']:raise SystemExit('DBX Auth2 source hash mismatch')
module.mkdir(exist_ok=True)
notice=lock['sources']['license'];license_path=root/'.tools/downloads/microsoft-dbx'/notice['filename']
if hashlib.sha256(license_path.read_bytes()).hexdigest()!=notice['sha256']:raise SystemExit('Microsoft DBX license hash mismatch')
shutil.copyfile(license_path,module/'Microsoft-DBX-LICENSE.txt')
for name in ('DbxAuthProbe.c','DbxAuthProbe.inf'):shutil.copyfile(root/'scripts/firmware-tests'/name,module/name)
(module/'DbxAuth2Payload.h').write_text('// Generated from pinned Microsoft DBX. BSD-2-Clause-Patent.\nSTATIC CONST UINT8 mDbxAuth2Payload[] = {\n'+',\n'.join('  '+', '.join('0x%02x'%value for value in payload[offset:offset+16]) for offset in range(0,len(payload),16))+'\n};\n')
(module/'Probe.dsc').write_text((source/'ArmVirtPkg/ArmVirtQemu.dsc').read_text()+'\n[Components.AARCH64]\n  PerpendicularDbxAuthProbe/DbxAuthProbe.inf\n')
PY
export GCC5_AARCH64_PREFIX="${PERPENDICULAR_AARCH64_PREFIX:-/opt/homebrew/bin/aarch64-elf-}"
export PYTHON_COMMAND=/usr/bin/python3
export SOURCE_DATE_EPOCH=0
cd "$PERP_PROBE_SOURCE"
set +u
. ./edksetup.sh BaseTools >/dev/null
build -a AARCH64 -t GCC5 -b RELEASE -p PerpendicularDbxAuthProbe/Probe.dsc \
  -m PerpendicularDbxAuthProbe/DbxAuthProbe.inf -n 1 -D SECURE_BOOT_ENABLE=TRUE \
  -D TPM2_ENABLE=TRUE -D TPM2_CONFIG_ENABLE=TRUE -D FD_SIZE_IN_MB=3 \
  > "$PERP_PROBE_ROOT/.tools/edk2/dbx-auth-probe-build.log" 2>&1
echo "Built test-only DbxAuthProbe.efi with one build job; no runtime or VM changed."

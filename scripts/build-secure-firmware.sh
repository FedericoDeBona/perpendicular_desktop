#!/bin/bash
# Build the exact EDK2 snapshot shipped inside the verified QEMU source archive.
# Outputs remain under ignored .tools/edk2; this does not change existing VMs.
set -euo pipefail
PERP_FIRMWARE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PERP_FIRMWARE_WORK="$PERP_FIRMWARE_ROOT/.tools/edk2"
PERP_QEMU_VERSION=11.1.2
PERP_QEMU_SHA256=731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016
PERP_QEMU_ARCHIVE="$PERP_FIRMWARE_ROOT/.tools/downloads/qemu-$PERP_QEMU_VERSION.tar.xz"
PERP_EDK2_SOURCE="$PERP_FIRMWARE_WORK/source"
PERP_FIRMWARE_OUTPUT="$PERP_FIRMWARE_WORK/output"
PERP_FIRMWARE_TARGET="${PERPENDICULAR_FIRMWARE_TARGET:-RELEASE}"
PERP_FIRMWARE_JOBS="${PERPENDICULAR_BUILD_JOBS:-6}"
PERP_FIRMWARE_PYTHON="${PERPENDICULAR_FIRMWARE_PYTHON:-/usr/bin/python3}"
PERP_AARCH64_PREFIX="${PERPENDICULAR_AARCH64_PREFIX:-/opt/homebrew/bin/aarch64-elf-}"
[[ "$PERP_FIRMWARE_ROOT" != *[[:space:]]* ]] || { echo "EDK2 requires a workspace path without whitespace." >&2; exit 1; }
[[ "$PERP_FIRMWARE_TARGET" == RELEASE || "$PERP_FIRMWARE_TARGET" == DEBUG || "$PERP_FIRMWARE_TARGET" == NOOPT ]] || { echo "Invalid firmware build target." >&2; exit 1; }
[[ -x "${PERP_AARCH64_PREFIX}gcc" ]] || { echo "Install the ARM ELF cross compiler: brew install aarch64-elf-gcc acpica" >&2; exit 1; }
command -v iasl >/dev/null || { echo "Install the ACPI compiler: brew install acpica" >&2; exit 1; }
[[ -f "$PERP_QEMU_ARCHIVE" ]] || { echo "Run scripts/bootstrap.sh to acquire the pinned QEMU archive first." >&2; exit 1; }
[[ "$(shasum -a 256 "$PERP_QEMU_ARCHIVE" | awk '{print $1}')" == "$PERP_QEMU_SHA256" ]] || { echo "QEMU source checksum failed." >&2; exit 1; }
mkdir -p "$PERP_EDK2_SOURCE" "$PERP_FIRMWARE_OUTPUT"
tar -xOf "$PERP_QEMU_ARCHIVE" "qemu-$PERP_QEMU_VERSION/pc-bios/edk2-licenses.txt" > "$PERP_FIRMWARE_OUTPUT/edk2-licenses.txt"
if [[ ! -f "$PERP_EDK2_SOURCE/ArmVirtPkg/ArmVirtQemu.dsc" ]]; then
  tar -xf "$PERP_QEMU_ARCHIVE" -C "$PERP_EDK2_SOURCE" --strip-components=3 "qemu-$PERP_QEMU_VERSION/roms/edk2"
fi
rg -q 'OvmfPkg/QemuRamfbDxe/QemuRamfbDxe.inf' "$PERP_EDK2_SOURCE/ArmVirtPkg/ArmVirtQemuFvMain.fdf.inc"
# GCC 16 defaults to C23, where bool is a keyword. This EDK2 snapshot
# intentionally supplies its own BOOLEAN/bool definitions and expects GNU C11.
"$PERP_FIRMWARE_PYTHON" - "$PERP_EDK2_SOURCE/ArmVirtPkg/ArmVirtQemu.dsc" <<'PY'
import pathlib,sys
path=pathlib.Path(sys.argv[1]);data=path.read_bytes();marker=b'  GCC:*_GCC5_AARCH64_CC_FLAGS = -std=gnu11\r\n'
if marker not in data:
    data=data.replace(b'[BuildOptions]\r\n',b'[BuildOptions]\r\n'+marker,1)
    path.write_bytes(data)
PY
export GCC5_AARCH64_PREFIX="$PERP_AARCH64_PREFIX"
export PYTHON_COMMAND="$PERP_FIRMWARE_PYTHON"
export SOURCE_DATE_EPOCH=0
cd "$PERP_EDK2_SOURCE"
# Apple Clang now supplies UINT8_MAX through its SDK headers; the bundled
# BaseTools decompressor also defines it. Keep other host warnings as errors.
make -C BaseTools -j "$PERP_FIRMWARE_JOBS" EXTRA_OPTFLAGS=-Wno-error=macro-redefined > "$PERP_FIRMWARE_WORK/basetools.log" 2>&1
# EDK2's environment setup reads optional unset variables internally.
set +u
. ./edksetup.sh BaseTools > "$PERP_FIRMWARE_WORK/setup.log" 2>&1
set -u
build -a AARCH64 -t GCC5 -b "$PERP_FIRMWARE_TARGET" -p ArmVirtPkg/ArmVirtQemu.dsc \
  -n "$PERP_FIRMWARE_JOBS" -D SECURE_BOOT_ENABLE=TRUE -D TPM2_ENABLE=TRUE \
  -D TPM2_CONFIG_ENABLE=TRUE -D FD_SIZE_IN_MB=3 \
  > "$PERP_FIRMWARE_WORK/build.log" 2>&1
PERP_FIRMWARE_FV="$PERP_EDK2_SOURCE/Build/ArmVirtQemu-AARCH64/${PERP_FIRMWARE_TARGET}_GCC5/FV"
"$PERP_FIRMWARE_PYTHON" - "$PERP_FIRMWARE_FV" "$PERP_FIRMWARE_OUTPUT" <<'PY'
import pathlib,sys
source,output=map(pathlib.Path,sys.argv[1:])
for original,name in [('QEMU_EFI.fd','edk2-aarch64-secure-code.fd'),('QEMU_VARS.fd','edk2-arm-empty-vars.fd')]:
    data=(source/original).read_bytes()
    if not data or len(data)>64*1024*1024: raise SystemExit('Unexpected ARM firmware image size')
    (output/name).write_bytes(data+b'\xff'*(64*1024*1024-len(data)))
PY
PERP_ENROLLED_TEMPLATE="${PERPENDICULAR_ENROLLED_VARS:-$PERP_FIRMWARE_ROOT/.tools/qemu/share/qemu/edk2-arm-secure-vars.fd}"
if [[ -f "$PERP_ENROLLED_TEMPLATE" ]]; then
  PERP_FIRMWARE_IMAGE="${PERPENDICULAR_QEMU_IMG:-$PERP_FIRMWARE_ROOT/.tools/qemu/bin/qemu-img}"
  [[ -x "$PERP_FIRMWARE_IMAGE" ]] || { echo "qemu-img is needed to normalize enrolled variables." >&2; exit 1; }
  "$PERP_FIRMWARE_IMAGE" convert -O raw "$PERP_ENROLLED_TEMPLATE" "$PERP_FIRMWARE_OUTPUT/edk2-arm-secure-vars.fd"
  "$PERP_FIRMWARE_PYTHON" - "$PERP_FIRMWARE_OUTPUT/edk2-arm-empty-vars.fd" "$PERP_FIRMWARE_OUTPUT/edk2-arm-secure-vars.fd" <<'PY'
import json,pathlib,struct,subprocess,sys,uuid
empty,enrolled=map(pathlib.Path,sys.argv[1:]); baseline=empty.read_bytes();data=enrolled.read_bytes()
if len(data)!=64*1024*1024: raise SystemExit('Enrolled ARM variable bank must be64MiB')
if data[16:72]!=baseline[16:72] or data[72:100]!=baseline[72:100]:
    raise SystemExit('Enrolled variable store layout differs from the built EDK2 store')
variables={};position=100;limit=72+struct.unpack_from('<I',data,88)[0]
while position+60<=limit and data[position:position+2]==b'\xaa\x55':
    state=data[position+2];attributes=struct.unpack_from('<I',data,position+4)[0]
    name_size,data_size=struct.unpack_from('<II',data,position+36)
    if name_size<2 or name_size>4096 or position+60+name_size+data_size>limit: raise SystemExit('Invalid authenticated variable bounds')
    name=data[position+60:position+60+name_size].decode('utf-16-le').rstrip('\x00')
    # EDK2 VariableFormat.h uses ALIGNMENT=1 for name/data and aligns only
    # the following variable header to4bytes.
    payload=position+60+name_size
    if state==0x3f:variables[name]={'attributes':attributes,'size':data_size,'data':data[payload:payload+data_size]}
    position=(payload+data_size+3)&~3
for name in ('PK','KEK','db'):
    if name not in variables or not variables[name]['size']: raise SystemExit('Missing active enrolled '+name)
report={name:{key:value for key,value in entry.items() if key!='data'} for name,entry in variables.items() if name in ('PK','KEK','db','dbx','SecureBootEnable')}
if 'SecureBootEnable' in variables:report['SecureBootEnable']['value_hex']=variables['SecureBootEnable']['data'].hex()
certificates={}
for name in ('PK','KEK','db'):
    payload=variables[name]['data'];offset=0;certificates[name]=[]
    while offset+28<=len(payload):
        kind=uuid.UUID(bytes_le=payload[offset:offset+16]);size,header,signature=struct.unpack_from('<III',payload,offset+16)
        if size<28 or signature<16 or offset+size>len(payload):raise SystemExit('Invalid signature list in '+name)
        if kind==uuid.UUID('a5c059a1-94e4-4aa7-87b5-ab155c2bf072'):
            for item in range(offset+28+header,offset+size,signature):
                certificate=payload[item+16:item+signature]
                result=subprocess.run(['/usr/bin/openssl','x509','-inform','DER','-noout','-subject','-issuer'],input=certificate,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
                certificates[name].append(result.stdout.decode().strip())
        offset+=size
if not any('Microsoft' in certificate for certificate in certificates['db']):raise SystemExit('Enrolled db has no Microsoft X509 trust certificate')
report['x509_certificates']=certificates
(enrolled.parent/'enrolled-variable-summary.json').write_text(json.dumps(report,indent=2)+'\n')
print('Enrolled PK,KEK,db verified; guest SecureBoot remains a runtime check.')
PY
else
  echo "No enrolled variable template supplied. Empty variables are provided, but SecureBoot keys still need enrollment." >&2
fi
"$PERP_FIRMWARE_PYTHON" - "$PERP_FIRMWARE_OUTPUT" "$PERP_QEMU_SHA256" "$PERP_FIRMWARE_TARGET" "${PERP_AARCH64_PREFIX}gcc" "$PERP_ENROLLED_TEMPLATE" <<'PY'
import hashlib,json,pathlib,subprocess,sys
output=pathlib.Path(sys.argv[1]);files={path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in output.glob('*.fd')}
report={'source':'https://download.qemu.org/qemu-11.1.2.tar.xz','source_sha256':sys.argv[2],'platform':'ArmVirtPkg/ArmVirtQemu.dsc','target':sys.argv[3],
        'flags':{'SECURE_BOOT_ENABLE':True,'TPM2_ENABLE':True,'TPM2_CONFIG_ENABLE':True,'FD_SIZE_IN_MB':3},'ramfb_driver':'OvmfPkg/QemuRamfbDxe/QemuRamfbDxe.inf',
        'compiler':subprocess.check_output([sys.argv[4],'--version'],text=True).splitlines()[0],'compiler_compatibility':{'firmware_c_standard':'gnu11','host_apple_clang':'Wno-error=macro-redefined'},'files_sha256':files,'guest_secure_boot_verified':False}
template=pathlib.Path(sys.argv[5])
report['code_provenance']={'source_archive':report['source'],'source_archive_sha256':sys.argv[2],'license_aggregation':'edk2-licenses.txt'}
report['enrolled_variables_provenance']={'source_template_name':template.name,'source_template_sha256':hashlib.sha256(template.read_bytes()).hexdigest() if template.is_file() else None,
    'description':'Separately supplied enrolled variable template; default is TianoCore/UTM public PK and Microsoft2011/2023 trust certificates provisioned in the local QEMU firmware directory.',
    'default_upstream_project':'https://github.com/utmapp/UTM','normalization':'qemu-img convert -O raw; authenticated store layout and active PK/KEK/db are validated.','certificate_summary':'enrolled-variable-summary.json'}
(output/'build-manifest.json').write_text(json.dumps(report,indent=2)+'\n')
PY
echo "Secure ARM firmware built at $PERP_FIRMWARE_OUTPUT. No existing VM or installed runtime was changed."

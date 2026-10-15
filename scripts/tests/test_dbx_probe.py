"""Compile the real EFI probe with a host shim that writes SetVariable input."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROBE = Path(__file__).resolve().parents[1] / "firmware-tests/DbxAuthProbe.c"

HEADER = r'''
#ifndef TEST_UEFI_H
#define TEST_UEFI_H
#include <stdint.h>
#include <stddef.h>
#include <wchar.h>
typedef uint8_t UINT8;
typedef uint64_t UINT64;
typedef size_t UINTN;
typedef uint64_t EFI_STATUS;
typedef void VOID;
typedef void *EFI_HANDLE;
typedef wchar_t CHAR16;
typedef int EFI_GUID;
typedef int EFI_SYSTEM_TABLE;
#define STATIC static
#define CONST const
#define IN
#define OUT
#define EFIAPI
#define EFI_SUCCESS 0
#define EFI_BUFFER_TOO_SMALL (0x8000000000000000ULL | 5)
#define EFI_DEVICE_ERROR (0x8000000000000000ULL | 7)
#define EFI_OUT_OF_RESOURCES (0x8000000000000000ULL | 9)
#define EFI_SECURITY_VIOLATION (0x8000000000000000ULL | 26)
#define EFI_ERROR(Status) (((Status) >> 63) != 0)
typedef struct {
 EFI_STATUS (*GetVariable)(CHAR16 *, EFI_GUID *, void *, UINTN *, VOID *);
 EFI_STATUS (*SetVariable)(CHAR16 *, EFI_GUID *, unsigned int, UINTN, VOID *);
} EFI_RUNTIME_SERVICES;
extern EFI_RUNTIME_SERVICES *gRT;
extern EFI_GUID gEfiGlobalVariableGuid, gEfiImageSecurityDatabaseGuid;
VOID *AllocatePool(UINTN);
VOID *AllocateCopyPool(UINTN, const VOID *);
VOID FreePool(VOID *);
int CompareMem(const VOID *, const VOID *, UINTN);
UINTN Print(const CHAR16 *, ...);
#endif
'''

HARNESS = r'''
#include "Uefi.h"
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "PROBE_SOURCE"
EFI_GUID gEfiGlobalVariableGuid = 1, gEfiImageSecurityDatabaseGuid = 2;
static int calls, outstanding, fail_copy;
static UINT8 dbx[2] = {1, 2};
VOID *AllocatePool(UINTN n) { VOID *p = malloc(n); if (p) outstanding++; return p; }
VOID *AllocateCopyPool(UINTN n, const VOID *d) {
 if (fail_copy) return NULL;
 VOID *p = AllocatePool(n); if (p) memcpy(p, d, n); return p;
}
VOID FreePool(VOID *p) { if (p) { outstanding--; free(p); } }
int CompareMem(const VOID *a, const VOID *b, UINTN n) { return memcmp(a, b, n); }
UINTN Print(const CHAR16 *s, ...) { (void)s; return 0; }
static EFI_STATUS get(CHAR16 *name, EFI_GUID *guid, void *attr, UINTN *size, VOID *data) {
 (void)guid; (void)attr;
 if (wcscmp(name, L"SecureBoot") == 0) { *(UINT8 *)data = 1; return EFI_SUCCESS; }
 if (*size < sizeof(dbx)) { *size = sizeof(dbx); return EFI_BUFFER_TOO_SMALL; }
 memcpy(data, dbx, sizeof(dbx)); *size = sizeof(dbx); return EFI_SUCCESS;
}
static EFI_STATUS set(CHAR16 *name, EFI_GUID *guid, unsigned int attr, UINTN size, VOID *data) {
 UINT8 expected[sizeof(mDbxAuth2Payload)];
 assert(wcscmp(name, L"dbx") == 0 && guid == &gEfiImageSecurityDatabaseGuid && attr == 0x67);
 assert(size == sizeof(expected) && data != mDbxAuth2Payload);
 memcpy(expected, mDbxAuth2Payload, sizeof(expected));
 calls++;
 if (calls == 2) expected[sizeof(expected)-1] ^= 1;
 assert(memcmp(data, expected, sizeof(expected)) == 0);
 // Model EDK2's in-place duplicate filtering, including writes before return.
 ((UINT8 *)data)[sizeof(expected)-1] = 0xee;
 if (calls == 2) return EFI_SECURITY_VIOLATION;
 dbx[0] = 3;
 return EFI_SUCCESS;
}
static EFI_RUNTIME_SERVICES rt = {get, set};
EFI_RUNTIME_SERVICES *gRT = &rt;
int main(int argc, char **argv) {
 UINT8 original[sizeof(mDbxAuth2Payload)];
 (void)argv; fail_copy = argc > 1;
 memcpy(original, mDbxAuth2Payload, sizeof(original));
 EFI_STATUS status = UefiMain(NULL, NULL);
 assert(status == (fail_copy ? EFI_OUT_OF_RESOURCES : EFI_SUCCESS));
 assert(calls == (fail_copy ? 0 : 3));
 assert(memcmp(original, mDbxAuth2Payload, sizeof(original)) == 0);
 assert(outstanding == 0);
 return 0;
}
'''


@unittest.skipUnless(shutil.which("clang"), "requires host clang; no firmware execution")
class ProbeBufferTests(unittest.TestCase):
    def test_firmware_can_modify_each_call_buffer_without_changing_the_signed_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Uefi.h").write_text(HEADER)
            for name in ["Guid/GlobalVariable.h", "Guid/ImageAuthentication.h",
                         "Library/BaseMemoryLib.h", "Library/MemoryAllocationLib.h",
                         "Library/UefiLib.h", "Library/UefiRuntimeServicesTableLib.h"]:
                path = root / name
                path.parent.mkdir(exist_ok=True)
                path.write_text('#include "Uefi.h"\n')
            # A small non-secret fixture is enough to test writes and restoration.
            (root / "DbxAuth2Payload.h").write_text(
                "STATIC CONST UINT8 mDbxAuth2Payload[] = {0x11,0x22,0x33,0x44};\n")
            harness = root / "harness.c"
            harness.write_text(HARNESS.replace("PROBE_SOURCE", str(PROBE)))
            binary = root / "check"
            subprocess.run([shutil.which("clang"), "-std=c11", "-Werror=implicit-function-declaration",
                            "-I", str(root), str(harness), "-o", str(binary)],
                           check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, capture_output=True)
            subprocess.run([str(binary), "allocation-failure"], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()

// SPDX-License-Identifier: Apache-2.0
// Test-only EFI program. Run exclusively in a disposable firmware VM.
#include <Uefi.h>
#include <Guid/GlobalVariable.h>
#include <Guid/ImageAuthentication.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include "DbxAuth2Payload.h"

STATIC
EFI_STATUS
ReadDbx (OUT VOID **Buffer, OUT UINTN *Size)
{
  EFI_STATUS Status;
  *Size = 0;
  *Buffer = NULL;
  Status = gRT->GetVariable (L"dbx", &gEfiImageSecurityDatabaseGuid, NULL, Size, NULL);
  if ((Status != EFI_BUFFER_TOO_SMALL) || (*Size > 65536)) {
    return EFI_DEVICE_ERROR;
  }
  *Buffer = AllocatePool (*Size);
  if (*Buffer == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }
  return gRT->GetVariable (L"dbx", &gEfiImageSecurityDatabaseGuid, NULL, Size, *Buffer);
}

EFI_STATUS
EFIAPI
UefiMain (IN EFI_HANDLE ImageHandle, IN EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_STATUS Status;
  VOID       *Before;
  VOID       *After;
  VOID       *Checked;
  UINTN      BeforeSize;
  UINTN      AfterSize;
  UINTN      CheckedSize;
  UINT8      *Altered;
  UINT8      Value;
  UINTN      ValueSize;

  Print (L"PERP_AUTH2_PROBE_ENTERED\n");
  ValueSize = sizeof (Value);
  Status = gRT->GetVariable (L"SecureBoot", &gEfiGlobalVariableGuid, NULL, &ValueSize, &Value);
  Print (L"PERP_SECURE_BOOT=%u STATUS=%r\n", Value, Status);
  if (EFI_ERROR (Status) || (Value != 1)) {
    return EFI_SECURITY_VIOLATION;
  }
  Before = After = Checked = NULL;
  Status = ReadDbx (&Before, &BeforeSize);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  Status = gRT->SetVariable (L"dbx", &gEfiImageSecurityDatabaseGuid, 0x67,
                            sizeof (mDbxAuth2Payload), (VOID *)mDbxAuth2Payload);
  Print (L"PERP_AUTH2_ORIGINAL_STATUS=%r CODE=%Lx\n", Status, (UINT64)Status);
  if (EFI_ERROR (Status)) {
    FreePool (Before);
    return Status;
  }
  Status = ReadDbx (&After, &AfterSize);
  if (EFI_ERROR (Status)) {
    FreePool (Before);
    return Status;
  }
  Print (L"PERP_AUTH2_BYTES_BEFORE=%u AFTER=%u\n", BeforeSize, AfterSize);
  Altered = AllocateCopyPool (sizeof (mDbxAuth2Payload), mDbxAuth2Payload);
  if (Altered == NULL) {
    FreePool (Before);
    FreePool (After);
    return EFI_OUT_OF_RESOURCES;
  }
  Altered[sizeof (mDbxAuth2Payload) - 1] ^= 1;
  Status = gRT->SetVariable (L"dbx", &gEfiImageSecurityDatabaseGuid, 0x67,
                            sizeof (mDbxAuth2Payload), Altered);
  Print (L"PERP_AUTH2_TAMPER_STATUS=%r CODE=%Lx\n", Status, (UINT64)Status);
  Status = ReadDbx (&Checked, &CheckedSize);
  Print (L"PERP_AUTH2_TAMPER_UNCHANGED=%u\n",
         !EFI_ERROR (Status) && (AfterSize == CheckedSize)
         && (CompareMem (After, Checked, AfterSize) == 0));
  if (Checked != NULL) {
    FreePool (Checked);
    Checked = NULL;
  }
  Status = gRT->SetVariable (L"dbx", &gEfiImageSecurityDatabaseGuid, 0x67,
                            sizeof (mDbxAuth2Payload), (VOID *)mDbxAuth2Payload);
  Print (L"PERP_AUTH2_REPLAY_STATUS=%r CODE=%Lx\n", Status, (UINT64)Status);
  Status = ReadDbx (&Checked, &CheckedSize);
  Print (L"PERP_AUTH2_REPLAY_UNCHANGED=%u\n",
         !EFI_ERROR (Status) && (AfterSize == CheckedSize)
         && (CompareMem (After, Checked, AfterSize) == 0));
  Print (L"PERP_AUTH2_PROBE_DONE\n");
  FreePool (Altered);
  FreePool (Before);
  FreePool (After);
  if (Checked != NULL) {
    FreePool (Checked);
  }
  return EFI_SUCCESS;
}

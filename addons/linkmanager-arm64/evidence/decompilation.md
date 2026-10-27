# Pseudocodice recuperato da REA/Ghidra

Derivato dai record originali in [rea/](rea/). È pseudocodice di analisi, non sorgente originale né codice pronto da compilare. Warning e limiti integrali rimangono nei JSON. I percorsi locali presenti nei record descrivono il computer della cattura; per gli input portabili usare [artifacts/](../artifacts/) e il manifesto. Nessun programma Windows è stato eseguito.

## LinkManagerSvc.exe — 0x140003020

[011-tools-call.json](rea/011-tools-call.json) · `ev_fec94c9135ca5c7cbf67b6c550d2245c11409f4f5c16936f6a2f7822f0cacc56`

```c
/* WARNING: Function: __chkstk replaced with injection: alloca_probe */
/* WARNING: Function: __security_check_cookie replaced with injection: security_check_cookie */
/* WARNING: Removing unreachable block (ram,0x000140003748) */
/* WARNING: Removing unreachable block (ram,0x000140003542) */
/* WARNING: Removing unreachable block (ram,0x0001400039f6) */
/* WARNING: Removing unreachable block (ram,0x0001400034d6) */
/* WARNING: Removing unreachable block (ram,0x000140003228) */
/* WARNING: Removing unreachable block (ram,0x00014000312b) */
/* WARNING: Removing unreachable block (ram,0x00014000319b) */
/* WARNING: Removing unreachable block (ram,0x00014000328c) */
/* WARNING: Removing unreachable block (ram,0x0001400032f6) */
/* WARNING: Removing unreachable block (ram,0x000140003883) */
/* WARNING: Removing unreachable block (ram,0x00014000390d) */
/* WARNING: Removing unreachable block (ram,0x00014000381a) */
/* WARNING: Removing unreachable block (ram,0x000140003be9) */
/* WARNING: Removing unreachable block (ram,0x000140003629) */
/* WARNING: Removing unreachable block (ram,0x000140003692) */
/* WARNING: Removing unreachable block (ram,0x0001400035ab) */
/* WARNING: Removing unreachable block (ram,0x0001400037b1) */

int FUN_140003020(char *param_1,undefined1 *param_2,undefined8 *param_3)

{
  bool bVar1;
  bool bVar2;
  bool bVar3;
  DWORD DVar4;
  BOOL BVar5;
  int iVar6;
  size_t sVar7;
  char *pcVar8;
  undefined1 *puVar9;
  longlong lVar10;
  undefined1 *puVar11;
  undefined1 auStackY_2a58 [32];
  _SP_DEVINFO_DATA local_2a00;
  OLECHAR local_29d8 [56];
  HDEVINFO local_2968;
  uint local_2960;
  int local_295c;
  DWORD local_2958 [2];
  HKEY local_2950;
  BOOL local_2948;
  GUID local_2940;
  PSP_DRVINFO_DETAIL_DATA_A local_2930;
  DWORD local_2928;
  _SP_DEVINSTALL_PARAMS_A local_2918;
  CHAR local_27d8 [272];
  _SP_DRVINFO_DETAIL_DATA_A local_26c8 [10];
  _SP_DRVINFO_DATA_V2_A local_6c8;
  int local_3a8;
  int local_3a4;
  DWORD local_3a0;
  BOOL local_39c;
  _SP_DRVINFO_DATA_V2_A *local_398;
  wchar_t local_388 [256];
  char local_188 [256];
  CHAR local_88 [40];
  undefined1 local_60 [16];
  undefined1 local_50 [16];
  undefined1 local_40 [16];
  char *local_30;
  ulonglong local_28;
  undefined8 uStack_18;
  
  uStack_18 = 0x14000303b;
  local_28 = DAT_1400232d0 ^ (ulonglong)auStackY_2a58;
  local_295c = 0;
  local_2968 = (HDEVINFO)0xffffffffffffffff;
  local_2960 = 0;
  bVar1 = false;
  bVar2 = false;
  bVar3 = false;
  local_2928 = 0;
  local_2950 = (HKEY)0x0;
  local_2a00.cbSize = 0x20;
  local_6c8.cbSize = 800;
  memcpy(&local_2940,&DAT_14001e210,0x10);
  local_2968 = SetupDiCreateDeviceInfoList(&local_2940,(HWND)0x0);
  if (local_2968 == (HDEVINFO)0xffffffffffffffff) {
    DVar4 = GetLastError();
    _snprintf(&DAT_1400249b0,0x100,"SetupDiCreateDeviceInfoList failed (0x%08X)",(ulonglong)DVar4);
    local_295c = 1;
  }
  else {
    local_2948 = SetupDiClassNameFromGuidA(&local_2940,local_27d8,0x104,(PDWORD)0x0);
    if (local_2948 == 0) {
      DVar4 = GetLastError();
      _snprintf(&DAT_1400249b0,0x100,"SetupDiClassNameFromGuid failed (0x%08X)",(ulonglong)DVar4);
      local_295c = 1;
    }
    else {
      local_2948 = SetupDiCreateDeviceInfoA
                             (local_2968,local_27d8,&local_2940,(PCSTR)0x0,(HWND)0x0,1,&local_2a00);
      if (local_2948 == 0) {
        DVar4 = GetLastError();
        _snprintf(&DAT_1400249b0,0x100,"SetupDiCreateDeviceInfo failed (0x%08X)",(ulonglong)DVar4);
        local_295c = 1;
      }
      else {
        local_2948 = SetupDiSetSelectedDevice(local_2968,&local_2a00);
        if (local_2948 == 0) {
          DVar4 = GetLastError();
          _snprintf(&DAT_1400249b0,0x100,"SetupDiSetSelectedDevice failed (0x%08X)",(ulonglong)DVar4
                   );
          local_295c = 1;
        }
        else {
          local_2948 = SetupDiBuildDriverInfoList(local_2968,&local_2a00,1);
          if (local_2948 != 0) {
            bVar3 = true;
LAB_140003304:
            while (local_39c = SetupDiEnumDriverInfoA
                                         (local_2968,&local_2a00,1,local_2928,&local_6c8),
                  local_39c == 0) {
              DVar4 = GetLastError();
              if (DVar4 == 0x103) goto LAB_14000349e;
              local_2928 = local_2928 + 1;
            }
            local_2930 = local_26c8;
            local_26c8[0].cbSize = 0x328;
            BVar5 = SetupDiGetDriverInfoDetailA
                              (local_2968,&local_2a00,&local_6c8,local_2930,0x2000,(PDWORD)0x0);
            if (BVar5 != 0) {
              local_398 = (_SP_DRVINFO_DATA_V2_A *)local_2930->HardwareID;
              while ((((local_398 != (_SP_DRVINFO_DATA_V2_A *)0x0 &&
                       ((char)local_398->cbSize != '\0')) && (local_398 < &local_6c8)) &&
                     (iVar6 = _stricmp((char *)local_398,"lmtap"), iVar6 != 0))) {
                sVar7 = strlen((char *)local_398);
                local_398 = (_SP_DRVINFO_DATA_V2_A *)(local_398->Description + (sVar7 - 0xf));
              }
              if (((local_398 != (_SP_DRVINFO_DATA_V2_A *)0x0) && ((char)local_398->cbSize != '\0'))
                 && (local_398 < &local_6c8)) {
                bVar1 = true;
LAB_14000349e:
                if (bVar1) {
                  local_2948 = SetupDiSetSelectedDriverA(local_2968,&local_2a00,&local_6c8);
                  if (local_2948 == 0) {
                    DVar4 = GetLastError();
                    _snprintf(&DAT_1400249b0,0x100,"SetupDiSetSelectedDriver failed (0x%08X)",
                              (ulonglong)DVar4);
                    local_295c = 1;
                  }
                  else {
                    local_2948 = SetupDiCallClassInstaller(0x19,local_2968,&local_2a00);
                    if (local_2948 == 0) {
                      DVar4 = GetLastError();
                      _snprintf(&DAT_1400249b0,0x100,"SetupDiCallClassInstaller failed (0x%08X)",
                                (ulonglong)DVar4);
                      local_295c = 1;
                    }
                    else {
                      bVar2 = true;
                      local_2948 = SetupDiCallClassInstaller(0x18,local_2968,&local_2a00);
                      if ((local_2948 == 0) && (DVar4 = GetLastError(), DVar4 != 0xe000020e)) {
                        DVar4 = GetLastError();
                        _snprintf(&DAT_1400249b0,0x100,
                                  "SetupDiCallClassInstaller (DIF_ALLOW_INSTALL) failed (0x%08X)",
                                  (ulonglong)DVar4);
                        local_295c = 1;
                      }
                      else {
                        local_2948 = SetupDiCallClassInstaller(0x15,local_2968,&local_2a00);
                        if (local_2948 == 0) {
                          DVar4 = GetLastError();
                          _snprintf(&DAT_1400249b0,0x100,
                                    "SetupDiCallClassInstaller (DIF_INSTALLDEVICEFILES) failed (0x%08X)"
                                    ,(ulonglong)DVar4);
                          local_295c = 1;
                        }
                        else {
                          local_2918.cbSize = 0x140;
                          local_2948 = SetupDiGetDeviceInstallParamsA
                                                 (local_2968,&local_2a00,&local_2918);
                          if (local_2948 != 0) {
                            local_2918.Flags = local_2918.Flags | 0x1000000;
                            local_2948 = SetupDiSetDeviceInstallParamsA
                                                   (local_2968,&local_2a00,&local_2918);
                            if (local_2948 == 0) {
                              DVar4 = GetLastError();
                              _snprintf(&DAT_1400249b0,0x100,
                                        "SetupDiSetDeviceInstallParams failed (0x%08X)",
                                        (ulonglong)DVar4);
                              local_295c = 1;
                              goto LAB_140003bf9;
                            }
                          }
                          local_2948 = SetupDiCallClassInstaller(0x22,local_2968,&local_2a00);
                          if (local_2948 == 0) {
                            DVar4 = GetLastError();
                            _snprintf(&DAT_1400249b0,0x100,
                                      "SetupDiCallClassInstaller (DIF_REGISTER_COINSTALLERS) failed (0x%08X)"
                                      ,(ulonglong)DVar4);
                            local_295c = 1;
                          }
                          else {
                            local_2948 = SetupDiCallClassInstaller(0x20,local_2968,&local_2a00);
                            if (local_2948 == 0) {
                              DVar4 = GetLastError();
                              _snprintf(&DAT_1400249b0,0x100,
                                        "SetupDiCallClassInstaller (DIF_INSTALLINTERFACES) failed (0x%08X)"
                                        ,(ulonglong)DVar4);
                              local_295c = 1;
                            }
                            else {
                              local_2948 = SetupDiCallClassInstaller(2,local_2968,&local_2a00);
                              if (local_2948 == 0) {
                                DVar4 = GetLastError();
                                _snprintf(&DAT_1400249b0,0x100,
                                          "SetupDiCallClassInstaller (DIF_INSTALLDEVICE) failed (0x%08X)"
                                          ,(ulonglong)DVar4);
                                local_295c = 1;
                              }
                              else {
                                Sleep(1000);
                                local_2950 = SetupDiOpenDevRegKey
                                                       (local_2968,&local_2a00,1,0,2,0x20019);
                                if (local_2950 == (HKEY)0xffffffffffffffff) {
                                  DVar4 = GetLastError();
                                  _snprintf(&DAT_1400249b0,0x100,
                                            "SetupDiOpenDevRegKey failed (0x%08X)",(ulonglong)DVar4)
                                  ;
                                  local_295c = 1;
                                }
                                else {
                                  FUN_140009b90((ulonglong *)local_29d8,0,100);
                                  local_2958[0] = 100;
                                  local_3a4 = 0;
                                  while( true ) {
                                    while ((local_2960 = RegQueryValueExW(local_2950,
                                                                          L"NetCfgInstanceId",
                                                                          (LPDWORD)0x0,&local_3a0,
                                                                          (LPBYTE)local_29d8,
                                                                          local_2958),
                                           local_2960 == 2 &&
                                           (iVar6 = local_3a4 + 1, bVar1 = local_3a4 < 100,
                                           local_3a4 = iVar6, bVar1))) {
                                      Sleep(100);
                                    }
                                    if (local_2960 != 0) {
                                      _snprintf(&DAT_1400249b0,0x100,
                                                "RegQueryValueEx (NetCfgInstanceId) failed (0x%08X)"
                                                ,(ulonglong)local_2960);
                                      local_295c = 1;
                                      goto LAB_140003bf9;
                                    }
                                    local_3a8 = 0;
                                    local_2960 = 0;
                                    do {
                                      if (local_3a8 == 0) {
                                        local_30 = "%s";
                                      }
                                      else {
                                        local_30 = "%s #%d";
                                      }
                                      _snprintf(local_188,0x100,local_30);
                                      mbstowcs(local_388,local_188,0x100);
                                      local_2960 = FUN_140003d60(local_29d8,local_388);
                                      if ((local_2960 == 0) &&
                                         (pcVar8 = strstr(param_1," L2 "), pcVar8 != (char *)0x0)) {
                                        FUN_1400021d0(0xffffffff,0x8000000,
                                                                                                            
                                                  "netsh interface ip set interface \"%s\" metric=9999"
                                                  ,local_188);
                                        FUN_1400021d0(0xffffffff,0x8000000,
                                                                                                            
                                                  "netsh interface ipv6 set interface \"%s\" metric=9999"
                                                  ,local_188);
                                      }
                                    } while ((local_2960 == 0x80070034) &&
                                            (local_3a8 = local_3a8 + 1, local_3a8 < 100));
                                    if (((local_2960 != 0x800401f3) &&
                                        (((local_2960 != 1 && (local_2960 != 0x80070002)) &&
                                         (local_2960 != 0x80071a2d)))) ||
                                       (iVar6 = local_3a4 + 1, bVar1 = 99 < local_3a4,
                                       local_3a4 = iVar6, bVar1)) break;
                                    Sleep(100);
                                  }
                                  RegCloseKey(local_2950);
                                  if (local_2960 != 0) {
                                    _snprintf(&DAT_1400249b0,0x100,
                                              "Failed to set interface name (ret=0x%08X, pCfgGuidString=\'%ls\', cbSize=%d)"
                                              ,(ulonglong)local_2960);
                                    local_295c = 1;
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
                else {
                  _snprintf(&DAT_1400249b0,0x100,
                            "Could not find LinkManager Adapter driver! Please reinstall");
                  local_295c = 1;
                }
                goto LAB_140003bf9;
              }
            }
            local_2928 = local_2928 + 1;
            goto LAB_140003304;
          }
          DVar4 = GetLastError();
          _snprintf(&DAT_1400249b0,0x100,"SetupDiBuildDriverInfoList failed (0x%08X)",
                    (ulonglong)DVar4);
          local_295c = 1;
        }
      }
    }
  }
LAB_140003bf9:
  if (local_2968 != (HDEVINFO)0xffffffffffffffff) {
    if ((local_2960 != 0) && (bVar2)) {
      SetupDiCallClassInstaller(5,local_2968,&local_2a00);
    }
    SetupDiDeleteDeviceInfo(local_2968,&local_2a00);
    if (bVar3) {
      SetupDiDestroyDriverInfoList(local_2968,&local_2a00,1);
    }
    SetupDiDestroyDeviceInfoList(local_2968);
  }
  if (local_295c == 0) {
    if (param_3 != (undefined8 *)0x0) {
      *param_3 = 0;
    }
    if (param_2 != (undefined1 *)0x0) {
      FUN_14000c504(local_88,local_29d8,0x28);
      puVar9 = FUN_140002540(local_50,local_88);
      puVar11 = local_40;
      for (lVar10 = 0x10; lVar10 != 0; lVar10 = lVar10 + -1) {
        *puVar11 = *puVar9;
        puVar9 = puVar9 + 1;
        puVar11 = puVar11 + 1;
      }
      puVar9 = local_40;
      puVar11 = local_60;
      for (lVar10 = 0x10; lVar10 != 0; lVar10 = lVar10 + -1) {
        *puVar11 = *puVar9;
        puVar9 = puVar9 + 1;
        puVar11 = puVar11 + 1;
      }
      puVar9 = local_60;
      for (lVar10 = 0x10; lVar10 != 0; lVar10 = lVar10 + -1) {
        *param_2 = *puVar9;
        puVar9 = puVar9 + 1;
        param_2 = param_2 + 1;
      }
    }
  }
  else if (param_3 != (undefined8 *)0x0) {
    *param_3 = &DAT_1400249b0;
  }
  return local_295c;
}
```

## LinkManagerSvc.exe — 0x140005a50

[012-tools-call.json](rea/012-tools-call.json) · `ev_c6885e5f90584f04ce7819489258e5ec07856f4ab5782872f926f645f13e2856`

```c
/* WARNING: Function: __security_check_cookie replaced with injection: security_check_cookie */
/* WARNING: Removing unreachable block (ram,0x000140005b4e) */
/* WARNING: Removing unreachable block (ram,0x000140005c96) */
/* WARNING: Removing unreachable block (ram,0x000140005bee) */

int FUN_140005a50(undefined1 *param_1,undefined4 param_2,undefined8 *param_3)

{
  HANDLE hDevice;
  longlong lVar1;
  uint *puVar2;
  undefined4 local_res10 [2];
  undefined8 *local_res18;
  undefined1 auStackY_2d8 [32];
  int local_288;
  char local_280 [40];
  char local_258 [512];
  uint local_58 [4];
  DWORD local_48;
  BOOL local_44;
  uint local_38 [4];
  ulonglong local_28;
  
  local_28 = DAT_1400232d0 ^ (ulonglong)auStackY_2d8;
  local_288 = 0;
  puVar2 = local_38;
  for (lVar1 = 0x10; lVar1 != 0; lVar1 = lVar1 + -1) {
    *(undefined1 *)puVar2 = *param_1;
    param_1 = param_1 + 1;
    puVar2 = (uint *)((longlong)puVar2 + 1);
  }
  local_res10[0] = param_2;
  local_res18 = param_3;
  FUN_140002710(local_38,local_280);
  sprintf(local_258,"\\\\.\\Global\\%s.tap",local_280);
  hDevice = CreateFileA(local_258,0xc0000000,3,(LPSECURITY_ATTRIBUTES)0x0,3,4,(HANDLE)0x0);
  if (hDevice == (HANDLE)0xffffffffffffffff) {
    GetLastError();
    _snprintf(&DAT_1400249b0,0x100,"Could not open host interface device %s (0x%08X)",local_258);
    local_288 = 1;
  }
  else {
    local_44 = DeviceIoControl(hDevice,0x220008,local_58,0xc,local_58,0xc,&local_48,
                               (LPOVERLAPPED)0x0);
    if (local_44 == 0) {
      GetLastError();
      _snprintf(&DAT_1400249b0,0x100,"DeviceIOControl for host interface device %s failed (0x%08X)",
                local_258);
      local_288 = 1;
    }
    else if ((local_58[0] < 9) &&
            (local_44 = DeviceIoControl(hDevice,0x22002c,local_res10,4,(LPVOID)0x0,0,&local_48,
                                        (LPOVERLAPPED)0x0), local_44 == 0)) {
      GetLastError();
      _snprintf(&DAT_1400249b0,0x100,"DeviceIOControl for host interface device %s failed (0x%08X)",
                local_258);
      local_288 = 1;
    }
  }
  if (hDevice != (HANDLE)0xffffffffffffffff) {
    CloseHandle(hDevice);
  }
  if ((local_288 != 0) && (local_res18 != (undefined8 *)0x0)) {
    *local_res18 = &DAT_1400249b0;
  }
  return local_288;
}
```

## LinkManagerTray.exe — 0x140088360

[019-tools-call.json](rea/019-tools-call.json) · `ev_5be40ab74e7bd5ae004617a3d21c2677ef733bb3ab03585b73d8f7f62ebe10d3`

```c
/* WARNING: Function: __security_check_cookie replaced with injection: security_check_cookie */
/* WARNING: Removing unreachable block (ram,0x00014008845e) */
/* WARNING: Removing unreachable block (ram,0x0001400885a6) */
/* WARNING: Removing unreachable block (ram,0x0001400884fe) */

int FUN_140088360(undefined1 *param_1,undefined4 param_2,undefined8 *param_3)

{
  HANDLE hDevice;
  longlong lVar1;
  uint *puVar2;
  undefined4 local_res10 [2];
  undefined8 *local_res18;
  undefined1 auStackY_2d8 [32];
  int local_288;
  char local_280 [40];
  char local_258 [512];
  uint local_58 [4];
  DWORD local_48;
  BOOL local_44;
  uint local_38 [4];
  ulonglong local_28;
  
  local_28 = DAT_140103b40 ^ (ulonglong)auStackY_2d8;
  local_288 = 0;
  puVar2 = local_38;
  for (lVar1 = 0x10; lVar1 != 0; lVar1 = lVar1 + -1) {
    *(undefined1 *)puVar2 = *param_1;
    param_1 = param_1 + 1;
    puVar2 = (uint *)((longlong)puVar2 + 1);
  }
  local_res10[0] = param_2;
  local_res18 = param_3;
  FUN_140085020(local_38,local_280);
  sprintf(local_258,"\\\\.\\Global\\%s.tap",local_280);
  hDevice = CreateFileA(local_258,0xc0000000,3,(LPSECURITY_ATTRIBUTES)0x0,3,4,(HANDLE)0x0);
  if (hDevice == (HANDLE)0xffffffffffffffff) {
    GetLastError();
    _snprintf(&DAT_140106f10,0x100,"Could not open host interface device %s (0x%08X)",local_258);
    local_288 = 1;
  }
  else {
    local_44 = DeviceIoControl(hDevice,0x220008,local_58,0xc,local_58,0xc,&local_48,
                               (LPOVERLAPPED)0x0);
    if (local_44 == 0) {
      GetLastError();
      _snprintf(&DAT_140106f10,0x100,"DeviceIOControl for host interface device %s failed (0x%08X)",
                local_258);
      local_288 = 1;
    }
    else if ((local_58[0] < 9) &&
            (local_44 = DeviceIoControl(hDevice,0x22002c,local_res10,4,(LPVOID)0x0,0,&local_48,
                                        (LPOVERLAPPED)0x0), local_44 == 0)) {
      GetLastError();
      _snprintf(&DAT_140106f10,0x100,"DeviceIOControl for host interface device %s failed (0x%08X)",
                local_258);
      local_288 = 1;
    }
  }
  if (hDevice != (HANDLE)0xffffffffffffffff) {
    CloseHandle(hDevice);
  }
  if ((local_288 != 0) && (local_res18 != (undefined8 *)0x0)) {
    *local_res18 = &DAT_140106f10;
  }
  return local_288;
}
```

## LinkManagerTray.exe — 0x140095e70

[022-tools-call.json](rea/022-tools-call.json) · `ev_e5927989f223ee42152eacc6c9a488bdc51f60962caf66092708f0fe268407a6`

```c
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */

DWORD FUN_140095e70(HANDLE param_1,undefined8 param_2,undefined8 param_3,undefined8 param_4)

{
  DWORD DVar1;
  HANDLE pvVar2;
  undefined8 uVar3;
  int *piVar4;
  code *pcVar5;
  undefined4 local_b88;
  int local_b84;
  DWORD local_b80;
  DWORD local_b7c;
  LPCVOID local_b78;
  int local_b70;
  int local_b6c;
  DWORD local_b68 [2];
  int local_b60;
  uint local_b58 [4];
  ulonglong local_b48 [361];
  
  local_b7c = 0;
  DAT_140107060 = malloc(0x600);
  if (DAT_140107060 == (void *)0x0) {
    FUN_140006090(s_cannot_allocate_buffer_140103920,param_2,param_3,param_4);
    local_b7c = 8;
  }
  else {
    _DAT_140107068 = 0;
    _DAT_140107070 = 0;
    DAT_1401070d8 = DAT_140106898;
    _DAT_140107078 = param_1;
    DAT_140107080 = param_1;
    FUN_1400a3660((ulonglong *)&DAT_140107180,0,0x80);
    for (local_b84 = 1; local_b84 < 4; local_b84 = local_b84 + 1) {
      pvVar2 = CreateEventA((LPSECURITY_ATTRIBUTES)0x0,1,0,(LPCSTR)0x0);
      (&DAT_1401070d8)[local_b84] = pvVar2;
      *(HANDLE *)(&DAT_140107198 + (longlong)local_b84 * 0x20) = (&DAT_1401070d8)[local_b84];
    }
    local_b88 = 1;
    DeviceIoControl(param_1,0x220018,&local_b88,4,(LPVOID)0x0,0,&local_b80,(LPOVERLAPPED)0x0);
    EnterCriticalSection((LPCRITICAL_SECTION)&DAT_140107088);
    while (DVar1 = WaitForSingleObject(DAT_1401070d8,0), DVar1 != 0) {
      pcVar5 = FUN_1400965a0;
      piVar4 = (int *)0x600;
      uVar3 = FUN_1400965e0(2,DAT_140107060,0x600,FUN_1400965a0);
      local_b6c = (int)uVar3;
      if (local_b6c < 0) {
        local_b7c = GetLastError();
        break;
      }
      local_b60 = 0;
      local_b78 = (LPCVOID)FUN_140096a00((longlong *)local_b68);
      if (local_b78 != (LPCVOID)0x0) {
        ResetEvent(DAT_1401070e0);
        uVar3 = FUN_1400964e0(local_b78,local_b68[0]);
        local_b60 = (int)uVar3;
        if (local_b60 < 0) {
          local_b7c = GetLastError();
          free(local_b78);
          break;
        }
        free(local_b78);
      }
      FUN_140096250((int *)&DAT_140107148);
      local_b70 = FUN_140096340();
      FUN_140096310(0x140107148);
      if (((local_b6c == 0) && (local_b60 == 0)) && (local_b70 == 0)) {
        local_b58[0] = 0x3c;
        local_b58[1] = 0;
        FUN_140050390(local_b48);
        FUN_14009bb60(DAT_1401081e8,(longlong)local_b48,piVar4,pcVar5);
        if (*(longlong *)(DAT_1401081e8 + 0x520) == 0) {
          if (*(int *)(DAT_1401081e8 + 0x530) != 0) {
            local_b58[0] = 0;
            local_b58[1] = 500000;
          }
        }
        else {
          local_b58[0] = 0;
          local_b58[1] = 5000;
        }
        FUN_140050660((longlong)local_b48,DAT_1401070d8,piVar4,pcVar5);
        FUN_140050660((longlong)local_b48,DAT_1401070e0,piVar4,pcVar5);
        FUN_140050660((longlong)local_b48,DAT_1401070e8,piVar4,pcVar5);
        FUN_140050660((longlong)local_b48,DAT_140107178,piVar4,pcVar5);
        LeaveCriticalSection((LPCRITICAL_SECTION)&DAT_140107088);
        FUN_140050a50((int *)local_b48,local_b58,piVar4,(int *)pcVar5);
        EnterCriticalSection((LPCRITICAL_SECTION)&DAT_140107088);
        FUN_14009bdf0(DAT_1401081e8,local_b48,piVar4,(ulonglong *)pcVar5);
      }
    }
    LeaveCriticalSection((LPCRITICAL_SECTION)&DAT_140107088);
    local_b88 = 0;
    DeviceIoControl(param_1,0x220018,&local_b88,4,(LPVOID)0x0,0,&local_b80,(LPOVERLAPPED)0x0);
    free(DAT_140107060);
  }
  return local_b7c;
}
```

## LinkManagerTray.exe — 0x1400964e0

[024-tools-call.json](rea/024-tools-call.json) · `ev_2891ef5791c3ff6675f46f1bcb08473722feba50411f6c88fc9a1249c68aea98`

```c
undefined8 FUN_1400964e0(LPCVOID param_1,DWORD param_2)

{
  DWORD DVar1;
  undefined8 uVar2;
  int local_14;
  DWORD local_10 [4];
  
  local_10[0] = 0;
  local_14 = WriteFile(DAT_140107080,param_1,param_2,local_10,(LPOVERLAPPED)&DAT_1401071e0);
  if (local_14 == 0) {
    DVar1 = GetLastError();
    if (DVar1 == 0x3e5) {
      local_14 = GetOverlappedResult(DAT_140107080,(LPOVERLAPPED)&DAT_1401071e0,local_10,1);
    }
  }
  if ((local_14 == 0) || (local_10[0] != param_2)) {
    uVar2 = 0xffffffff;
  }
  else {
    uVar2 = 1;
  }
  return uVar2;
}
```

## LinkManagerTray.exe — 0x1400965e0

[025-tools-call.json](rea/025-tools-call.json) · `ev_6572e59f63feb78090a9175e2ff1aba93f191c7d7f75234cbe987edcee3d18ed`

```c
undefined8 FUN_1400965e0(int param_1,LPVOID param_2,uint param_3,undefined *param_4)

{
  undefined8 uVar1;
  LPDWORD pDVar2;
  ulonglong uVar3;
  DWORD local_18;
  int local_14;
  DWORD local_10;
  DWORD local_c;
  
  uVar1 = FUN_140096790(param_1);
  local_14 = (int)uVar1;
  local_18 = 0;
  if (local_14 == 1) {
    uVar1 = 0;
  }
  else if (local_14 == 2) {
    uVar1 = 1;
    pDVar2 = &local_18;
    local_10 = GetOverlappedResult(*(HANDLE *)(&DAT_140107068 + (longlong)param_1 * 8),
                                   (LPOVERLAPPED)(&DAT_140107180 + (longlong)param_1 * 0x20),pDVar2,
                                   1);
    if (local_10 == 0) {
      local_c = GetLastError();
      if (local_c == 0x3e3) {
        FUN_140006130(s_GetOverlappedResult_failed___ld__1401038c0,0x3e3,
                      s__normal_after_wakeup__1401038a8,uVar1);
      }
      else {
        FUN_140006090(s_GetOverlappedResult_failed___ld_1401038e8,(ulonglong)local_c,pDVar2,uVar1);
      }
      SetLastError(local_c);
      uVar1 = 0xffffffff;
    }
    else {
      ResetEvent(*(HANDLE *)(&DAT_140107198 + (longlong)param_1 * 0x20));
      uVar1 = (*(code *)param_4)(param_2,local_18);
    }
  }
  else {
    pDVar2 = &local_18;
    uVar3 = (ulonglong)param_3;
    local_10 = ReadFile(*(HANDLE *)(&DAT_140107068 + (longlong)param_1 * 8),param_2,param_3,pDVar2,
                        (LPOVERLAPPED)(&DAT_140107180 + (longlong)param_1 * 0x20));
    if (local_10 == 0) {
      local_10 = GetLastError();
      if (local_10 == 0x3e5) {
        uVar1 = 0;
      }
      else {
        FUN_140006090(s_ReadFile_failed___ld_140103908,(ulonglong)local_10,uVar3,pDVar2);
        uVar1 = 0xffffffff;
      }
    }
    else {
      ResetEvent(*(HANDLE *)(&DAT_140107198 + (longlong)param_1 * 0x20));
      uVar1 = (*(code *)param_4)(param_2,local_18);
    }
  }
  return uVar1;
}
```

## LinkManagerTray.exe — 0x1400967f0

[029-tools-call.json](rea/029-tools-call.json) · `ev_3352ace05ac070709a376c41a70d5c9a5b09f0b4471f5483d2a20d311ee5a9ba`

```c
/* WARNING: Function: __security_check_cookie replaced with injection: security_check_cookie */

HANDLE FUN_1400967f0(undefined8 param_1)

{
  HANDLE pvVar1;
  undefined1 auStackY_e8 [32];
  char local_98 [128];
  ulonglong local_18;
  
  local_18 = DAT_140103b40 ^ (ulonglong)auStackY_e8;
  _snprintf(local_98,0x80,s_____Global__s_tap_140103938,param_1);
  pvVar1 = CreateFileA(local_98,0xc0000000,3,(LPSECURITY_ATTRIBUTES)0x0,3,0x40000004,(HANDLE)0x0);
  return pvVar1;
}
```

## LinkManagerTray.exe — 0x1400869c0

[030-tools-call.json](rea/030-tools-call.json) · `ev_297afdd0ac24cad7f3fdf2717f6065a453dece4b243f1c9309bab381086f2322`

```c
/* WARNING: Function: __security_check_cookie replaced with injection: security_check_cookie */
/* WARNING: Removing unreachable block (ram,0x000140086bf3) */
/* WARNING: Removing unreachable block (ram,0x000140086add) */
/* WARNING: Removing unreachable block (ram,0x000140086cfb) */
/* WARNING: Removing unreachable block (ram,0x000140086ff6) */
/* WARNING: Removing unreachable block (ram,0x000140086b5d) */
/* WARNING: Removing unreachable block (ram,0x000140087057) */
/* WARNING: Removing unreachable block (ram,0x0001400870bd) */

int FUN_1400869c0(undefined1 *param_1,undefined8 *param_2)

{
  DWORD DVar1;
  int iVar2;
  size_t sVar3;
  longlong lVar4;
  undefined1 *puVar5;
  uint *puVar6;
  undefined1 auStackY_7d8 [32];
  int local_790;
  HKEY local_788 [2];
  wchar_t local_778;
  undefined1 local_776 [1022];
  HDEVINFO local_378;
  HKEY local_370;
  char local_368 [40];
  DWORD local_340;
  DWORD local_33c;
  LSTATUS local_338;
  char local_328 [256];
  int local_228;
  _SP_DEVINFO_DATA local_220;
  BOOL local_200;
  GUID local_1f8;
  DWORD local_1e8;
  DWORD local_1e4 [3];
  PBYTE local_1d8;
  PBYTE local_1d0;
  wchar_t local_1c8 [200];
  uint local_38 [4];
  ulonglong local_28;
  
  local_28 = DAT_140103b40 ^ (ulonglong)auStackY_7d8;
  local_790 = 0;
  puVar5 = local_776;
  for (lVar4 = 0x3fe; lVar4 != 0; lVar4 = lVar4 + -1) {
    *puVar5 = 0;
    puVar5 = puVar5 + 1;
  }
  local_370 = (HKEY)0x0;
  local_778 = L'\0';
  local_788[0] = (HKEY)0x0;
  puVar6 = local_38;
  for (lVar4 = 0x10; lVar4 != 0; lVar4 = lVar4 + -1) {
    *(undefined1 *)puVar6 = *param_1;
    param_1 = param_1 + 1;
    puVar6 = (uint *)((longlong)puVar6 + 1);
  }
  FUN_140085020(local_38,local_368);
  sprintf(local_328,"%s\\%s",PTR_s_SYSTEM_CurrentControlSet_Control_1401036d8,local_368);
  local_338 = RegOpenKeyExA((HKEY)0xffffffff80000002,local_328,0,0x20019,local_788);
  if ((local_338 == 0) && (local_788[0] != (HKEY)0x0)) {
    local_338 = RegOpenKeyExA(local_788[0],"Connection",0,0x20019,&local_370);
    if ((local_338 == 0) && (local_370 != (HKEY)0x0)) {
      local_340 = 0x400;
      local_338 = RegQueryValueExW(local_370,L"PnPInstanceID",(LPDWORD)0x0,&local_33c,
                                   (LPBYTE)&local_778,&local_340);
      if ((local_338 != 0) || (local_33c != 1)) {
        _snprintf(&DAT_140106f10,0x100,"Host interface network is not found in registry (%s) [3]",
                  local_328);
        local_790 = 1;
      }
    }
    else {
      _snprintf(&DAT_140106f10,0x100,"Host interface network is not found in registry (%s) [2]",
                local_328);
      local_790 = 1;
    }
  }
  else {
    _snprintf(&DAT_140106f10,0x100,"Host interface network is not found in registry (%s) [1]",
              local_328);
    local_790 = 1;
  }
  if (local_370 != (HKEY)0x0) {
    RegCloseKey(local_370);
  }
  if (local_788[0] != (HKEY)0x0) {
    RegCloseKey(local_788[0]);
  }
  if (local_790 == 0) {
    local_378 = (HDEVINFO)0xffffffffffffffff;
    local_1e4[1] = 0;
    local_1e8 = 0;
    local_228 = 0;
    local_1e4[0] = 0;
    local_220.cbSize = 0x20;
    memcpy(&local_1f8,&DAT_1400e82d0,0x10);
    local_378 = SetupDiGetClassDevsA(&local_1f8,(PCSTR)0x0,(HWND)0x0,2);
    if (local_378 == (HDEVINFO)0xffffffffffffffff) {
      DVar1 = GetLastError();
      _snprintf(&DAT_140106f10,0x100,"SetupDiGetClassDevs failed (0x%08X)",(ulonglong)DVar1);
      local_790 = 1;
    }
    else {
LAB_140086d01:
      while (local_200 = SetupDiEnumDeviceInfo(local_378,local_1e8,&local_220), local_200 != 0) {
        local_200 = SetupDiGetDeviceRegistryPropertyA
                              (local_378,&local_220,1,(PDWORD)0x0,(PBYTE)0x0,0,local_1e4);
        if (local_200 == 0) {
          DVar1 = GetLastError();
          if (DVar1 == 0x7a) {
            local_1d8 = malloc((ulonglong)local_1e4[0]);
            local_200 = SetupDiGetDeviceRegistryPropertyA
                                  (local_378,&local_220,1,(PDWORD)0x0,local_1d8,local_1e4[0],
                                   (PDWORD)0x0);
            if (local_200 == 0) {
              free(local_1d8);
              local_1d8 = (PBYTE)0x0;
              local_1e8 = local_1e8 + 1;
            }
            else {
              local_1d0 = local_1d8;
              while( true ) {
                if (((local_1d0 == (PBYTE)0x0) || (*local_1d0 == '\0')) ||
                   (local_1d8 + local_1e4[0] <= local_1d0)) goto LAB_140086f6f;
                iVar2 = _stricmp("lmtap",(char *)local_1d0);
                if (((iVar2 == 0) || (iVar2 = _stricmp("vboxtap",(char *)local_1d0), iVar2 == 0)) &&
                   ((iVar2 = CM_Get_Device_IDW(local_220.DevInst,local_1c8,200), iVar2 == 0 &&
                    (iVar2 = wcscmp(local_1c8,&local_778), iVar2 == 0)))) break;
                sVar3 = strlen((char *)local_1d0);
                local_1d0 = local_1d0 + sVar3 + 1;
              }
              local_228 = 1;
LAB_140086f6f:
              if (local_1d8 != (PBYTE)0x0) {
                free(local_1d8);
                local_1d8 = (PBYTE)0x0;
              }
              if (local_228 != 0) goto LAB_140086fb5;
              local_1e8 = local_1e8 + 1;
            }
          }
          else {
            local_1e8 = local_1e8 + 1;
          }
        }
        else {
          local_1e8 = local_1e8 + 1;
        }
      }
      DVar1 = GetLastError();
      if (DVar1 != 0x103) {
        local_1e8 = local_1e8 + 1;
        goto LAB_140086d01;
      }
LAB_140086fb5:
      if (local_228 == 0) {
        DVar1 = GetLastError();
        _snprintf(&DAT_140106f10,0x100,"LinkManager Adapter driver not found (0x%08X)",
                  (ulonglong)DVar1);
        local_790 = 1;
      }
      else {
        local_200 = SetupDiSetSelectedDevice(local_378,&local_220);
        if (local_200 == 0) {
          DVar1 = GetLastError();
          _snprintf(&DAT_140106f10,0x100,"SetupDiSetSelectedDevice failed (0x%08X)",(ulonglong)DVar1
                   );
          local_790 = 1;
        }
        else {
          local_200 = SetupDiCallClassInstaller(5,local_378,&local_220);
          if (local_200 == 0) {
            DVar1 = GetLastError();
            _snprintf(&DAT_140106f10,0x100,"SetupDiCallClassInstaller (DIF_REMOVE) failed (0x%08X)",
                      (ulonglong)DVar1);
            local_790 = 1;
          }
        }
      }
    }
    if (local_378 != (HDEVINFO)0xffffffffffffffff) {
      SetupDiDestroyDeviceInfoList(local_378);
    }
  }
  if ((local_790 != 0) && (param_2 != (undefined8 *)0x0)) {
    *param_2 = &DAT_140106f10;
  }
  return local_790;
}
```

## lmtap.sys — 0x14000a360

[038-tools-call.json](rea/038-tools-call.json) · `ev_9cfb91e9b07bbaf1d997d4c3906f154f41de91a55a6d4dcabd622b751877c4da`

```c
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */

undefined4 FUN_14000a360(void)

{
  code *pcVar1;
  byte bVar2;
  undefined8 uVar3;
  undefined1 *puVar4;
  undefined1 auStack_78 [8];
  undefined1 auStack_70 [24];
  undefined4 local_58;
  undefined8 local_48;
  uint local_40;
  undefined4 local_20;
  undefined4 local_18;
  
  puVar4 = auStack_78;
  local_58 = 0;
  local_48 = 0;
  bVar2 = FUN_140001840();
  if (bVar2 < 2) {
    local_40 = 0;
  }
  else {
    local_40 = 1;
  }
  local_40 = (uint)(bVar2 >= 2);
  if (local_40 == 0) {
    local_20 = 1;
  }
  else {
    pcVar1 = (code *)swi(0x2c);
    (*pcVar1)();
    puVar4 = auStack_70;
    local_18 = 0;
  }
  *(undefined8 *)(puVar4 + -8) = 0x14000a3c6;
  uVar3 = FUN_140002e00(*(longlong *)(puVar4 + 0x88));
  *(undefined8 *)(puVar4 + 0x50) = uVar3;
  *(undefined8 *)(puVar4 + 0x30) =
       *(undefined8 *)(*(longlong *)(*(longlong *)(puVar4 + 0x50) + 0x30) + 0x18);
  if (*(longlong *)(puVar4 + 0x30) == 0) {
    *(undefined4 *)(puVar4 + 0x3c) = 1;
  }
  else {
    *(undefined4 *)(puVar4 + 0x3c) = 0;
  }
  if (*(int *)(puVar4 + 0x3c) == 0) {
    *(undefined4 *)(puVar4 + 0x5c) = 1;
  }
  else {
    *(undefined8 *)(puVar4 + -8) = 0x14000a41b;
    RtlAssert("adapter","C:\\cygwin\\home\\sss\\tap-windows6\\src\\device.c",0x122,0);
    *(undefined4 *)(puVar4 + 0x5c) = 0;
  }
  *(undefined4 *)(puVar4 + 0x48) = *(undefined4 *)(*(longlong *)(puVar4 + 0x50) + 0x10);
  *(undefined4 *)(puVar4 + 0x28) = *(undefined4 *)(*(longlong *)(puVar4 + 0x50) + 8);
  if ((*(int *)(puVar4 + 0x48) == 0) && (*(int *)(puVar4 + 0x28) == 0)) {
    *(undefined4 *)(puVar4 + 0x20) = 0xc000000d;
  }
  else {
    *(undefined4 *)(puVar4 + 0x24) = *(undefined4 *)(*(longlong *)(puVar4 + 0x50) + 0x18);
    if (*(int *)(puVar4 + 0x24) == 0x220004) {
      if (*(uint *)(puVar4 + 0x28) < 6) {
        _DAT_1400084d8 = "C:\\cygwin\\home\\sss\\tap-windows6\\src\\device.c";
        _DAT_1400084d0 = 0x143;
        *(undefined4 *)(puVar4 + 0x20) = 0xc0000023;
        *(undefined4 *)(*(longlong *)(puVar4 + 0x88) + 0x30) = *(undefined4 *)(puVar4 + 0x20);
      }
      else {
        **(undefined4 **)(*(longlong *)(puVar4 + 0x88) + 0x18) =
             *(undefined4 *)(*(longlong *)(puVar4 + 0x30) + 0xee);
        *(undefined2 *)(*(longlong *)(*(longlong *)(puVar4 + 0x88) + 0x18) + 4) =
             *(undefined2 *)(*(longlong *)(puVar4 + 0x30) + 0xf2);
        *(undefined8 *)(*(longlong *)(puVar4 + 0x88) + 0x38) = 6;
      }
    }
    else if (*(int *)(puVar4 + 0x24) == 0x220008) {
      *(undefined4 *)(puVar4 + 0x40) = 0xc;
      if (*(uint *)(puVar4 + 0x28) < *(uint *)(puVar4 + 0x40)) {
        _DAT_1400084d8 = "C:\\cygwin\\home\\sss\\tap-windows6\\src\\device.c";
        _DAT_1400084d0 = 0x15f;
        *(undefined4 *)(puVar4 + 0x20) = 0xc0000023;
        *(undefined4 *)(*(longlong *)(puVar4 + 0x88) + 0x30) = *(undefined4 *)(puVar4 + 0x20);
      }
      else {
        **(undefined4 **)(*(longlong *)(puVar4 + 0x88) + 0x18) = 9;
        *(undefined4 *)(*(longlong *)(*(longlong *)(puVar4 + 0x88) + 0x18) + 4) = 0x17;
        *(undefined4 *)(*(longlong *)(*(longlong *)(puVar4 + 0x88) + 0x18) + 8) = 0;
        *(ulonglong *)(*(longlong *)(puVar4 + 0x88) + 0x38) = (ulonglong)*(uint *)(puVar4 + 0x40);
      }
    }
    else if (*(int *)(puVar4 + 0x24) == 0x22000c) {
      *(undefined4 *)(puVar4 + 0x44) = 4;
      if (*(uint *)(puVar4 + 0x28) < *(uint *)(puVar4 + 0x44)) {
        _DAT_1400084d8 = "C:\\cygwin\\home\\sss\\tap-windows6\\src\\device.c";
        _DAT_1400084d0 = 0x172;
        *(undefined4 *)(puVar4 + 0x20) = 0xc0000023;
        *(undefined4 *)(*(longlong *)(puVar4 + 0x88) + 0x30) = *(undefined4 *)(puVar4 + 0x20);
      }
      else {
        **(undefined4 **)(*(longlong *)(puVar4 + 0x88) + 0x18) =
             *(undefined4 *)(*(longlong *)(puVar4 + 0x30) + 0xd8);
        *(ulonglong *)(*(longlong *)(puVar4 + 0x88) + 0x38) = (ulonglong)*(uint *)(puVar4 + 0x44);
      }
    }
    else if (*(int *)(puVar4 + 0x24) == 0x220018) {
      if (*(uint *)(puVar4 + 0x48) < 4) {
        _DAT_1400084d8 = "C:\\cygwin\\home\\sss\\tap-windows6\\src\\device.c";
        _DAT_1400084d0 = 0x194;
        *(undefined4 *)(puVar4 + 0x20) = 0xc000000d;
        *(undefined4 *)(*(longlong *)(puVar4 + 0x88) + 0x30) = *(undefined4 *)(puVar4 + 0x20);
      }
      else {
        *(undefined4 *)(puVar4 + 0x60) = **(undefined4 **)(*(longlong *)(puVar4 + 0x88) + 0x18);
        if (*(int *)(puVar4 + 0x60) == 0) {
          *(undefined4 *)(puVar4 + 0x4c) = 2;
        }
        else {
          *(undefined4 *)(puVar4 + 0x4c) = 1;
        }
        *(undefined8 *)(puVar4 + -8) = 0x14000a69e;
        FUN_140003080(*(longlong *)(puVar4 + 0x30),*(int *)(puVar4 + 0x4c));
        *(undefined8 *)(*(longlong *)(puVar4 + 0x88) + 0x38) = 1;
      }
    }
    else {
      *(undefined4 *)(puVar4 + 0x20) = 0xc0000010;
    }
  }
  *(undefined4 *)(*(longlong *)(puVar4 + 0x88) + 0x30) = *(undefined4 *)(puVar4 + 0x20);
  *(undefined8 *)(puVar4 + -8) = 0x14000a708;
  IofCompleteRequest(*(undefined8 *)(puVar4 + 0x88),0);
  return *(undefined4 *)(puVar4 + 0x20);
}
```


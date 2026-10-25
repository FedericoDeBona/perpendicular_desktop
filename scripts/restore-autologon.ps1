# Restores the appliance account's automatic logon without changing its password.
# Run elevated, then enter the EXISTING password at the protected prompt.
# No password parameter, command-line credential, transcript or plaintext registry value.
#Requires -RunAsAdministrator
param([string]$Account = $env:USERNAME)
$ErrorActionPreference = 'Stop'
if ($Account -ne $env:USERNAME) { throw 'Run as the Windows account whose automatic logon is being restored.' }
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
public static class PerpendicularLogonSecret {
    [StructLayout(LayoutKind.Sequential)] struct UnicodeString {
        public ushort Length, MaximumLength; public IntPtr Buffer;
    }
    [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes {
        public uint Length; public IntPtr RootDirectory, ObjectName;
        public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService;
    }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref ObjectAttributes attributes, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr handle, ref UnicodeString key, ref UnicodeString value);
    [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool LogonUser(string user, string domain, IntPtr password, uint type, uint provider, out IntPtr token);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static void Check(uint status) { if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status)); }
    public static void Store(string account, string domain, SecureString password) {
        IntPtr secret=IntPtr.Zero, keyBuffer=IntPtr.Zero, policy=IntPtr.Zero, token=IntPtr.Zero;
        try {
            secret=Marshal.SecureStringToGlobalAllocUnicode(password);
            if (!LogonUser(account, domain, secret, 2, 0, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Existing account password was not accepted; automatic logon was not changed.");
            var attributes=new ObjectAttributes {Length=(uint)Marshal.SizeOf(typeof(ObjectAttributes))};
            Check(LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x20, out policy)); // POLICY_CREATE_SECRET
            const string name="DefaultPassword";
            keyBuffer=Marshal.StringToHGlobalUni(name);
            var key=new UnicodeString {Length=(ushort)(name.Length*2),MaximumLength=(ushort)((name.Length+1)*2),Buffer=keyBuffer};
            var value=new UnicodeString {Length=checked((ushort)(password.Length*2)),MaximumLength=checked((ushort)((password.Length+1)*2)),Buffer=secret};
            Check(LsaStorePrivateData(policy, ref key, ref value));
        } finally {
            if (token!=IntPtr.Zero) CloseHandle(token);
            if (policy!=IntPtr.Zero) LsaClose(policy);
            if (keyBuffer!=IntPtr.Zero) Marshal.FreeHGlobal(keyBuffer);
            if (secret!=IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(secret);
        }
    }
}
'@
$password = Read-Host 'Existing Windows password (it will not be displayed)' -AsSecureString
try { [PerpendicularLogonSecret]::Store($Account, $env:COMPUTERNAME, $password) }
finally { if ($password) { $password.Dispose() }; $password=$null }
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
New-ItemProperty $key DefaultUserName -Value $Account -PropertyType String -Force | Out-Null
New-ItemProperty $key DefaultDomainName -Value $env:COMPUTERNAME -PropertyType String -Force | Out-Null
Remove-ItemProperty $key DefaultPassword -ErrorAction SilentlyContinue
Remove-ItemProperty $key AutoLogonCount -ErrorAction SilentlyContinue
New-ItemProperty $key AutoAdminLogon -Value '1' -PropertyType String -Force | Out-Null
$result = [pscustomobject]@{
    AutomaticLogon=$true; LimitedLogons=$false; CredentialStorage='LSA'; Account=$Account
    SecureBoot=(Confirm-SecureBootUEFI); CompletedUtc=[DateTime]::UtcNow.ToString('o')
}
$receipt=Join-Path $env:LOCALAPPDATA 'Perpendicular-autologon-result.json'
$result | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8
$result | Format-List
Write-Host 'Automatic logon restored. The account password and boot protections were not changed.'

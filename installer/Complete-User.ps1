$ErrorActionPreference='Stop'
$root=Join-Path $env:ProgramData 'Perpendicular\Setup'
Start-Transcript (Join-Path $root 'user-install.log') -Append|Out-Null
try {
    if([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem){throw 'Interactive user required'}
    if(!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Setup requires the elevated first-logon context'}
    $accelerated=@(Get-PnpDevice -PresentOnly -Class Display|Where-Object InstanceId -like 'PCI\VEN_1AF4&DEV_1050*')
    if(!$accelerated.Count) {
        # Windows Setup uses the packaged RAMFB recovery path. Install the
        # bridge, then let the host switch to the already staged 3D device offline.
        & (Join-Path $root 'Guest\perpendicular-guest.exe') install (Join-Path $root 'Guest\connection.json')
        if($LASTEXITCODE-ne0){throw 'Initial bridge installation failed'}
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Complete-User.ps1')+'"')
        $principal=New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
        $trigger=New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
        Register-ScheduledTask -TaskName 'PerpendicularFirstRunComplete' -Action $action -Trigger $trigger -Principal $principal -Force|Out-Null
        @{phase='base-installed';time=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $root 'status.json') -Encoding UTF8
        return
    }
    $glState=Join-Path $env:ProgramData 'Perpendicular\Graphics\OpenGL\install-state.json'
    if(!(Test-Path $glState)) {
        $checks=Join-Path $env:ProgramFiles 'Perpendicular OpenGL Check'
        New-Item -ItemType Directory -Force $checks|Out-Null
        $probe=Join-Path $checks 'OpenGLCheck.exe'
        Copy-Item (Join-Path $root 'Probes\arm64\OpenGLCheck.exe') $probe -Force
        $machine=[Guid](Get-CimInstance Win32_ComputerSystemProduct).UUID
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Guest\OpenGL\install.ps1') -ExpectedMachineID $machine -ApplicationExecutable $probe
        if($LASTEXITCODE-ne0){throw 'OpenGL setup failed'}
    }
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Guest\install.ps1')
    if($LASTEXITCODE-ne0){throw 'Perpendicular components setup failed'}
    $secret=Get-Content (Join-Path $root 'secrets.json') -Raw|ConvertFrom-Json
    # Keep appliance autologon in LSA, never in a persistent plaintext Winlogon value.
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class InstallerLogon {
 [StructLayout(LayoutKind.Sequential)]struct U{public ushort L,M;public IntPtr B;}
 [StructLayout(LayoutKind.Sequential)]struct A{public uint L;public IntPtr R,N;public uint F;public IntPtr D,Q;}
 [DllImport("advapi32.dll")]static extern uint LsaOpenPolicy(IntPtr s,ref A a,uint x,out IntPtr h);
 [DllImport("advapi32.dll")]static extern uint LsaStorePrivateData(IntPtr h,ref U k,ref U v);
 [DllImport("advapi32.dll")]static extern uint LsaClose(IntPtr h);
 public static void Store(string value){IntPtr h=IntPtr.Zero,k=IntPtr.Zero,v=IntPtr.Zero;try{var a=new A{L=(uint)Marshal.SizeOf(typeof(A))};if(LsaOpenPolicy(IntPtr.Zero,ref a,0x20,out h)!=0)throw new Exception("LSA policy");k=Marshal.StringToHGlobalUni("DefaultPassword");v=Marshal.StringToHGlobalUni(value);var key=new U{L=30,M=32,B=k};var data=new U{L=(ushort)(value.Length*2),M=(ushort)((value.Length+1)*2),B=v};if(LsaStorePrivateData(h,ref key,ref data)!=0)throw new Exception("LSA secret");}finally{if(h!=IntPtr.Zero)LsaClose(h);if(k!=IntPtr.Zero)Marshal.FreeHGlobal(k);if(v!=IntPtr.Zero)Marshal.ZeroFreeGlobalAllocUnicode(v);}}
}
'@
    [InstallerLogon]::Store($secret.password)
    $key='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    New-ItemProperty $key DefaultUserName -Value 'Perpendicular' -PropertyType String -Force|Out-Null
    New-ItemProperty $key DefaultDomainName -Value $env:COMPUTERNAME -PropertyType String -Force|Out-Null
    New-ItemProperty $key AutoAdminLogon -Value '1' -PropertyType String -Force|Out-Null
    Remove-ItemProperty $key DefaultPassword,AutoLogonCount -ErrorAction SilentlyContinue
    $user=[ADSI]("WinNT://"+$env:COMPUTERNAME+'/Perpendicular,user');$user.UserFlags=[int]$user.UserFlags.Value-bor0x10000;$user.SetInfo()
    Remove-Item (Join-Path $root 'secrets.json') -Force
    foreach($file in @('C:\Windows\Panther\unattend.xml','C:\Windows\Panther\Unattend\unattend.xml','C:\Windows\System32\Sysprep\unattend.xml')){if(Test-Path $file){Remove-Item $file -Force}}
    Unregister-ScheduledTask -TaskName 'PerpendicularFirstRunComplete' -Confirm:$false -ErrorAction SilentlyContinue
    @{phase='installed';time=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $root 'status.json') -Encoding UTF8
} catch {
    @{phase='failed';message=$_.ToString()}|ConvertTo-Json|Set-Content (Join-Path $root 'status.json') -Encoding UTF8
    throw
} finally {Stop-Transcript|Out-Null}

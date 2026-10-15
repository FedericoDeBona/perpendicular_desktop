#Requires -Version 5.1
# Physical-pixel mode selection only. No registry writes or Windows DPI changes.
$script:DisplayLastAttemptTick = $null

function Initialize-AgentDisplayNative {
    if ($null -ne ('Perpendicular.Guest.DisplayNative' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace Perpendicular.Guest {
    public sealed class DisplayMode {
        public int Width;
        public int Height;
        public uint? Dpi;
        public string DeviceName;
        public string Adapter;
    }
    public sealed class DisplaySnapshot {
        public DisplayMode Current;
        public List<DisplayMode> Modes = new List<DisplayMode>();
        public bool CanResize;
        public string Reason;
    }
    public sealed class DisplayChange {
        public bool Applied;
        public bool Changed;
        public string Code;
        public string Reason;
        public DisplayMode Actual;
    }
    public static class DisplayNative {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct Device {
            public uint Size;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Id;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Key;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DevMode {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            public ushort SpecVersion, DriverVersion, Size, DriverExtra;
            public uint Fields;
            public int PositionX, PositionY;
            public uint Orientation, FixedOutput;
            public short Color, Duplex, YResolution, TTOption, Collate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FormName;
            public ushort LogPixels;
            public uint BitsPerPel, Width, Height, Flags, Frequency;
            public uint ICMMethod, ICMIntent, MediaType, DitherType, Reserved1, Reserved2, PanningWidth, PanningHeight;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumDisplayDevicesW(string name, uint index, ref Device device, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumDisplaySettingsExW(string name, uint index, ref DevMode mode, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int ChangeDisplaySettingsExW(string name, ref DevMode mode, IntPtr window, uint flags, IntPtr parameters);
        [DllImport("shcore.dll", ExactSpelling = true)]
        private static extern int GetProcessDpiAwareness(IntPtr process, out int awareness);
        [DllImport("user32.dll", ExactSpelling = true)]
        private static extern uint GetDpiForSystem();

        public static int[] StructureSizes() { return new int[] { Marshal.SizeOf(typeof(DevMode)), Marshal.SizeOf(typeof(Device)) }; }
        public static bool Allowed(int width, int height) {
            return width >= 640 && width <= 3840 && height >= 480 && height <= 2160 && (long)width * height <= 8294400;
        }
        private static DevMode EmptyMode() {
            DevMode mode = new DevMode(); mode.Size = (ushort)Marshal.SizeOf(typeof(DevMode)); return mode;
        }
        private static uint? SystemDpi() {
            // An unaware process receives virtualized 96 DPI. Return unknown
            // rather than label that value as the Windows scaling setting.
            try {
                int awareness;
                if (GetProcessDpiAwareness(IntPtr.Zero, out awareness) != 0 || awareness == 0) return null;
                uint dpi = GetDpiForSystem();
                return dpi >= 48 && dpi <= 768 ? (uint?)dpi : null;
            } catch (EntryPointNotFoundException) { return null; }
              catch (DllNotFoundException) { return null; }
        }
        private static DisplayMode Describe(DevMode mode, Device device) {
            return new DisplayMode { Width = (int)mode.Width, Height = (int)mode.Height,
                Dpi = SystemDpi(), DeviceName = device.Name, Adapter = device.Description ?? "" };
        }
        private static bool Primary(out Device device) {
            for (uint index = 0; index < 32; index++) {
                device = new Device(); device.Size = (uint)Marshal.SizeOf(typeof(Device));
                if (!EnumDisplayDevicesW(null, index, ref device, 0)) break;
                if ((device.Flags & 5) == 5 && (device.Flags & 8) == 0 && !String.IsNullOrEmpty(device.Name)) return true;
            }
            device = new Device(); return false;
        }
        private static bool Current(Device device, out DevMode mode) {
            mode = EmptyMode();
            return EnumDisplaySettingsExW(device.Name, 0xffffffff, ref mode, 0)
                && mode.Width > 0 && mode.Width <= 16384 && mode.Height > 0 && mode.Height <= 16384;
        }
        private static void RefreshActual(DisplayChange change, Device device) {
            DevMode mode; change.Actual = Current(device, out mode) ? Describe(mode, device) : null;
        }
        private static List<DevMode> Modes(Device device, DevMode current, out bool bounded) {
            List<DevMode> modes = new List<DevMode>(); bounded = true;
            for (uint index = 0; index < 1024; index++) {
                DevMode mode = EmptyMode();
                // No EDS_RAWMODE or unsafe display modes. Keep the actual
                // enumerated DEVMODE, including refresh/orientation fields.
                if (!EnumDisplaySettingsExW(device.Name, index, ref mode, 0)) return modes;
                if (index == 1023) { bounded = false; return modes; }
                if (!Allowed((int)mode.Width, (int)mode.Height) || mode.BitsPerPel != 32
                    || mode.Size != Marshal.SizeOf(typeof(DevMode)) || mode.DriverExtra != 0
                    || (mode.Fields & 0x180000) != 0x180000 || (mode.Flags & 2) != 0
                    || mode.Orientation != current.Orientation) continue;
                int found = modes.FindIndex(delegate(DevMode m) { return m.Width == mode.Width && m.Height == mode.Height; });
                if (found < 0) modes.Add(mode);
                else if (Math.Abs((long)mode.Frequency - current.Frequency) < Math.Abs((long)modes[found].Frequency - current.Frequency)) modes[found] = mode;
                if (modes.Count > 128) { bounded = false; return modes; }
            }
            bounded = false; return modes;
        }
        public static DisplaySnapshot Query() {
            DisplaySnapshot snapshot = new DisplaySnapshot(); Device device; DevMode current;
            if (!Primary(out device) || !Current(device, out current)) {
                snapshot.Reason = "The primary Windows display mode is unavailable."; return snapshot;
            }
            snapshot.Current = Describe(current, device); bool bounded;
            List<DevMode> modes = Modes(device, current, out bounded);
            if (!bounded) { snapshot.Reason = "The driver exceeded the bounded mode enumeration limit."; return snapshot; }
            foreach (DevMode mode in modes) {
                snapshot.Modes.Add(new DisplayMode { Width = (int)mode.Width, Height = (int)mode.Height });
                if (mode.Width != current.Width || mode.Height != current.Height) snapshot.CanResize = true;
            }
            if (!snapshot.CanResize) snapshot.Reason = "The current display driver exposes no alternative safe mode; a fixed RAM framebuffer cannot be resized.";
            return snapshot;
        }
        public static DisplayChange Resize(int width, int height) {
            if (!Allowed(width, height)) throw new ArgumentOutOfRangeException("width", "Physical pixel bounds exceeded.");
            Device device; DevMode before;
            DisplayChange change = new DisplayChange { Code = "display_unavailable", Reason = "The current Windows display mode is unavailable." };
            if (!Primary(out device) || !Current(device, out before)) return change;
            change.Actual = Describe(before, device);
            if (before.Width == width && before.Height == height) { change.Applied = true; change.Code = "already_current"; change.Reason = null; return change; }
            bool bounded; List<DevMode> modes = Modes(device, before, out bounded);
            int found = modes.FindIndex(delegate(DevMode m) { return m.Width == width && m.Height == height; });
            if (!bounded || found < 0) { change.Code = "display_mode_unsupported"; change.Reason = "The display driver does not expose the requested safe mode."; return change; }
            DevMode selected = modes[found];
            // Enumerated settings may include position or other fields. This
            // operation never repositions or changes the primary display.
            selected.Fields &= 0x007c0000;
            int test = ChangeDisplaySettingsExW(device.Name, ref selected, IntPtr.Zero, 2, IntPtr.Zero);
            if (test != 0) { RefreshActual(change, device); change.Code = "display_test_failed"; change.Reason = "Windows rejected the mode test (code " + test + ")."; return change; }
            // Flags 0 changes only the active mode. Never UPDATEREGISTRY,
            // SET_PRIMARY, GLOBAL, unsafe flags, adapter names or custom modes.
            int applied = ChangeDisplaySettingsExW(device.Name, ref selected, IntPtr.Zero, 0, IntPtr.Zero);
            if (applied != 0) { RefreshActual(change, device); change.Code = "display_change_failed"; change.Reason = "Windows rejected the dynamic mode change (code " + applied + ")."; return change; }
            DevMode actual;
            change.Actual = null;
            for (int attempt = 0; attempt < 13; attempt++) {
                if (Current(device, out actual)) {
                    change.Actual = Describe(actual, device);
                    if (actual.Width == width && actual.Height == height) {
                        change.Applied = true; change.Changed = true; change.Code = "resized"; change.Reason = null; return change;
                    }
                }
                if (attempt < 12) Thread.Sleep(50);
            }
            change.Code = "display_not_applied"; change.Reason = "Windows did not report the requested actual resolution after the mode change."; return change;
        }
    }
}
'@
}

function ConvertTo-AgentDisplayCurrent {
    param($Mode)
    if ($null -eq $Mode) { return $null }
    return @{ width = $Mode.Width; height = $Mode.Height; dpi = $Mode.Dpi
        device_name = $Mode.DeviceName; adapter = $Mode.Adapter }
}

function Get-AgentDisplayNativeStatus {
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        return @{ can_resize = $false; reason = 'Windows display APIs are unavailable on this platform.'; current = $null; modes = @(); dpi_change_supported = $false }
    }
    Initialize-AgentDisplayNative
    $snapshot = [Perpendicular.Guest.DisplayNative]::Query()
    return @{ can_resize = $snapshot.CanResize; reason = $snapshot.Reason
        current = (ConvertTo-AgentDisplayCurrent $snapshot.Current)
        modes = @($snapshot.Modes | ForEach-Object { @{ width = $_.Width; height = $_.Height } })
        dpi_change_supported = $false }
}

function Get-AgentDisplayStatus {
    try { return Get-AgentDisplayNativeStatus }
    catch { return @{ can_resize = $false; reason = 'Windows display mode enumeration failed.'; current = $null; modes = @(); dpi_change_supported = $false } }
}

function Get-AgentDisplayTick {
    return [long][Math]::Floor([Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency)
}

function Invoke-AgentDisplayNativeResize {
    param([int]$Width, [int]$Height)
    Initialize-AgentDisplayNative
    $result = [Perpendicular.Guest.DisplayNative]::Resize($Width, $Height)
    return @{ applied = $result.Applied; changed = $result.Changed; code = $result.Code
        reason = $result.Reason; actual = (ConvertTo-AgentDisplayCurrent $result.Actual) }
}

function Set-AgentDisplay {
    param($Width, $Height, $HostDpi)
    foreach ($value in @($Width, $Height, $HostDpi)) {
        if ($value -isnot [int] -and $value -isnot [long]) {
            throw (New-AgentError 'invalid_display_request' 'Display dimensions and host_dpi must be JSON integers.')
        }
    }
    if ($Width -lt 640 -or $Width -gt 3840 -or $Height -lt 480 -or $Height -gt 2160 -or
        ([long]$Width * [long]$Height) -gt 8294400 -or $HostDpi -lt 96 -or $HostDpi -gt 288) {
        throw (New-AgentError 'invalid_display_request' 'Display request exceeds the physical-pixel or host-DPI limits.')
    }
    $status = Get-AgentDisplayStatus
    $result = @{ applied = $false; changed = $false; code = 'display_mode_unsupported'; reason = $status.reason
        requested = @{ width = $Width; height = $Height; host_dpi = $HostDpi }
        actual = $status.current; dpi_changed = $false; retry_after_ms = 0 }
    if ($null -ne $status.current -and $status.current.width -eq $Width -and $status.current.height -eq $Height) {
        $result.applied = $true; $result.code = 'already_current'; $result.reason = $null; return $result
    }
    if (-not $status.can_resize) { return $result }
    $matching = @($status.modes | Where-Object { $_.width -eq $Width -and $_.height -eq $Height })
    if ($matching.Count -eq 0) { $result.reason = 'The requested resolution is not a safe mode exposed by the current display driver.'; return $result }
    $now = Get-AgentDisplayTick
    if ($null -ne $script:DisplayLastAttemptTick -and ($now - $script:DisplayLastAttemptTick) -lt 750) {
        $result.code = 'display_resize_throttled'; $result.reason = 'Wait for the previous display change before another resize.'
        $result.retry_after_ms = [int][Math]::Min(750, [Math]::Max(1, 750 - ($now - $script:DisplayLastAttemptTick)))
        return $result
    }
    $script:DisplayLastAttemptTick = $now
    try {
        $native = Invoke-AgentDisplayNativeResize ([int]$Width) ([int]$Height)
        foreach ($key in @('applied', 'changed', 'code', 'reason', 'actual')) { $result[$key] = $native[$key] }
        if ($result.applied -and ($null -eq $result.actual -or $result.actual.width -ne $Width -or $result.actual.height -ne $Height)) {
            $result.applied = $false; $result.changed = $false; $result.code = 'display_not_applied'
            $result.reason = 'Windows did not report the requested actual resolution.'
        }
        return $result
    } catch {
        $result.code = 'display_change_failed'; $result.reason = 'Windows display mode change failed.'
        $result.actual = (Get-AgentDisplayStatus).current
        return $result
    }
}

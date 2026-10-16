// SPDX-License-Identifier: MIT
// Independent diagnostic. C# 5 syntax for Windows PowerShell 5.1 Add-Type.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Perpendicular3D
{
    public sealed class UmdModuleReport
    {
        public string path;
        public string sha256;
        public long? disk_file_bytes;
        public string hash_status = "unknown";
        public string hash_error;
    }

    public sealed class ProbeReport
    {
        public int protocol = 1;
        public string mode;
        public bool success;
        public string error_stage;
        public string error_message;
        public string error_hresult;
        public string os_version = Environment.OSVersion.VersionString;
        public int process_id = Process.GetCurrentProcess().Id;
        public int session_id = Process.GetCurrentProcess().SessionId;
        public string process_machine;
        public string native_machine;
        public bool native_arm64;
        public string requested_driver = "D3D_DRIVER_TYPE_HARDWARE";
        public bool software_fallback = false;
        public string[] requested_feature_levels = { "11_1", "11_0", "10_1", "10_0" };
        public bool device_creation_succeeded;
        public string device_creation_hresult;
        public string feature_level;
        public string adapter_description;
        public string vendor_id;
        public string device_id;
        public string subsystem_id;
        public string revision;
        public string adapter_luid;
        public uint adapter_flags;
        public bool dxgi_software_flag;
        public bool software_adapter;
        public string expected_adapter = "PCI vendor 0x1AF4, device 0x1050 (VirtIO GPU)";
        public bool expected_adapter_verified;
        public bool hardware_adapter_verified;
        public bool host_acceleration_verified = false;
        public string system_d3d11_path;
        public string umd_inventory_status = "not_attempted";
        public string umd_inventory_error;
        public UmdModuleReport[] umd_modules = new UmdModuleReport[0];
        public bool scene_attempted;
        public bool scene_completed;
        public bool exclusive_requested;
        public bool exclusive_observed;
        public bool exclusive_end_observed;
        public string fullscreen_restore_hresult;
        public int width = 800;
        public int height = 600;
        public int buffer_count = 2;
        public string format = "B8G8R8A8_UNORM";
        public string swap_effect = "FLIP_DISCARD";
        public int requested_frames;
        public int requested_seconds;
        public int present_attempts;
        public int present_s_ok;
        public int present_occluded;
        public string last_present_hresult;
        public string device_removed_hresult;
        public long scene_elapsed_ms;
        public bool user_closed;
        public string evidence_scope = "Device creation and Present return values are separate from observed console pixels, host acceleration and performance.";
    }

    public static class Probe
    {
        // check-abi.py verifies these slots against the existing pinned WIDL headers.
        internal const int QueryInterfaceSlot = 0;
        internal const int ReleaseSlot = 2;
        internal const int GetParentSlot = 6; // IDXGIObject
        internal const int GetAdapterSlot = 7; // IDXGIDevice
        internal const int GetDesc1Slot = 10; // IDXGIAdapter1
        internal const int MakeWindowAssociationSlot = 8; // IDXGIFactory2
        internal const int CreateSwapChainForHwndSlot = 15; // IDXGIFactory2
        internal const int CreateRenderTargetViewSlot = 9; // ID3D11Device
        internal const int GetDeviceRemovedReasonSlot = 39; // ID3D11Device
        internal const int PresentSlot = 8; // IDXGISwapChain1
        internal const int GetBufferSlot = 9; // IDXGISwapChain1
        internal const int SetFullscreenStateSlot = 10; // IDXGISwapChain1
        internal const int GetFullscreenStateSlot = 11; // IDXGISwapChain1
        internal const int ResizeBuffersSlot = 13; // IDXGISwapChain1
        internal const int ClearViewSlot = 132; // ID3D11DeviceContext1
        private const uint HardwareDriver = 1;
        private const uint SdkVersion = 7;
        private const uint BgraSupport = 0x20;
        private const uint SoftwareAdapterFlag = 2;
        private const int StatusOccluded = 0x087A0001;
        private const long MaxUmdFileBytes = 8 * 1024 * 1024;
        private static readonly uint[] Levels = { 0xb100, 0xb000, 0xa100, 0xa000 };
        private static readonly Guid DxgiDeviceId = new Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
        private static readonly Guid Adapter1Id = new Guid("29038f61-3839-4626-91fd-086879011a05");
        private static readonly Guid Factory2Id = new Guid("50c83a1c-e072-4c48-87b0-3630fa36a6d0");
        private static readonly Guid Context1Id = new Guid("bb2c6faa-b5fb-4082-8e6b-388b8cfa90e1");
        private static readonly Guid Texture2DId = new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
        private static readonly object RunLock = new object();

        [StructLayout(LayoutKind.Sequential)] internal struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct AdapterDesc1
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
            public uint VendorId, DeviceId, SubSysId, Revision;
            public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
            public Luid AdapterLuid;
            public uint Flags;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct SampleDesc { public uint Count, Quality; }
        [StructLayout(LayoutKind.Sequential)] internal struct SwapDesc1
        {
            public uint Width, Height, Format;
            public int Stereo;
            public SampleDesc Sample;
            public uint Usage, BufferCount, Scaling, SwapEffect, AlphaMode, Flags;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct Rect
        {
            public int Left, Top, Right, Bottom;
            public Rect(int l, int t, int r, int b) { Left = l; Top = t; Right = r; Bottom = b; }
        }

        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int Query(IntPtr self, ref Guid id, out IntPtr result);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate uint ReleaseNative(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetAdapterNative(IntPtr self, out IntPtr adapter);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetDescNative(IntPtr self, out AdapterDesc1 desc);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int AssociateNative(IntPtr self, IntPtr hwnd, uint flags);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int CreateSwapNative(IntPtr self, IntPtr device, IntPtr hwnd, ref SwapDesc1 desc, IntPtr fullscreen, IntPtr output, out IntPtr swap);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetBufferNative(IntPtr self, uint index, ref Guid id, out IntPtr buffer);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int CreateRtvNative(IntPtr self, IntPtr resource, IntPtr desc, out IntPtr view);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int FullscreenNative(IntPtr self, int enabled, IntPtr output);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int FullscreenQueryNative(IntPtr self, out int enabled, out IntPtr output);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int ResizeBuffersNative(IntPtr self, uint count, uint width, uint height, uint format, uint flags);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int PresentNative(IntPtr self, uint interval, uint flags);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int RemovedNative(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate void ClearViewNative(IntPtr self, IntPtr view, [In, MarshalAs(UnmanagedType.LPArray, SizeConst = 4)] float[] color, ref Rect rectangle, uint count);

        private static T Method<T>(IntPtr instance, int slot) where T : class
        {
            if (instance == IntPtr.Zero) throw new InvalidOperationException("Null COM instance");
            IntPtr entry = Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), checked(slot * IntPtr.Size));
            if (entry == IntPtr.Zero) throw new InvalidOperationException("Null COM method");
            return (T)(object)Marshal.GetDelegateForFunctionPointer(entry, typeof(T));
        }
        private static string Hex(int value) { return "0x" + unchecked((uint)value).ToString("X8"); }
        private sealed class ProbeFailure : Exception
        {
            public readonly string Stage;
            public readonly int? Result;
            public ProbeFailure(string stage, string message, int? result) : base(message) { Stage = stage; Result = result; }
        }
        private static void Check(int result, string stage)
        {
            if (result < 0) throw new ProbeFailure(stage, stage + " returned " + Hex(result), result);
        }
        private static void Release(ref IntPtr value)
        {
            IntPtr owned = value; value = IntPtr.Zero;
            if (owned != IntPtr.Zero) Method<ReleaseNative>(owned, ReleaseSlot)(owned);
        }
        private static IntPtr Interface(IntPtr value, Guid id, string stage)
        {
            IntPtr result = IntPtr.Zero;
            int hr = Method<Query>(value, QueryInterfaceSlot)(value, ref id, out result);
            if (hr < 0) { Release(ref result); Check(hr, stage); }
            if (result == IntPtr.Zero) throw new ProbeFailure(stage, "Successful query returned a null pointer", null);
            return result;
        }
        private static string FeatureLevel(uint level)
        {
            return ((level >> 12) & 15).ToString() + "_" + ((level >> 8) & 15).ToString();
        }
        private static string NormalizeMode(string mode)
        {
            if (String.Equals(mode, "Device", StringComparison.OrdinalIgnoreCase)) return "Device";
            if (String.Equals(mode, "Scene", StringComparison.OrdinalIgnoreCase)) return "Scene";
            throw new ProbeFailure("arguments", "Use Device or Scene (case insensitive).", null);
        }
        private static bool IsNativeArm64(ushort process, ushort native, int pointerBytes) { return process == 0 && native == 0xaa64 && pointerBytes == 8; }
        private static bool IsSoftware(uint flags) { return (flags & SoftwareAdapterFlag) != 0; }
        private static bool IsUmdName(string name)
        {
            return name != null && name.StartsWith("neptune_umd", StringComparison.OrdinalIgnoreCase) && name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase);
        }
        private static string InventoryError(Exception error)
        {
            string text = error.GetType().Name + ": " + error.Message;
            return text.Length <= 512 ? text : text.Substring(0, 512);
        }
        private static UmdModuleReport HashUmdFile(string path, ref long remainingBytes)
        {
            UmdModuleReport result = new UmdModuleReport(); result.path = path;
            try
            {
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
                {
                    long length = stream.Length; result.disk_file_bytes = length;
                    if (length > MaxUmdFileBytes || length > remainingBytes) throw new IOException("UMD file or aggregate hash byte limit exceeded");
                    remainingBytes -= length;
                    using (SHA256 hash = SHA256.Create())
                    {
                        byte[] buffer = new byte[65536]; long unread = length;
                        while (unread > 0)
                        {
                            int count = stream.Read(buffer, 0, (int)Math.Min(unread, buffer.Length));
                            if (count == 0) throw new IOException("UMD file shortened during hashing");
                            hash.TransformBlock(buffer, 0, count, buffer, 0); unread -= count;
                        }
                        if (stream.ReadByte() != -1) throw new IOException("UMD file grew during hashing");
                        hash.TransformFinalBlock(new byte[0], 0, 0);
                        result.sha256 = BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
                        result.hash_status = "available";
                    }
                }
            }
            catch (Exception error) { result.sha256 = null; result.hash_status = "unknown"; result.hash_error = InventoryError(error); }
            return result;
        }
        private static void CaptureUmdModules(ProbeReport report)
        {
            List<UmdModuleReport> found = new List<UmdModuleReport>();
            report.umd_inventory_status = "complete";
            long remainingBytes = 32 * 1024 * 1024;
            try
            {
                using (Process self = Process.GetCurrentProcess())
                {
                    ProcessModuleCollection modules = self.Modules;
                    if (modules.Count > 1024) throw new IOException("Own-process module enumeration limit exceeded");
                    foreach (ProcessModule module in modules)
                    {
                        if (!IsUmdName(module.ModuleName)) continue;
                        if (found.Count == 8) throw new IOException("Matching UMD module count limit exceeded");
                        string path = module.FileName;
                        if (String.IsNullOrEmpty(path) || path.Length > 32768) throw new IOException("UMD module path unavailable or too long");
                        UmdModuleReport item = HashUmdFile(path, ref remainingBytes); found.Add(item);
                        if (item.hash_status != "available") report.umd_inventory_status = "partial";
                    }
                }
            }
            catch (Exception error)
            {
                report.umd_inventory_status = found.Count == 0 ? "unknown" : "partial";
                report.umd_inventory_error = InventoryError(error);
            }
            report.umd_modules = found.ToArray();
        }
        private static void ValidateAdapter(ProbeReport report, AdapterDesc1 desc)
        {
            report.adapter_description = desc.Description;
            report.vendor_id = "0x" + desc.VendorId.ToString("X8"); report.device_id = "0x" + desc.DeviceId.ToString("X8");
            report.subsystem_id = "0x" + desc.SubSysId.ToString("X8"); report.revision = "0x" + desc.Revision.ToString("X8");
            report.adapter_luid = unchecked((uint)desc.AdapterLuid.High).ToString("X8") + ":" + desc.AdapterLuid.Low.ToString("X8");
            report.adapter_flags = desc.Flags;
            report.dxgi_software_flag = IsSoftware(desc.Flags);
            // Actual Windows baseline returned this software renderer with Flags=0.
            report.software_adapter = report.dxgi_software_flag || (desc.VendorId == 0x1414 && desc.DeviceId == 0x008c);
            if (report.software_adapter) throw new ProbeFailure("adapter", "Software adapter (DXGI flag or Microsoft Basic Render ID); Device/Scene refused.", null);
            if (desc.VendorId != 0x1af4 || desc.DeviceId != 0x1050)
                throw new ProbeFailure("adapter_target", "Expected VirtIO GPU vendor 0x1AF4/device 0x1050; Device/Scene refused.", null);
            report.expected_adapter_verified = true;
            // Compatibility field: only API creation plus target identity, never host-GPU proof.
            report.hardware_adapter_verified = report.device_creation_succeeded;
        }
        private static bool ObservePresent(ProbeReport report, int hr)
        {
            report.present_attempts++; report.last_present_hresult = Hex(hr);
            if (hr == StatusOccluded) { report.present_occluded++; return false; }
            Check(hr, "Present");
            if (hr != 0) throw new ProbeFailure("Present", "Non-S_OK status is not counted as a completed presentation: " + Hex(hr), hr);
            report.present_s_ok++;
            return true;
        }
        private static bool IsFullscreen(IntPtr swap)
        {
            int enabled; IntPtr output = IntPtr.Zero;
            try { Check(Method<FullscreenQueryNative>(swap, GetFullscreenStateSlot)(swap, out enabled, out output), "GetFullscreenState"); return enabled != 0; }
            finally { Release(ref output); }
        }

        public static ProbeReport Run(string mode, bool exclusive, int frames, int seconds)
        {
            lock (RunLock) { return RunOnce(mode, exclusive, frames, seconds); }
        }
        private static ProbeReport RunOnce(string mode, bool exclusive, int frames, int seconds)
        {
            ProbeReport report = new ProbeReport();
            report.mode = mode; report.exclusive_requested = exclusive;
            report.requested_frames = frames; report.requested_seconds = seconds;
            IntPtr device = IntPtr.Zero, context = IntPtr.Zero, dxgi = IntPtr.Zero, adapter = IntPtr.Zero, adapter1 = IntPtr.Zero;
            try
            {
                mode = NormalizeMode(mode); report.mode = mode;
                if ((exclusive && mode != "Scene") || frames < 1 || frames > 600 || seconds < 1 || seconds > 30)
                    throw new ProbeFailure("arguments", "Use Device/Scene; exclusive only with Scene; 1..600 frames, 1..30 seconds.", null);
                if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                    throw new ProbeFailure("platform", "This diagnostic requires Windows; no native graphics function was called.", null);
                ushort processMachine, nativeMachine;
                if (!Native.IsWow64Process2(Native.GetCurrentProcess(), out processMachine, out nativeMachine))
                    throw new ProbeFailure("architecture", "IsWow64Process2 failed: " + Marshal.GetLastWin32Error(), null);
                report.process_machine = "0x" + processMachine.ToString("X4");
                report.native_machine = "0x" + nativeMachine.ToString("X4");
                report.native_arm64 = IsNativeArm64(processMachine, nativeMachine, IntPtr.Size);
                if (!report.native_arm64) throw new ProbeFailure("architecture", "Use native ARM64 PowerShell, not an emulated x86/x64 process.", null);
                uint level;
                int hr = Native.D3D11CreateDevice(IntPtr.Zero, HardwareDriver, IntPtr.Zero, BgraSupport, Levels, (uint)Levels.Length, SdkVersion, out device, out level, out context);
                report.device_creation_hresult = Hex(hr);
                CaptureUmdModules(report);
                Check(hr, "D3D11CreateDevice(HARDWARE)");
                if (device == IntPtr.Zero || context == IntPtr.Zero) throw new ProbeFailure("device", "Creation returned null device/context", null);
                report.device_creation_succeeded = true; report.feature_level = FeatureLevel(level);
                StringBuilder dllPath = new StringBuilder(32768);
                if (Native.GetModuleFileNameW(Native.GetModuleHandleW("d3d11.dll"), dllPath, (uint)dllPath.Capacity) != 0) report.system_d3d11_path = dllPath.ToString();
                dxgi = Interface(device, DxgiDeviceId, "IDXGIDevice");
                Check(Method<GetAdapterNative>(dxgi, GetAdapterSlot)(dxgi, out adapter), "GetAdapter");
                adapter1 = Interface(adapter, Adapter1Id, "IDXGIAdapter1");
                AdapterDesc1 desc;
                Check(Method<GetDescNative>(adapter1, GetDesc1Slot)(adapter1, out desc), "GetDesc1");
                ValidateAdapter(report, desc);
                if (mode == "Scene") RenderScene(report, device, context, adapter, exclusive, frames, seconds);
                report.success = mode == "Device" || report.scene_completed;
            }
            catch (ProbeFailure error) { report.error_stage = error.Stage; report.error_message = error.Message; report.error_hresult = error.Result.HasValue ? Hex(error.Result.Value) : null; }
            catch (Exception error) { report.error_stage = "managed_or_native_binding"; report.error_message = error.GetType().FullName + ": " + error.Message; }
            finally { Release(ref adapter1); Release(ref adapter); Release(ref dxgi); Release(ref context); Release(ref device); }
            return report;
        }

        private static void RenderScene(ProbeReport report, IntPtr device, IntPtr context, IntPtr adapter, bool exclusive, int frames, int seconds)
        {
            report.scene_attempted = true;
            if (report.session_id == 0 || !Environment.UserInteractive) throw new ProbeFailure("session", "Scene requires the interactive desktop, not Session 0.", null);
            IntPtr factory = IntPtr.Zero, swap = IntPtr.Zero, buffer = IntPtr.Zero, view = IntPtr.Zero, context1 = IntPtr.Zero;
            bool enteredFullscreen = false;
            using (NativeWindow window = new NativeWindow(report.width, report.height))
            {
                try
                {
                    context1 = Interface(context, Context1Id, "ID3D11DeviceContext1");
                    Guid factoryId = Factory2Id;
                    Check(Method<Query>(adapter, GetParentSlot)(adapter, ref factoryId, out factory), "GetParent(IDXGIFactory2)");
                    Check(Method<AssociateNative>(factory, MakeWindowAssociationSlot)(factory, window.Handle, 2), "MakeWindowAssociation(NO_ALT_ENTER)");
                    SwapDesc1 desc = new SwapDesc1();
                    desc.Width = (uint)report.width; desc.Height = (uint)report.height; desc.Format = 87;
                    desc.Sample.Count = 1; desc.Usage = 0x20; desc.BufferCount = 2; desc.SwapEffect = 4; desc.AlphaMode = 3;
                    Check(Method<CreateSwapNative>(factory, CreateSwapChainForHwndSlot)(factory, device, window.Handle, ref desc, IntPtr.Zero, IntPtr.Zero, out swap), "CreateSwapChainForHwnd");
                    if (exclusive)
                    {
                        Check(Method<FullscreenNative>(swap, SetFullscreenStateSlot)(swap, 1, IntPtr.Zero), "SetFullscreenState(true)");
                        enteredFullscreen = true;
                        report.exclusive_observed = IsFullscreen(swap);
                        if (!report.exclusive_observed) throw new ProbeFailure("exclusive", "DXGI did not confirm exclusive state.", null);
                        // Required after a flip-model fullscreen transition,
                        // before acquiring any buffer/RTV and before Present.
                        Check(Method<ResizeBuffersNative>(swap, ResizeBuffersSlot)(swap, 2, (uint)report.width, (uint)report.height, 87, 0), "ResizeBuffers(fullscreen transition)");
                    }
                    Guid textureId = Texture2DId;
                    Check(Method<GetBufferNative>(swap, GetBufferSlot)(swap, 0, ref textureId, out buffer), "GetBuffer(0)");
                    Check(Method<CreateRtvNative>(device, CreateRenderTargetViewSlot)(device, buffer, IntPtr.Zero, out view), "CreateRenderTargetView");
                    Release(ref buffer);
                    Stopwatch timer = Stopwatch.StartNew();
                    while (report.present_attempts < frames && timer.Elapsed.TotalSeconds < seconds)
                    {
                        window.Pump();
                        if (window.Closed) { report.user_closed = true; break; }
                        DrawPattern(context1, view, report.present_s_ok + 1, report.width, report.height);
                        int hr = Method<PresentNative>(swap, PresentSlot)(swap, 1, 0);
                        if (!ObservePresent(report, hr)) { Thread.Sleep(50); continue; }
                        window.Title("Perpendicular D3D11 HARDWARE - accepted Present " + report.present_s_ok + " - " + (exclusive ? "exclusive" : "windowed"));
                    }
                    timer.Stop(); report.scene_elapsed_ms = timer.ElapsedMilliseconds;
                    int removed = Method<RemovedNative>(device, GetDeviceRemovedReasonSlot)(device);
                    report.device_removed_hresult = Hex(removed); Check(removed, "GetDeviceRemovedReason");
                    if (exclusive)
                    {
                        report.exclusive_end_observed = IsFullscreen(swap);
                        if (!report.exclusive_end_observed) throw new ProbeFailure("exclusive", "DXGI left exclusive mode during the probe.", null);
                    }
                    report.scene_completed = report.present_s_ok > 0 && !report.user_closed;
                    if (!report.scene_completed) throw new ProbeFailure("scene", report.user_closed ? "User closed the probe before completion." : "No Present returned S_OK.", null);
                }
                finally
                {
                    if (enteredFullscreen && swap != IntPtr.Zero)
                    {
                        int restored = Method<FullscreenNative>(swap, SetFullscreenStateSlot)(swap, 0, IntPtr.Zero);
                        report.fullscreen_restore_hresult = Hex(restored);
                        if (restored != 0)
                        {
                            report.scene_completed = false;
                            report.error_stage = "fullscreen_restore"; report.error_hresult = Hex(restored);
                            report.error_message = "Fullscreen restoration did not return S_OK.";
                        }
                    }
                    Release(ref view); Release(ref buffer); Release(ref swap); Release(ref factory); Release(ref context1);
                }
            }
        }

        private static void DrawPattern(IntPtr context1, IntPtr view, int frame, int width, int height)
        {
            ClearViewNative clear = Method<ClearViewNative>(context1, ClearViewSlot);
            float[][] colors = { new float[] { 1, 0, 0, 1 }, new float[] { 0, 1, 0, 1 }, new float[] { 0, 0, 1, 1 }, new float[] { 1, 1, 1, 1 }, new float[] { 0, 0, 0, 1 } };
            Rect full = new Rect(0, 0, width, height);
            clear(context1, view, colors[(frame / 30) % 3], ref full, 1);
            for (int quadrant = 0; quadrant < 4; quadrant++)
            {
                int x = (quadrant % 2) * width / 2, y = (quadrant / 2) * height / 2;
                Rect rect = new Rect(x + 16, y + 16, x + width / 2 - 16, y + height / 2 - 16);
                clear(context1, view, colors[quadrant], ref rect, 1);
            }
            for (int bit = 0; bit < 16; bit++)
            {
                Rect rect = new Rect(16 + bit * 24, height - 40, 36 + bit * 24, height - 16);
                clear(context1, view, colors[(frame & (1 << bit)) != 0 ? 3 : 4], ref rect, 1);
            }
        }

        private sealed class NativeWindow : IDisposable
        {
            internal IntPtr Handle;
            internal bool Closed;
            private readonly string className = "Perpendicular3DProbe-" + Guid.NewGuid().ToString("N");
            private readonly Native.WindowProc procedure;
            private readonly IntPtr instance;
            private bool registered;
            internal NativeWindow(int width, int height)
            {
                procedure = OnMessage; instance = Native.GetModuleHandleW(null);
                Native.WindowClass definition = new Native.WindowClass();
                definition.Size = (uint)Marshal.SizeOf(typeof(Native.WindowClass)); definition.Instance = instance;
                definition.Procedure = Marshal.GetFunctionPointerForDelegate(procedure); definition.ClassName = className;
                definition.Cursor = Native.LoadCursorW(IntPtr.Zero, new IntPtr(32512));
                if (Native.RegisterClassExW(ref definition) == 0) throw new ProbeFailure("window", "RegisterClassEx failed: " + Marshal.GetLastWin32Error(), null);
                registered = true;
                try
                {
                    const uint style = 0x00ca0000; // Caption, system menu, minimize. No resize/maximize.
                    Rect bounds = new Rect(0, 0, width, height);
                    if (!Native.AdjustWindowRect(ref bounds, style, false)) throw new ProbeFailure("window", "AdjustWindowRect failed", null);
                    Handle = Native.CreateWindowExW(0, className, "Perpendicular D3D11 hardware probe", style, unchecked((int)0x80000000), unchecked((int)0x80000000), bounds.Right - bounds.Left, bounds.Bottom - bounds.Top, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
                    if (Handle == IntPtr.Zero) throw new ProbeFailure("window", "CreateWindowEx failed: " + Marshal.GetLastWin32Error(), null);
                    Native.ShowWindow(Handle, 5);
                }
                catch { Dispose(); throw; }
            }
            private IntPtr OnMessage(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam)
            {
                if (message == 0x10 || message == 2) { Closed = true; return IntPtr.Zero; }
                return Native.DefWindowProcW(hwnd, message, wparam, lparam);
            }
            internal void Pump()
            {
                Native.Message message;
                for (int count = 0; count < 64 && Native.PeekMessageW(out message, IntPtr.Zero, 0, 0, 1); count++)
                {
                    if (message.Id == 0x12) { Closed = true; break; }
                    Native.TranslateMessage(ref message); Native.DispatchMessageW(ref message);
                }
            }
            internal void Title(string title) { Native.SetWindowTextW(Handle, title); }
            public void Dispose()
            {
                if (Handle != IntPtr.Zero) { Native.DestroyWindow(Handle); Handle = IntPtr.Zero; }
                if (registered) { Native.UnregisterClassW(className, instance); registered = false; }
                GC.KeepAlive(procedure);
            }
        }

        private static class Native
        {
            [UnmanagedFunctionPointer(CallingConvention.StdCall)] internal delegate IntPtr WindowProc(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
            [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct WindowClass
            {
                public uint Size, Style;
                public IntPtr Procedure;
                public int ClassExtra, WindowExtra;
                public IntPtr Instance, Icon, Cursor, Background;
                [MarshalAs(UnmanagedType.LPWStr)] public string MenuName;
                [MarshalAs(UnmanagedType.LPWStr)] public string ClassName;
                public IntPtr SmallIcon;
            }
            [StructLayout(LayoutKind.Sequential)] internal struct Point { public int X, Y; }
            [StructLayout(LayoutKind.Sequential)] internal struct Message { public IntPtr Window; public uint Id; public UIntPtr WParam; public IntPtr LParam; public uint Time; public Point Position; public uint Private; }
            [DllImport("d3d11.dll"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
            internal static extern int D3D11CreateDevice(IntPtr adapter, uint driver, IntPtr software, uint flags, [In] uint[] levels, uint count, uint sdk, out IntPtr device, out uint level, out IntPtr context);
            [DllImport("kernel32.dll", SetLastError = true), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
            [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
            [DllImport("kernel32.dll"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] internal static extern IntPtr GetCurrentProcess();
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] internal static extern IntPtr GetModuleHandleW(string name);
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] internal static extern uint GetModuleFileNameW(IntPtr module, StringBuilder path, uint size);
            [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] internal static extern ushort RegisterClassExW(ref WindowClass value);
            [DllImport("user32.dll", CharSet = CharSet.Unicode), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UnregisterClassW(string name, IntPtr instance);
            [DllImport("user32.dll", CharSet = CharSet.Unicode), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] internal static extern IntPtr LoadCursorW(IntPtr instance, IntPtr name);
            [DllImport("user32.dll", SetLastError = true), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool AdjustWindowRect(ref Rect bounds, uint style, [MarshalAs(UnmanagedType.Bool)] bool menu);
            [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] internal static extern IntPtr CreateWindowExW(uint exStyle, string className, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
            [DllImport("user32.dll"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ShowWindow(IntPtr window, int command);
            [DllImport("user32.dll", CharSet = CharSet.Unicode), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] internal static extern IntPtr DefWindowProcW(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
            [DllImport("user32.dll"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool PeekMessageW(out Message message, IntPtr window, uint min, uint max, uint flags);
            [DllImport("user32.dll"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TranslateMessage(ref Message message);
            [DllImport("user32.dll", CharSet = CharSet.Unicode), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] internal static extern IntPtr DispatchMessageW(ref Message message);
            [DllImport("user32.dll", CharSet = CharSet.Unicode), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetWindowTextW(IntPtr window, string text);
            [DllImport("user32.dll"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool DestroyWindow(IntPtr window);
        }

        // No Windows DLL, GPU, window, VM or host bridge is called by these tests.
        public static string[] SelfTest()
        {
            List<string> passed = new List<string>();
            if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(AdapterDesc1)) != 312 || Marshal.OffsetOf(typeof(AdapterDesc1), "Flags").ToInt32() != 304 || Marshal.SizeOf(typeof(SwapDesc1)) != 48 || Marshal.SizeOf(typeof(Rect)) != 16 || Marshal.SizeOf(typeof(Native.WindowClass)) != 80 || Marshal.SizeOf(typeof(Native.Message)) != 48)
                throw new Exception("Win64 structure layout mismatch");
            passed.Add("Win64 struct sizes/adapter flag offset");
            if (FeatureLevel(0xb100) != "11_1" || FeatureLevel(0xa000) != "10_0" || Hex(unchecked((int)0x887A0005)) != "0x887A0005") throw new Exception("Result formatting mismatch");
            passed.Add("Feature-level and negative HRESULT reporting");
            if (HardwareDriver != 1 || SdkVersion != 7 || !IsNativeArm64(0, 0xaa64, 8) || IsNativeArm64(0x8664, 0xaa64, 8) || IsNativeArm64(0, 0x8664, 8) || IsNativeArm64(0, 0xaa64, 4) || !IsSoftware(2) || IsSoftware(0)) throw new Exception("Hardware/native-architecture admission failed");
            passed.Add("HARDWARE constant, ARM64-only admission and software-adapter rejection");
            string[] modes = { "Device", "device", "DEVICE", "DeViCe", "Scene", "scene", "SCENE", "sCeNe" };
            foreach (string mode in modes)
            {
                string expected = mode.StartsWith("d", StringComparison.OrdinalIgnoreCase) ? "Device" : "Scene";
                if (NormalizeMode(mode) != expected) throw new Exception("Mode casing was not canonicalized");
                if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                {
                    ProbeReport denied = Run(mode, expected == "Scene", 1, 1);
                    if (denied.mode != expected || denied.error_stage != "platform" || denied.success || denied.native_arm64 || denied.scene_attempted || denied.device_creation_succeeded)
                        throw new Exception("Accepted mode casing failed arguments or reached native calls");
                }
            }
            foreach (string mode in new string[] { null, "", " device", "Scenes", "WARP" })
            {
                ProbeReport denied = Run(mode, false, 1, 1);
                if (denied.error_stage != "arguments" || denied.device_creation_succeeded || denied.scene_attempted) throw new Exception("Invalid mode was admitted");
            }
            passed.Add("Eight Device/Scene casings canonicalized; invalid modes rejected before native calls");
            foreach (uint[] identity in new uint[][] { new uint[] { 0x1414, 0x008c, 0 }, new uint[] { 0x1234, 0x1050, 0 }, new uint[] { 0x1af4, 0x1050, 2 }, new uint[] { 0x1af4, 0x1050, 0 } })
            {
                AdapterDesc1 desc = new AdapterDesc1();
                desc.Description = identity[0] == 0x1414 ? "Microsoft Basic Render Driver" : "Test adapter";
                desc.VendorId = identity[0]; desc.DeviceId = identity[1]; desc.Flags = identity[2];
                ProbeReport candidate = new ProbeReport();
                candidate.device_creation_succeeded = true; candidate.device_creation_hresult = "0x00000000";
                candidate.native_arm64 = true; candidate.feature_level = "11_1";
                bool denied = false; string stage = null;
                try { ValidateAdapter(candidate, desc); } catch (ProbeFailure error) { denied = true; stage = error.Stage; }
                bool expected = identity[0] == 0x1af4 && identity[1] == 0x1050 && identity[2] == 0;
                if (denied == expected || candidate.expected_adapter_verified != expected || candidate.hardware_adapter_verified != expected || candidate.host_acceleration_verified || candidate.scene_attempted)
                    throw new Exception("Target identity/software classification escaped admission");
                if (identity[0] == 0x1414 && (stage != "adapter" || !candidate.software_adapter || candidate.dxgi_software_flag || candidate.adapter_description != "Microsoft Basic Render Driver" || candidate.vendor_id != "0x00001414" || candidate.device_id != "0x0000008C"))
                    throw new Exception("Actual Windows Basic Render flags=0 counterexample was not rejected");
                if (identity[0] == 0x1234 && stage != "adapter_target") throw new Exception("Unexpected non-software adapter was admitted");
            }
            passed.Add("Actual Basic Render S_OK/11_1/flags=0 counterexample rejected; only non-software VirtIO 1AF4:1050 admitted, host acceleration unclaimed");
            if (!IsUmdName("neptune_umd.dll") || !IsUmdName("NEPTUNE_UMD_ARM64.DLL") || IsUmdName(null) || IsUmdName("otherneptune_umd.dll") || IsUmdName("neptune_umd.dll.extra"))
                throw new Exception("UMD module-name filter escaped its prefix/suffix");
            string fixture = Path.GetTempFileName();
            try
            {
                File.WriteAllBytes(fixture, Encoding.ASCII.GetBytes("abc"));
                long budget = 3; UmdModuleReport hashed = HashUmdFile(fixture, ref budget);
                if (hashed.hash_status != "available" || hashed.sha256 != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" || hashed.disk_file_bytes != 3 || budget != 0)
                    throw new Exception("Full UMD-file SHA256/budget mismatch");
                budget = 2; hashed = HashUmdFile(fixture, ref budget);
                if (hashed.hash_status != "unknown" || hashed.sha256 != null || hashed.hash_error == null || budget != 2) throw new Exception("UMD aggregate hash budget escaped its bound");
                using (FileStream stream = new FileStream(fixture, FileMode.Open, FileAccess.Write)) { stream.SetLength(MaxUmdFileBytes + 1); }
                budget = 32 * 1024 * 1024; hashed = HashUmdFile(fixture, ref budget);
                if (hashed.hash_status != "unknown" || hashed.sha256 != null || hashed.hash_error == null || budget != 32 * 1024 * 1024) throw new Exception("UMD file hash limit escaped its bound");
                File.Delete(fixture); hashed = HashUmdFile(fixture, ref budget);
                if (hashed.hash_status != "unknown" || hashed.sha256 != null || hashed.hash_error == null) throw new Exception("Unavailable UMD file was reported as hashed");
            }
            finally { if (File.Exists(fixture)) File.Delete(fixture); }
            passed.Add("Neptune-only module filter; full known SHA256, aggregate/per-file bounds and unavailable-file unknown status");
            ProbeReport present = new ProbeReport();
            if (!ObservePresent(present, 0) || ObservePresent(present, StatusOccluded) || present.present_s_ok != 1 || present.present_occluded != 1) throw new Exception("Present status was reported as success");
            foreach (int failed in new int[] { unchecked((int)0x887A0005), 0x087A0007 })
            {
                bool denied = false;
                try { ObservePresent(present, failed); } catch (ProbeFailure) { denied = true; }
                if (!denied || present.present_s_ok != 1) throw new Exception("Non-S_OK Present escaped rejection");
            }
            passed.Add("Only S_OK counts; occlusion, device removal and other statuses are distinct");
            ProbeReport invalid = Run("Scene", true, 601, 1);
            if (invalid.success || invalid.error_stage != "arguments" || invalid.scene_attempted || invalid.device_creation_succeeded || invalid.software_fallback) throw new Exception("Invalid probe request was admitted");
            passed.Add("Bounds fail before native calls; no software fallback");
            int calls = 0, releases = 0;
            ClearViewNative draw = delegate(IntPtr self, IntPtr view, float[] color, ref Rect rect, uint count)
            {
                if (view != new IntPtr(0x1234) || count != 1 || rect.Left < 0 || rect.Top < 0 || rect.Right > 800 || rect.Bottom > 600 || rect.Right <= rect.Left || rect.Bottom <= rect.Top || color.Length != 4 || color[3] != 1) throw new Exception("Invalid pattern command");
                if (calls >= 5)
                {
                    int bit = calls - 5; float expected = (5 & (1 << bit)) != 0 ? 1 : 0;
                    if (color[0] != expected || color[1] != expected || color[2] != expected) throw new Exception("Pixel counter bit mismatch");
                }
                calls++;
            };
            ReleaseNative release = delegate(IntPtr self) { releases++; return 0; };
            IntPtr table = Marshal.AllocHGlobal(133 * IntPtr.Size), instance = Marshal.AllocHGlobal(IntPtr.Size);
            try
            {
                for (int i = 0; i < 133; i++) Marshal.WriteIntPtr(table, i * IntPtr.Size, IntPtr.Zero);
                Marshal.WriteIntPtr(table, ClearViewSlot * IntPtr.Size, Marshal.GetFunctionPointerForDelegate(draw));
                Marshal.WriteIntPtr(table, ReleaseSlot * IntPtr.Size, Marshal.GetFunctionPointerForDelegate(release));
                Marshal.WriteIntPtr(instance, table);
                DrawPattern(instance, new IntPtr(0x1234), 5, 800, 600);
                if (calls != 21) throw new Exception("Expected one clear, four quadrants and sixteen counter rectangles");
                IntPtr owned = instance; Release(ref owned); Release(ref owned);
                if (owned != IntPtr.Zero || releases != 1) throw new Exception("COM ownership released more than once");
            }
            finally { Marshal.FreeHGlobal(instance); Marshal.FreeHGlobal(table); GC.KeepAlive(draw); GC.KeepAlive(release); }
            passed.Add("Owned mock vtable/delegate dispatch, bounded pixel-counter commands and one-release ownership");
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
            {
                ProbeReport denied = Run("Device", false, 1, 1);
                if (denied.success || denied.error_stage != "platform" || denied.device_creation_succeeded || denied.scene_attempted) throw new Exception("Non-Windows host reached graphics APIs");
                passed.Add("Non-Windows execution fails closed before DLL calls");
            }
            return passed.ToArray();
        }
    }
}

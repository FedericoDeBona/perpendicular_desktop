// Independent per-instance Guest Tools access preparation. No API runs at load.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Perpendicular.ChannelAccess {
    public static class Descriptor {
        static void Need(bool condition, string message) { if (!condition) throw new InvalidDataException(message); }
        static ushort U16(byte[] b, int p) { Need(p >= 0 && p + 2 <= b.Length, "Truncated descriptor"); return BitConverter.ToUInt16(b, p); }
        static uint U32(byte[] b, int p) { Need(p >= 0 && p + 4 <= b.Length, "Truncated descriptor"); return BitConverter.ToUInt32(b, p); }
        static void Put16(byte[] b, int p, ushort v) { Buffer.BlockCopy(BitConverter.GetBytes(v), 0, b, p, 2); }
        static void Put32(byte[] b, int p, uint v) { Buffer.BlockCopy(BitConverter.GetBytes(v), 0, b, p, 4); }
        static int SidLength(byte[] b, int p) {
            Need(p >= 0 && p + 8 <= b.Length && b[p] == 1 && b[p + 1] <= 15, "Malformed SID");
            int length = 8 + 4 * b[p + 1]; Need(p + length <= b.Length, "Truncated SID"); return length;
        }
        public static byte[] UserSid(string value) {
            Need(value != null && Regex.IsMatch(value, @"\AS-1-5-21-(0|[1-9][0-9]{0,9})-(0|[1-9][0-9]{0,9})-(0|[1-9][0-9]{0,9})-(0|[1-9][0-9]{0,9})\z"), "Expected a desktop account SID");
            string[] parts = value.Split('-'); byte[] sid = new byte[28]; sid[0] = 1; sid[1] = 5; sid[7] = 5;
            Put32(sid, 8, 21);
            for (int i = 0; i < 4; i++) { uint n; Need(UInt32.TryParse(parts[i + 4], out n), "SID component out of range"); Put32(sid, 12 + i * 4, n); }
            return sid;
        }
        public static bool Equal(byte[] a, byte[] b) {
            if (a == null || b == null) return a == null && b == null;
            if (a.Length != b.Length) return false;
            int different = 0; for (int i = 0; i < a.Length; i++) different |= a[i] ^ b[i]; return different == 0;
        }
        static byte[] Slice(byte[] b, int p, int count) { byte[] result = new byte[count]; Buffer.BlockCopy(b, p, result, 0, count); return result; }
        static byte[][] Sections(byte[] sd) {
            Need(sd != null && sd.Length >= 20 && sd.Length <= 65536 && sd[0] == 1 && (U16(sd, 2) & 0x8004) == 0x8004, "Expected a self-relative descriptor with a non-null DACL");
            byte[][] result = new byte[4][]; List<int[]> ranges = new List<int[]>();
            for (int i = 0; i < 4; i++) {
                uint raw = U32(sd, 4 + i * 4); Need(raw <= 65536, "Descriptor offset out of range"); int p = (int)raw;
                if (p == 0) { Need(i != 3, "Null DACL refused"); continue; }
                Need(p >= 20 && p % 4 == 0 && p + 8 <= sd.Length, "Invalid descriptor section");
                int length = i < 2 ? SidLength(sd, p) : U16(sd, p + 2);
                Need(length >= 8 && p + length <= sd.Length, "Truncated descriptor section");
                foreach (int[] range in ranges) Need(p + length <= range[0] || p >= range[1], "Overlapping descriptor sections");
                ranges.Add(new int[] {p, p + length}); result[i] = Slice(sd, p, length);
            }
            return result;
        }
        public static byte[] Dacl(byte[] sd) { return Sections(sd)[3]; }
        public static byte[] AddReadWrite(byte[] sd, string ownerSid) {
            byte[] user = UserSid(ownerSid); byte[][] sections = Sections(sd); byte[] acl = sections[3];
            Need((acl[0] == 2 || acl[0] == 4) && acl[1] == 0 && U16(acl, 2) == acl.Length && U16(acl, 4) > 0 && U16(acl, 4) <= 128, "Unexpected/empty DACL");
            int p = 8, insert = -1; bool inherited = false, already = false;
            for (int i = 0; i < U16(acl, 4); i++) {
                Need(p + 8 <= acl.Length, "Truncated ACE"); int size = U16(acl, p + 2);
                Need(size >= 16 && size % 4 == 0 && p + size <= acl.Length && (acl[p] == 0 || acl[p] == 1) && (acl[p + 1] & ~31) == 0, "Unsupported ACE type/flags");
                Need(acl[p] != 1, "A deny ACE requires manual security review");
                Need(size == 8 + SidLength(acl, p + 8), "Malformed ACE SID");
                bool itemInherited = (acl[p + 1] & 16) != 0;
                Need(!inherited || itemInherited, "Noncanonical DACL");
                if (itemInherited && !inherited) { inherited = true; insert = p; }
                uint mask = U32(acl, p + 4);
                if ((acl[p + 1] & 8) == 0 && Equal(Slice(acl, p + 8, size - 8), user) && ((mask & 0xc0000000U) == 0xc0000000U || (mask & 0x10000000U) != 0)) already = true;
                p += size;
            }
            Need(p <= acl.Length && acl.Length - p < 4, "Unexpected DACL padding");
            if (already) return (byte[])sd.Clone();
            if (insert < 0) insert = p;
            byte[] ace = new byte[8 + user.Length]; Put16(ace, 2, (ushort)ace.Length); Put32(ace, 4, 0xc0000000U); Buffer.BlockCopy(user, 0, ace, 8, user.Length);
            Need(acl.Length + ace.Length <= UInt16.MaxValue && U16(acl, 4) < UInt16.MaxValue, "DACL capacity exceeded");
            byte[] next = new byte[acl.Length + ace.Length];
            Buffer.BlockCopy(acl, 0, next, 0, insert); Buffer.BlockCopy(ace, 0, next, insert, ace.Length); Buffer.BlockCopy(acl, insert, next, insert + ace.Length, acl.Length - insert);
            Put16(next, 2, (ushort)next.Length); Put16(next, 4, (ushort)(U16(acl, 4) + 1)); sections[3] = next;
            int total = 20; foreach (byte[] section in sections) if (section != null) total += section.Length;
            Need(total <= 65536, "Descriptor capacity exceeded"); byte[] output = new byte[total]; Buffer.BlockCopy(sd, 0, output, 0, 20); p = 20;
            for (int i = 0; i < 4; i++) { byte[] section = sections[i]; Put32(output, 4 + i * 4, section == null ? 0U : (uint)p); if (section != null) { Buffer.BlockCopy(section, 0, output, p, section.Length); p += section.Length; } }
            return output;
        }
    }

    public enum ClassGuidReadState { NotRead, Observed, Unavailable, Invalid, Absent }
    public enum CapabilitiesReadState { NotRead, Observed, Unavailable, Invalid }

    public sealed class Port {
        public string InstanceId, PdoName, ParentId, ParentService;
        public Guid ClassGuid, InterfaceDetailClassGuid;
        public ClassGuidReadState ClassGuidState;
        public int ClassGuidPropertyError;
        public Guid UnifiedClassGuid;
        public ClassGuidReadState UnifiedClassGuidState;
        public int UnifiedClassGuidPropertyError;
        public uint Capabilities;
        public CapabilitiesReadState CapabilitiesState;
        public int CapabilitiesPropertyError;
        public string[] HardwareIds, ParentHardwareIds;
        public uint Status, Problem, ParentStatus, ParentProblem;
        public byte[] Property, LiveDaclDescriptor;
    }

    // Only fixed labels, bounded counts and booleans may leave the native
    // identity gate. Never include a device path, instance ID, SID or DACL.
    public sealed class PortIdentityChecks {
        public bool CandidatePresent, ClassGuidMatches, HardwareIdsPresent, HardwareIdSingle, HardwareIdExact;
        public bool InstancePrefixMatches, InstanceSuffixValid, AliasMatches, PdoNameSyntax;
        public bool ParentServiceMatches, ParentPciIdentityValid, ParentHardwareIdsPresent, ParentHardwareMatchesInstance;
        public bool ChildProblemZero, ParentProblemZero, ParentStarted, ChildNoProblemFlag, ParentNoProblemFlag;
        public bool RawPortIdentity, InstanceIdentity, FixedAlias, ParentIdentity, ParentHardwareAvailable, Healthy, Valid;
        // -1 means unavailable; 65 means more than the accepted 64 entries.
        public int HardwareIdCount = -1, ParentHardwareIdCount = -1;
        public string ClassGuidKind = "unavailable", InterfaceDetailClassGuidKind = "unavailable", ClassGuidSource = "unavailable", ClassGuidReadCode = "not_read", HardwareIdKind = "unavailable", FailureCode = "raw_port_identity";
        public int ClassGuidPropertyError;
        public bool ClasslessConfirmed, ExpectedSetupClassConfirmed, SetupClassAccepted;
        public string UnifiedClassGuidKind = "unavailable", UnifiedClassGuidSource = "unavailable", UnifiedClassGuidReadCode = "not_read", SetupClassIdentityCode = "rejected";
        public int UnifiedClassGuidPropertyError;
        public bool CapabilitiesObserved, RawDeviceOk;
        public string CapabilitiesSource = "unavailable", CapabilitiesReadCode = "not_read";
        public int CapabilitiesPropertyError;
    }

    public sealed class PortIdentityException : Exception {
        public readonly PortIdentityChecks Checks;
        public PortIdentityException(string message, PortIdentityChecks checks, Exception inner) : base(message, inner) { Checks = checks; }
    }

    public static class Device {
        public const string Name = "org.perpendicular.guest_agent.0";
        const string Alias = "Global\\org.perpendicular.guest_agent.0";
        const string OpenName = @"\\.\Global\org.perpendicular.guest_agent.0";
        public const string Hardware = @"{6FDE7547-1B65-48ae-B628-80BE62016026}\VIOSerialPort";
        static readonly Guid PortClass = new Guid("6fde7547-1b65-48ae-b628-80be62016026");
        static readonly Guid PortInterface = new Guid("6fde7521-1b65-48ae-b628-80be62016026");
        const uint ClassGuidRegistryProperty = 8; // SPDRP_CLASSGUID, REG_SZ
        const uint CapabilitiesRegistryProperty = 15; // SPDRP_CAPABILITIES, REG_DWORD
        const uint RawDeviceOkCapability = 0x40; // CM_DEVCAP_RAWDEVICEOK
        static readonly PropertyKey DeviceClass = new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 10); // DEVPKEY_Device_ClassGuid
        static readonly PropertyKey Security = new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 25);
        [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid Guid; public uint Id; public PropertyKey(Guid guid, uint id) { Guid = guid; Id = id; } }
        [StructLayout(LayoutKind.Sequential)] struct Info { public uint Size; public Guid ClassGuid; public uint DevInst; public UIntPtr Reserved; }
        [StructLayout(LayoutKind.Sequential)] struct Interface { public uint Size; public Guid Guid; public uint Flags; public UIntPtr Reserved; }
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SetupDiGetClassDevsW(ref Guid g, string enumerator, IntPtr hwnd, uint flags);
        [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr info, ref Guid g, uint index, ref Interface item);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr set, ref Interface item, IntPtr detail, uint size, out uint required, ref Info info);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiGetDeviceRegistryPropertyW(IntPtr set, ref Info info, uint key, out uint type, byte[] buffer, uint size, out uint required);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiOpenDeviceInfoW(IntPtr set, string id, IntPtr hwnd, uint flags, ref Info info);
        [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiGetDevicePropertyW(IntPtr set, ref Info info, ref PropertyKey key, out uint type, byte[] buffer, uint size, out uint required, uint flags);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiSetDevicePropertyW(IntPtr set, ref Info info, ref PropertyKey key, uint type, byte[] buffer, uint size, uint flags);
        [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode)] static extern uint CM_Get_Device_IDW(uint devinst, StringBuilder id, uint length, uint flags);
        [DllImport("cfgmgr32.dll")] static extern uint CM_Get_Parent(out uint parent, uint devinst, uint flags);
        [DllImport("cfgmgr32.dll")] static extern uint CM_Get_DevNode_Status(out uint status, out uint problem, uint devinst, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint QueryDosDeviceW(string name, char[] target, uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr attributes, uint disposition, uint flags, IntPtr template);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetKernelObjectSecurity(SafeFileHandle handle, uint information, byte[] buffer, uint size, out uint required);
        [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool WTSQuerySessionInformationW(IntPtr server, int session, int kind, out IntPtr data, out uint size);
        [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr data);
        static void Need(bool c, string message) { if (!c) throw new InvalidDataException(message); }
        static void Last() { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        static string Instance(uint devinst) { StringBuilder b = new StringBuilder(1024); Need(CM_Get_Device_IDW(devinst, b, 1024, 0) == 0, "Device instance unavailable"); return b.ToString(); }
        static string[] Strings(IntPtr set, ref Info info, uint key, uint expectedType) {
            uint type, size; bool ok = SetupDiGetDeviceRegistryPropertyW(set, ref info, key, out type, null, 0, out size);
            if (!ok && Marshal.GetLastWin32Error() != 122) Last();
            Need(size >= 2 && size <= 65536 && size % 2 == 0, "Unbounded device property");
            byte[] b = new byte[size]; if (!SetupDiGetDeviceRegistryPropertyW(set, ref info, key, out type, b, size, out size)) Last();
            Need(type == expectedType && size <= b.Length, "Device property type mismatch");
            string text = Encoding.Unicode.GetString(b, 0, (int)size); Need(text.EndsWith(expectedType == 7 ? "\0\0" : "\0", StringComparison.Ordinal), "Unterminated device property");
            string[] values = text.TrimEnd('\0').Split('\0'); Need(values.Length > 0 && values.Length <= 64, "Unexpected device property list"); return values;
        }
        static string One(IntPtr set, ref Info info, uint key) { string[] values = Strings(set, ref info, key, 1); Need(values.Length == 1 && values[0].Length > 0, "Expected one device property"); return values[0]; }
        static byte[] Property(IntPtr set, ref Info info) {
            PropertyKey key = Security; uint type, size;
            if (!SetupDiGetDevicePropertyW(set, ref info, ref key, out type, null, 0, out size, 0)) { int error = Marshal.GetLastWin32Error(); if (error == 1168) return null; if (error != 122) throw new Win32Exception(error); }
            Need(size >= 20 && size <= 65536, "Invalid security property size"); byte[] data = new byte[size];
            if (!SetupDiGetDevicePropertyW(set, ref info, ref key, out type, data, size, out size, 0)) Last();
            Need(type == 0x13 && size == data.Length, "Expected binary device security descriptor"); Descriptor.Dacl(data); return data;
        }
        static string Target() {
            char[] text = new char[4096]; uint count = QueryDosDeviceW(Alias, text, (uint)text.Length); if (count == 0) Last();
            Need(count <= text.Length, "DOS mapping exceeded bound"); string[] names = new string(text, 0, (int)count).TrimEnd('\0').Split('\0');
            Need(names.Length == 1 && Regex.IsMatch(names[0], @"\A\\Device\\[A-Za-z0-9_]{1,128}\z"), "Fixed global DOS alias is missing or ambiguous"); return names[0];
        }
        static string ClassGuidKind(Guid value) {
            return value == PortClass ? "expected_raw_port" : value == PortInterface ? "port_interface" :
                value == Guid.Empty ? "empty" : value == new Guid("4d36e97d-e325-11ce-bfc1-08002be10318") ? "system" :
                value == new Guid("4d36e978-e325-11ce-bfc1-08002be10318") ? "ports" : "other";
        }
        public static void ObserveClassGuid(Port port, string property) {
            Need(port != null, "Port metadata unavailable");
            port.ClassGuid = Guid.Empty; port.ClassGuidState = ClassGuidReadState.Invalid; port.ClassGuidPropertyError = 0;
            Guid observed = Guid.Empty;
            Need(property != null && property.Length <= 38 && String.Equals(property, property.Trim(), StringComparison.Ordinal) && (Guid.TryParseExact(property, "B", out observed) || Guid.TryParseExact(property, "D", out observed)), "Invalid observed device setup class");
            port.ClassGuid = observed; port.ClassGuidState = ClassGuidReadState.Observed; port.ClassGuidPropertyError = 0;
        }
        static void ReadClassGuid(IntPtr set, ref Info info, Port port) {
            // The raw WDF security-override GUID does not set the PnP setup
            // class. Observe SPDRP_CLASSGUID on this exact mapped devnode; do
            // not substitute a driver constant or the parent/probe class.
            port.InterfaceDetailClassGuid = info.ClassGuid;
            try { ObserveClassGuid(port, One(set, ref info, ClassGuidRegistryProperty)); }
            catch (Win32Exception error) {
                port.ClassGuidState = ClassGuidReadState.Unavailable; port.ClassGuidPropertyError = error.NativeErrorCode;
            } catch (InvalidDataException) {
                port.ClassGuidState = ClassGuidReadState.Invalid;
            }
        }
        public static void ObserveUnifiedClassGuid(Port port, bool success, int error, uint propertyType, byte[] bytes, uint required) {
            Need(port != null, "Port metadata unavailable");
            port.UnifiedClassGuid = Guid.Empty; port.UnifiedClassGuidState = ClassGuidReadState.Invalid; port.UnifiedClassGuidPropertyError = 0;
            if (!success) {
                port.UnifiedClassGuidState = error == 1168 ? ClassGuidReadState.Absent : ClassGuidReadState.Unavailable;
                port.UnifiedClassGuidPropertyError = error; return;
            }
            Need(error == 0 && propertyType == 0x0d && bytes != null && bytes.Length == 16 && required == 16, "Expected one device setup-class GUID");
            port.UnifiedClassGuid = new Guid(bytes); port.UnifiedClassGuidState = ClassGuidReadState.Observed;
        }
        static void ReadUnifiedClassGuid(IntPtr set, ref Info info, Port port) {
            PropertyKey key = DeviceClass; uint type, required; byte[] bytes = new byte[16];
            bool success = SetupDiGetDevicePropertyW(set, ref info, ref key, out type, bytes, 16, out required, 0);
            int error = success ? 0 : Marshal.GetLastWin32Error();
            try { ObserveUnifiedClassGuid(port, success, error, type, bytes, required); }
            catch (InvalidDataException) { port.UnifiedClassGuidState = ClassGuidReadState.Invalid; }
        }
        public static void ObserveCapabilities(Port port, uint registryType, byte[] bytes, uint required) {
            Need(port != null, "Port metadata unavailable");
            port.Capabilities = 0; port.CapabilitiesState = CapabilitiesReadState.Invalid; port.CapabilitiesPropertyError = 0;
            Need(registryType == 4 && bytes != null && bytes.Length == 4 && required == 4, "Expected one device capabilities DWORD");
            port.Capabilities = BitConverter.ToUInt32(bytes, 0); port.CapabilitiesState = CapabilitiesReadState.Observed; port.CapabilitiesPropertyError = 0;
        }
        static void ReadCapabilities(IntPtr set, ref Info info, Port port) {
            uint type, required; byte[] bytes = new byte[4];
            if (!SetupDiGetDeviceRegistryPropertyW(set, ref info, CapabilitiesRegistryProperty, out type, bytes, 4, out required)) {
                port.CapabilitiesState = CapabilitiesReadState.Unavailable; port.CapabilitiesPropertyError = Marshal.GetLastWin32Error(); return;
            }
            try { ObserveCapabilities(port, type, bytes, required); }
            catch (InvalidDataException) { port.CapabilitiesState = CapabilitiesReadState.Invalid; }
        }
        public static PortIdentityChecks GetIdentityChecks(Port port, string target) {
            PortIdentityChecks c = new PortIdentityChecks(); c.CandidatePresent = port != null;
            if (port == null) return c;
            c.ClassGuidMatches = port.ClassGuid == PortClass;
            c.ClassGuidKind = ClassGuidKind(port.ClassGuid); c.InterfaceDetailClassGuidKind = ClassGuidKind(port.InterfaceDetailClassGuid);
            c.ClassGuidSource = port.ClassGuidState == ClassGuidReadState.Observed ? "spdrp_classguid" : "unavailable";
            c.ClassGuidReadCode = port.ClassGuidState == ClassGuidReadState.Observed ? "observed" : port.ClassGuidState == ClassGuidReadState.Unavailable ? "api_unavailable" : port.ClassGuidState == ClassGuidReadState.Invalid ? "invalid_property" : "not_read";
            c.ClassGuidPropertyError = port.ClassGuidPropertyError;
            c.UnifiedClassGuidKind = ClassGuidKind(port.UnifiedClassGuid);
            c.UnifiedClassGuidSource = port.UnifiedClassGuidState == ClassGuidReadState.Observed || port.UnifiedClassGuidState == ClassGuidReadState.Absent ? "devpkey_device_classguid" : "unavailable";
            c.UnifiedClassGuidReadCode = port.UnifiedClassGuidState == ClassGuidReadState.Observed ? "observed" : port.UnifiedClassGuidState == ClassGuidReadState.Absent ? "not_found" : port.UnifiedClassGuidState == ClassGuidReadState.Unavailable ? "api_unavailable" : port.UnifiedClassGuidState == ClassGuidReadState.Invalid ? "invalid_property" : "not_read";
            c.UnifiedClassGuidPropertyError = port.UnifiedClassGuidPropertyError;
            // WDF's raw-device security GUID does not itself install a PnP
            // setup class. Permit classlessness only on these independent,
            // exact observations, never on legacy ERROR_INVALID_DATA alone.
            c.ClasslessConfirmed = port.UnifiedClassGuidState == ClassGuidReadState.Absent && port.UnifiedClassGuidPropertyError == 1168 && port.UnifiedClassGuid == Guid.Empty &&
                port.ClassGuidState == ClassGuidReadState.Unavailable && port.ClassGuidPropertyError == 13 && port.ClassGuid == Guid.Empty && port.InterfaceDetailClassGuid == Guid.Empty;
            c.ExpectedSetupClassConfirmed = port.UnifiedClassGuidState == ClassGuidReadState.Observed && port.UnifiedClassGuidPropertyError == 0 && port.UnifiedClassGuid == PortClass &&
                port.ClassGuidState == ClassGuidReadState.Observed && port.ClassGuidPropertyError == 0 && port.ClassGuid == PortClass &&
                (port.InterfaceDetailClassGuid == Guid.Empty || port.InterfaceDetailClassGuid == PortClass);
            c.SetupClassAccepted = c.ClasslessConfirmed || c.ExpectedSetupClassConfirmed;
            c.SetupClassIdentityCode = c.ClasslessConfirmed ? "classless_confirmed" : c.ExpectedSetupClassConfirmed ? "expected_class" : "rejected";
            c.CapabilitiesObserved = port.CapabilitiesState == CapabilitiesReadState.Observed;
            c.CapabilitiesSource = c.CapabilitiesObserved ? "spdrp_capabilities" : "unavailable";
            c.CapabilitiesReadCode = c.CapabilitiesObserved ? "observed" : port.CapabilitiesState == CapabilitiesReadState.Unavailable ? "api_unavailable" : port.CapabilitiesState == CapabilitiesReadState.Invalid ? "invalid_property" : "not_read";
            c.CapabilitiesPropertyError = port.CapabilitiesPropertyError;
            c.RawDeviceOk = c.CapabilitiesObserved && port.CapabilitiesPropertyError == 0 && (port.Capabilities & RawDeviceOkCapability) != 0;
            c.HardwareIdsPresent = port.HardwareIds != null;
            c.HardwareIdCount = port.HardwareIds == null ? -1 : Math.Min(port.HardwareIds.Length, 65);
            c.HardwareIdSingle = port.HardwareIds != null && port.HardwareIds.Length == 1;
            c.HardwareIdExact = c.HardwareIdSingle && String.Equals(port.HardwareIds[0], Hardware, StringComparison.OrdinalIgnoreCase);
            c.HardwareIdKind = c.HardwareIdExact ? "expected_single" : !c.HardwareIdsPresent ? "unavailable" : c.HardwareIdCount == 0 ? "empty" : c.HardwareIdSingle ? "other_single" : "multiple";
            c.RawPortIdentity = c.SetupClassAccepted && c.RawDeviceOk && c.HardwareIdExact;
            c.InstancePrefixMatches = port.InstanceId != null && port.InstanceId.Length <= 1024 && port.InstanceId.StartsWith(Hardware + "\\", StringComparison.OrdinalIgnoreCase);
            c.InstanceSuffixValid = c.InstancePrefixMatches && Regex.IsMatch(port.InstanceId.Substring(Hardware.Length + 1), @"\A[A-Za-z0-9_&-]{1,512}\z");
            c.InstanceIdentity = c.InstancePrefixMatches && c.InstanceSuffixValid;
            c.AliasMatches = String.Equals(port.PdoName, target, StringComparison.OrdinalIgnoreCase);
            c.PdoNameSyntax = target != null && Regex.IsMatch(target, @"\A\\Device\\[A-Za-z0-9_]{1,128}\z");
            c.FixedAlias = c.AliasMatches && c.PdoNameSyntax;
            c.ParentServiceMatches = String.Equals(port.ParentService, "VirtioSerial", StringComparison.OrdinalIgnoreCase);
            c.ParentPciIdentityValid = port.ParentId != null && Regex.IsMatch(port.ParentId, @"\APCI\\VEN_1AF4&DEV_(1003|1043)(?:&|\\)[A-Za-z0-9_&\\]+\z", RegexOptions.IgnoreCase);
            c.ParentIdentity = c.ParentServiceMatches && c.ParentPciIdentityValid;
            c.ParentHardwareIdsPresent = port.ParentHardwareIds != null;
            c.ParentHardwareIdCount = port.ParentHardwareIds == null ? -1 : Math.Min(port.ParentHardwareIds.Length, 65);
            c.ParentHardwareAvailable = port.ParentHardwareIds != null && port.ParentHardwareIds.Length > 0 && port.ParentHardwareIds.Length <= 64;
            if (c.ParentPciIdentityValid && c.ParentHardwareAvailable) {
                string device = Regex.Match(port.ParentId, @"DEV_(1003|1043)", RegexOptions.IgnoreCase).Groups[1].Value;
                foreach (string id in port.ParentHardwareIds) if (id != null && id.Length <= 1024 && Regex.IsMatch(id, @"\APCI\\VEN_1AF4&DEV_" + device + @"(?:&|\z)", RegexOptions.IgnoreCase)) c.ParentHardwareMatchesInstance = true;
            }
            c.ChildProblemZero = port.Problem == 0; c.ParentProblemZero = port.ParentProblem == 0;
            c.ParentStarted = (port.ParentStatus & 8) != 0; c.ChildNoProblemFlag = (port.Status & 0x400) == 0; c.ParentNoProblemFlag = (port.ParentStatus & 0x400) == 0;
            c.Healthy = c.ParentHardwareMatchesInstance && c.ChildProblemZero && c.ParentProblemZero && c.ParentStarted && c.ChildNoProblemFlag && c.ParentNoProblemFlag;
            c.Valid = c.RawPortIdentity && c.InstanceIdentity && c.FixedAlias && c.ParentIdentity && c.ParentHardwareAvailable && c.Healthy;
            c.FailureCode = !c.RawPortIdentity ? "raw_port_identity" : !c.InstanceIdentity ? "port_instance" : !c.FixedAlias ? "fixed_alias" :
                !c.ParentIdentity ? "parent_identity" : !c.ParentHardwareAvailable ? "parent_hardware_unavailable" : !c.Healthy ? "port_health" : "none";
            return c;
        }
        public static void ValidatePort(Port port, string target) {
            Need(GetIdentityChecks(port, target).RawPortIdentity, "Unexpected raw-port identity");
            Need(port.InstanceId != null && port.InstanceId.Length <= 1024 && port.InstanceId.StartsWith(Hardware + "\\", StringComparison.OrdinalIgnoreCase) && Regex.IsMatch(port.InstanceId.Substring(Hardware.Length + 1), @"\A[A-Za-z0-9_&-]{1,512}\z"), "Unexpected port instance");
            Need(String.Equals(port.PdoName, target, StringComparison.OrdinalIgnoreCase) && Regex.IsMatch(target, @"\A\\Device\\[A-Za-z0-9_]{1,128}\z"), "Fixed alias does not uniquely identify this PDO");
            Need(String.Equals(port.ParentService, "VirtioSerial", StringComparison.OrdinalIgnoreCase) && port.ParentId != null && Regex.IsMatch(port.ParentId, @"\APCI\\VEN_1AF4&DEV_(1003|1043)(?:&|\\)[A-Za-z0-9_&\\]+\z", RegexOptions.IgnoreCase), "Unexpected parent service/PCI identity");
            Need(port.ParentHardwareIds != null && port.ParentHardwareIds.Length > 0 && port.ParentHardwareIds.Length <= 64, "Parent hardware identity unavailable");
            string device = Regex.Match(port.ParentId, @"DEV_(1003|1043)", RegexOptions.IgnoreCase).Groups[1].Value;
            bool match = false; foreach (string id in port.ParentHardwareIds) if (id != null && id.Length <= 1024 && Regex.IsMatch(id, @"\APCI\\VEN_1AF4&DEV_" + device + @"(?:&|\z)", RegexOptions.IgnoreCase)) match = true;
            Need(match && port.Problem == 0 && port.ParentProblem == 0 && (port.ParentStatus & 8) != 0 && (port.ParentStatus & 0x400) == 0 && (port.Status & 0x400) == 0, "Port/controller is not healthy and started");
        }
        public static Port AcceptMatch(Port previous, Port candidate, string target) {
            Need(previous == null, "Multiple devnodes map to fixed guest channel");
            try { ValidatePort(candidate, target); }
            catch (InvalidDataException error) { throw new PortIdentityException(error.Message, GetIdentityChecks(candidate, target), error); }
            return candidate;
        }
        public static void ValidateConditional(Port port, string instance, string parent, byte[] expectedProperty, byte[] expectedLiveDacl, byte[] actualLiveDescriptor) {
            ValidatePort(port, port.PdoName);
            Need(String.Equals(port.InstanceId, instance, StringComparison.OrdinalIgnoreCase) && String.Equals(port.ParentId, parent, StringComparison.OrdinalIgnoreCase) && Descriptor.Equal(port.Property, expectedProperty), "Device/property changed since reviewed snapshot");
            if (expectedLiveDacl != null) Need(actualLiveDescriptor != null && Descriptor.Equal(Descriptor.Dacl(actualLiveDescriptor), expectedLiveDacl), "Actual PDO DACL changed since reviewed snapshot");
        }
        static Port Find(IntPtr set, out Info matched) {
            string target = Target(); Port found = null; matched = new Info(); Guid g = PortInterface;
            for (uint index = 0; index <= 256; index++) {
                Interface item = new Interface(); item.Size = (uint)Marshal.SizeOf(typeof(Interface));
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, index, ref item)) { if (Marshal.GetLastWin32Error() == 259) break; Last(); }
                Need(index < 256, "Too many VirtIO port interfaces"); Info info = new Info(); info.Size = (uint)Marshal.SizeOf(typeof(Info)); uint required;
                bool detail = SetupDiGetDeviceInterfaceDetailW(set, ref item, IntPtr.Zero, 0, out required, ref info);
                Need(!detail && Marshal.GetLastWin32Error() == 122 && info.DevInst != 0, "Cannot bind interface to devnode");
                string pdo = One(set, ref info, 14); if (!String.Equals(pdo, target, StringComparison.OrdinalIgnoreCase)) continue;
                uint parent; Need(CM_Get_Parent(out parent, info.DevInst, 0) == 0, "Parent unavailable");
                Info parentInfo = new Info(); parentInfo.Size = (uint)Marshal.SizeOf(typeof(Info)); string parentId = Instance(parent);
                if (!SetupDiOpenDeviceInfoW(set, parentId, IntPtr.Zero, 0, ref parentInfo)) Last();
                Port port = new Port(); port.InstanceId = Instance(info.DevInst); port.PdoName = pdo;
                port.HardwareIds = Strings(set, ref info, 1, 7); port.ParentId = parentId; port.ParentService = One(set, ref parentInfo, 4); port.ParentHardwareIds = Strings(set, ref parentInfo, 1, 7);
                Need(CM_Get_DevNode_Status(out port.Status, out port.Problem, info.DevInst, 0) == 0 && CM_Get_DevNode_Status(out port.ParentStatus, out port.ParentProblem, parent, 0) == 0, "Device state unavailable");
                // Collect every observation, then validate the complete exact
                // identity. Only unified ERROR_NOT_FOUND can prove absence;
                // legacy ERROR_INVALID_DATA alone cannot distinguish it.
                ReadClassGuid(set, ref info, port); ReadUnifiedClassGuid(set, ref info, port); ReadCapabilities(set, ref info, port);
                // Reject identity before even reading the security property.
                found = AcceptMatch(found, port, target); port.Property = Property(set, ref info); matched = info;
            }
            Need(found != null, "No present per-port PDO uniquely matches the fixed guest channel"); return found;
        }
        static IntPtr OpenSet() { Guid g = PortInterface; IntPtr set = SetupDiGetClassDevsW(ref g, null, IntPtr.Zero, 18); if (set == new IntPtr(-1)) Last(); return set; }
        static SafeFileHandle OpenReadControl() {
            SafeFileHandle handle = CreateFileW(OpenName, 0x20000, 0, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
            if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); } return handle;
        }
        static byte[] LiveDescriptor(SafeFileHandle handle, string expectedPdo) {
            uint size;
            if (!GetKernelObjectSecurity(handle, 4, null, 0, out size) && Marshal.GetLastWin32Error() != 122) Last();
            Need(size >= 20 && size <= 65536, "Live descriptor unavailable/bounded limit"); byte[] data = new byte[size];
            if (!GetKernelObjectSecurity(handle, 4, data, size, out size)) Last();
            Need(size == data.Length && String.Equals(Target(), expectedPdo, StringComparison.OrdinalIgnoreCase), "PDO changed during inspection"); Descriptor.Dacl(data); return data;
        }
        public static Port Inspect() {
            IntPtr set = OpenSet(); try {
                Info info; Port port = Find(set, out info);
                // READ_CONTROL only. No serial bytes/IOCTLs are sent. The raw
                // driver's exclusive create/close can still change open state.
                using (SafeFileHandle handle = OpenReadControl()) { port.LiveDaclDescriptor = LiveDescriptor(handle, port.PdoName); }
                return port;
            } finally { SetupDiDestroyDeviceInfoList(set); }
        }
        public static void WriteConditional(string instance, string parent, byte[] expected, byte[] next, byte[] expectedLiveDacl) {
            if (next != null) Descriptor.Dacl(next);
            IntPtr set = OpenSet(); SafeFileHandle liveHandle = null; try {
                Info info; Port port = Find(set, out info);
                byte[] actualLive = null;
                if (expectedLiveDacl != null) { liveHandle = OpenReadControl(); actualLive = LiveDescriptor(liveHandle, port.PdoName); }
                // The reviewed live DACL is checked even when no registry
                // override exists. Keep the same READ_CONTROL handle through
                // the write/readback, and reread the property just before set.
                port.Property = Property(set, ref info);
                Need(String.Equals(Target(), port.PdoName, StringComparison.OrdinalIgnoreCase), "Fixed alias changed before property write");
                ValidateConditional(port, instance, parent, expected, expectedLiveDacl, actualLive);
                PropertyKey key = Security;
                if (!SetupDiSetDevicePropertyW(set, ref info, ref key, next == null ? 0U : 0x13U, next, next == null ? 0U : (uint)next.Length, 0)) Last();
                Need(Descriptor.Equal(Property(set, ref info), next), "Device property write could not be verified; retain rollback receipt");
            } finally { if (liveHandle != null) liveHandle.Dispose(); SetupDiDestroyDeviceInfoList(set); }
        }
        public static string DesktopAccount(int session) {
            Need(session > 0, "Interactive desktop session required"); string[] parts = new string[2]; int[] kinds = new int[] {7, 5};
            for (int i = 0; i < 2; i++) { IntPtr data; uint size; if (!WTSQuerySessionInformationW(IntPtr.Zero, session, kinds[i], out data, out size)) Last(); try { Need(size >= 2 && size <= 2048 && size % 2 == 0, "Session identity unavailable"); parts[i] = Marshal.PtrToStringUni(data); } finally { WTSFreeMemory(data); } }
            Need(!String.IsNullOrEmpty(parts[1]), "No desktop user in this session"); return String.IsNullOrEmpty(parts[0]) ? parts[1] : parts[0] + "\\" + parts[1];
        }
    }
}

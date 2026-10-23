#!/usr/bin/env python3
"""Check EVENT-query feedback on the installed Windows hardware driver.

Uses the existing private guest bridge. Creates one temporary D3D11 device and
one query, then releases both. Does not install or configure anything. A pass
only establishes agreement after known completion, not correct early-completion
ordering, rendering compatibility, or general GPU reliability.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys


SOURCE = r'''
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public static class PerpendicularQueryFeedback {
    [DllImport("d3d11.dll", CallingConvention=CallingConvention.StdCall)]
    static extern int D3D11CreateDevice(IntPtr adapter, uint driver, IntPtr software,
        uint flags, IntPtr levels, uint count, uint sdk,
        out IntPtr device, out uint level, out IntPtr context);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int CreateQuery(IntPtr self, ref QueryDesc desc, out IntPtr query);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void End(IntPtr self, IntPtr query);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void Flush(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetData(IntPtr self, IntPtr query, out uint value, uint size, uint flags);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate uint Release(IntPtr self);
    [StructLayout(LayoutKind.Sequential)]
    struct QueryDesc { public uint Query; public uint MiscFlags; }
    public class Phase {
        public int index, completionHr, feedbackHr;
        public uint completionValue, feedbackValue;
        public double completionMilliseconds, feedbackMilliseconds;
        public bool consistent;
    }
    public class Report {
        public int deviceHr, queryHr;
        public uint featureLevel;
        public bool queryCreated, consistent;
        public Phase[] phases = new Phase[0];
    }
    // These are slots in the public ID3D11Device/ID3D11DeviceContext COM ABI.
    static T Method<T>(IntPtr self, int slot) where T : class {
        return Marshal.GetDelegateForFunctionPointer(
            Marshal.ReadIntPtr(Marshal.ReadIntPtr(self), slot * IntPtr.Size), typeof(T)) as T;
    }
    static int Poll(GetData get, IntPtr context, IntPtr query, uint flags,
                    int limit, out uint value, out double milliseconds) {
        var elapsed = Stopwatch.StartNew();
        int hr;
        do {
            hr = get(context, query, out value, 4, flags);
            if (hr != 1) break; // S_FALSE is the only retryable result.
            Thread.Sleep(1);
        } while (elapsed.ElapsedMilliseconds < limit);
        milliseconds = elapsed.Elapsed.TotalMilliseconds;
        return hr;
    }
    public static Report Run() {
        var report = new Report();
        IntPtr device = IntPtr.Zero, context = IntPtr.Zero, query = IntPtr.Zero;
        try {
            // HARDWARE only: an implicit WARP fallback must not qualify this pair.
            report.deviceHr = D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0x20,
                IntPtr.Zero, 0, 7, out device, out report.featureLevel, out context);
            if (report.deviceHr < 0) return report;
            var desc = new QueryDesc(); // D3D11_QUERY_EVENT: End-only.
            report.queryHr = Method<CreateQuery>(device, 24)(device, ref desc, out query);
            if (report.queryHr < 0) return report;
            report.queryCreated = true;
            var end = Method<End>(context, 28);
            var get = Method<GetData>(context, 29);
            var flush = Method<Flush>(context, 111);
            report.phases = new Phase[3]; // First End and two reuses; no stress loop.
            report.consistent = true;
            for (int i = 0; i < report.phases.Length; i++) {
                var phase = new Phase { index = i };
                report.phases[i] = phase;
                end(context, query);
                flush(context);
                phase.completionHr = Poll(get, context, query, 0, 500,
                    out phase.completionValue, out phase.completionMilliseconds);
                // Once GetData confirms completion, DONOTFLUSH must agree. This
                // avoids mistaking ordinary asynchronous GPU latency for a fault.
                phase.feedbackHr = Poll(get, context, query, 1, 100,
                    out phase.feedbackValue, out phase.feedbackMilliseconds);
                phase.consistent = phase.completionHr == 0 && phase.completionValue != 0
                    && phase.feedbackHr == 0 && phase.feedbackValue != 0;
                report.consistent &= phase.consistent;
            }
            return report;
        } finally {
            if (query != IntPtr.Zero) Method<Release>(query, 2)(query);
            if (context != IntPtr.Zero) Method<Release>(context, 2)(context);
            if (device != IntPtr.Zero) Method<Release>(device, 2)(device);
        }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', type=Path,
                        help='Private control socket of the VM being qualified')
    options = parser.parse_args()
    control = Path(__file__).resolve().with_name('control_guest.py')
    script = ("$ErrorActionPreference='Stop'; Add-Type -TypeDefinition @'\n"
              + SOURCE + "\n'@; [PerpendicularQueryFeedback]::Run() | ConvertTo-Json -Depth 6")
    target = ['--socket', str(options.socket)] if options.socket else []
    result = subprocess.run([
        sys.executable, str(control), *target, 'execute', '--timeout-seconds', '20',
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        '--', '-NoProfile', '-Command', script,
    ], capture_output=True, text=True, timeout=30)
    reply = json.loads(result.stdout)
    execution = reply.get('result', {})
    if (result.returncode or not reply.get('ok') or execution.get('exitCode') != 0
            or execution.get('timedOut') or execution.get('outputTruncated')):
        raise RuntimeError('Guest probe did not finish: ' + str(
            execution.get('stderr') or reply.get('error') or result.stderr))
    report = json.loads(execution['stdout'])
    report['scope'] = 'EVENT GetData/DONOTFLUSH agreement after reported completion'
    print(json.dumps(report, indent=2))
    return 0 if (report.get('queryCreated') and report.get('consistent')
                 and len(report.get('phases', [])) == 3) else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)

#!/usr/bin/env python3
"""Check that the installed Windows GPU driver honors D3D11 fence waits.

Runs once through the private guest bridge. No driver or service installation,
configuration changes, persistent GPU load, or user-window input. Exit 1 means
an ordering violation; exit 2 means the check could not finish. A pass is scoped
to these temporary devices and commands, not general rendering reliability.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', type=Path, help='Private control socket of the target VM')
    options = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    source = (repo / 'tests/WindowsFenceWaitChecks.cs').read_text()
    script = ("$ErrorActionPreference='Stop'; Add-Type -TypeDefinition @'\n" + source
              + "\n'@; [PerpendicularFenceWait]::Run() | ConvertTo-Json -Depth 6")
    target = ['--socket', str(options.socket)] if options.socket else []
    result = subprocess.run([
        sys.executable, str(repo / 'scripts/control_guest.py'), *target,
        'execute', '--timeout-seconds', '20',
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        '--', '-NoProfile', '-Command', script,
    ], capture_output=True, text=True, timeout=30)
    reply = json.loads(result.stdout)
    execution = reply.get('result', {})
    if (result.returncode or not reply.get('ok') or execution.get('exitCode') != 0
            or execution.get('timedOut') or execution.get('outputTruncated')):
        raise RuntimeError('Fence check did not finish: ' + str(
            execution.get('stderr') or reply.get('error') or result.stderr))
    report = json.loads(execution['stdout'])
    if (not report.get('driverModules') or report.get('adapter', {}).get('vendor') != 0x1af4
            or report.get('adapter', {}).get('flags', 2) & 2):
        print(json.dumps(report, indent=2))
        raise RuntimeError('Could not qualify the active Neptune hardware driver in the probe process.')
    report['consistent'] = (
        report.get('initialFenceValue') == 0
        and report.get('waitHr') == 0
        and report.get('beforeSignalQueryHr') == 1
        and report.get('beforeSignalFenceValue') == 0
        and report.get('mapHr') == 0
        and report.get('fenceAtMapReturn', 0) >= 1
        and report.get('pixel') == 'ff336699' and report.get('uniform') is True
        and report.get('signalHr') == 0
        and report.get('afterSignalQueryHr') == 0
        and report.get('afterSignalQueryValue') == 1
        and report.get('afterSignalFenceValue', 0) >= 1
        and report.get('prematureCompletion') is False
        and report.get('gpuWriteBeforeGate') is False)
    print(json.dumps(report, indent=2))
    return 0 if report['consistent'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)

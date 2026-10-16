# Isolated Windows 3D driver trial preparation

The actual Windows 3D path remains unverified. This directory prepares the
unchanged Triton v0.3 package reviewed with REA in
[the package report](../../docs/GRAPHICS_DRIVER_PACKAGE.md), plus a **read-only**
Windows baseline. The driver binaries, guest reports, VM state and generated
media stay outside Git. This is not the automatic Guest Tools installer.

```sh
python3 experimental/windows-3d-trial/prepare-media.py \
  /tmp/perpendicular-viogpu3d-release.zip .tools/windows-3d-media
```

Preparation checks the archive digest, exact eleven-member inventory and every
payload digest before creating a fresh output directory. It neither starts a
VM nor installs anything. Copy the separately built Windows hardware probe to
the private staging directory if needed, then create read-only optical media.
Attach only to the independently copied, stopped **3D Trial** VM.

In that guest, run `Read-Baseline.ps1` from the disc using Windows PowerShell.
An elevated session allows more security observations, but the script itself
does not elevate or mutate security state. The default report is a fresh JSON
file in the current user's Downloads folder. Missing access is recorded as
unknown. It reads OS, Secure Boot, TPM, Device Guard/HVCI, current BCD, display
driver and the two affected registry values. It verifies all package hashes
and records Windows Authenticode results for the signed payloads and catalog.
Those results **do not prove** kernel policy acceptance, catalog membership or
successful driver loading; actual installation and Code Integrity evidence
must be recorded separately.

The original signed INF starts the `vgpusrv` service and writes global
`TdrDebugMode=1` / `EnablePreemption=0` inside Windows. Do not edit its signed
contents or import certificates/disable Secure Boot, HVCI or signing policy to
force acceptance. The independent offline source VM is the rollback boundary;
uninstalling the display device alone is not a rollback of all INF effects.
Never publish baseline reports, copied TPM/EFI state or the Windows disk.

Driver-load success is only the next gate. Completion still requires a hardware
D3D11 scene, matching Mac GPU work and actual pixels, then desktop/browser
compatibility, resize, restart/recovery and measured sustained latency.

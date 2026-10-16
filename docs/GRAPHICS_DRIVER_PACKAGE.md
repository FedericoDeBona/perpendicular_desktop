# Triton v0.3 Windows driver package review

Read-only review on 2026-10-15 for a future disposable Windows 11 ARM clone.
**Not approved as a transparent driver-only change:** the supplied INF also
requests global graphics scheduler/recovery settings, notably
`TdrDebugMode=1` (ignore timeouts). Nothing was installed or loaded, and no VM,
app, stable runtime, certificate store or security setting was changed.

## Windows preinstallation checkpoint — 2026-10-16

The user subsequently authorized the concrete 3D trial, including the original
INF's service/recovery effects and a per-process PowerShell execution-policy
exception for our diagnostics. They requested that no further VM copies be
made. The already prepared **3D Trial** booted normally with the installed 2D
runtime; no 3D driver has yet been installed at this checkpoint.

Actual elevated Windows PowerShell observations on Windows 11 Pro ARM64
10.0.26300: all eleven full-file hashes match the reviewed manifest, and
Windows `Get-AuthenticodeSignature` reports **Valid** for the catalog and all
eight signed PE payloads. This is stronger Windows signing evidence than the
earlier Mac-only chain check below, but is still not kernel-mode catalog policy
acceptance or driver-load proof. Secure Boot reports **True**. Both global INF
values are absent before installation. Device Guard reports VBS status 0 and
security services running/configured `[0]`; these were observed, not disabled
for the trial. The current BCD listing contains no displayed test-signing or
integrity-disable option. `Get-Tpm` fails with **0x80284001**, consistent with
the earlier guest baseline; do not call TPM readiness verified from that error.

The full baseline is retained privately inside the guest. Host observation
receipt: `.tools/windows-3d-preinstall-observations.json`. The reproducible
[read-only baseline/media preparation](../experimental/windows-3d-trial/README.md)
retains failed observations as unknown and never installs a package. Installing
the unchanged package under Windows enforcement, identifying the loaded driver
and proving actual hardware D3D11 rendering remain the next gates.

## Exact release identity

The supplied file `/tmp/perpendicular-viogpu3d-release.zip` is 2,117,369 bytes.
Its full-file SHA-256 matches the GitHub asset's currently advertised digest:

```text
af976d1fc6cbd1c8462ba06a45f860ae1638d9a6a007e2bfe95bb9b235251c5d
```

[Release v0.3](https://github.com/osy/kvm-guest-drivers-windows/releases/tag/v0.3),
[exact asset](https://github.com/osy/kvm-guest-drivers-windows/releases/download/v0.3/viogpu3d-arm64x-signed.zip).
GitHub release ID `380253183`, asset ID `539094747`, asset name
`viogpu3d-arm64x-signed.zip`; asset uploaded 2026-09-01 06:19:00–01 UTC.
The release is marked prerelease, not draft, and `immutable=false`; publication
was 2026-09-01 06:19:04 UTC. Keep the digest as the identity, not only the mutable
tag/asset URL.

The tag currently points directly to commit
`769e75cd645fc48f4aaae716ca8a74795fe5e241`, dated 2026-08-31 02:32:27 UTC.
GitHub reports that commit's signature status as unsigned. This is the
**release's source reference**, not a reproducible-build proof that each binary
was produced from it.

REA archive inventory and safe extraction found eleven regular members, no
inventory integrity contradictions, and no nested archive. All paths below
are relative to `drivers/viogpu3d/`.

| Member | Bytes | Static format/role | Full-file SHA-256 |
| --- | ---: | --- | --- |
| neptune_umd.dll | 34,976 | PE32+, Machine AA64, CHPE v2, dual-forwarder candidate | bb181fe8c67c18b597ca9a34078195a6d506e282e72c18ed9da49c151c19257f |
| neptune_umd_arm64.dll | 1,375,392 | PE32+, Machine AA64, native ARM64 UMD | 8fbb509b3b5e2a06b67392fe6b711832227e1ab802e096bf7d723ace6c66b437 |
| neptune_umd_ec.dll | 1,421,984 | PE32+, Machine 8664, CHPE v2; ARM64EC candidate | 1171ecf0c7725425589f997202cfcc7cbfb7338886b87e71f34b4335e9ced941 |
| neptune_umd_x86.dll | 1,196,192 | PE32, Machine 014C, x86 UMD | 7547e89f6a8dfae5f9c4f078b32328901cc09047adaafdbbef00191b48673d90 |
| vgpusrv.exe | 206,496 | PE32+, Machine AA64, resolution service executable | abbab0a9cbfe79eecbe18af302a5ca78283a5b07337034fde39bed1306def876 |
| viogpu3d.cat | 15,777 | PKCS#7 driver catalog | 19d04aa184b1f9ee63c41bf514005cc1460d9ac21edbbd2dd974283e6d0f1643 |
| viogpu3d.inf | 4,311 | ARM64 installation manifest | e66a4afc07d4232b2dfb4a1788801c8e4cbf478a36d5c32d47eda2c628972423 |
| viogpu3d.sys | 226,464 | PE32+, Machine AA64, native kernel subsystem | 25d2a877fdf23394b927d924e0315375f1da9db29c00bfb550048b1811d5a332 |
| viogpuap.exe | 205,472 | PE32+, Machine AA64, resolution helper executable | 7160026ba8bf717580818f4fffc10c816b93fad6b85959668ef1f2a34f0c4853 |
| virtio_icd.json | 210 | Vulkan ICD manifest | 7a215445f88230a5d3d7b44f007bbffdc79f0829d54d4ae72984686faed1ce14 |
| vulkan_virtio.dll | 1,711,776 | PE32+, Machine AA64, Vulkan ICD exports | 424a0bfd7309df750ed2415c7c2fab48f96f91bd0b4a5fcfa34f9e567f8976dd |

The ARM64X/ARM64EC roles are supported by the release name, CHPE metadata and
forwarder observations, not by pretending that filename suffixes identify CPU
code. Final ARM64EC PE images can carry Machine 8664; A641 is an intermediate
object identifier, not the expected final PE header.
[Microsoft's ARM64EC identification rules](https://learn.microsoft.com/en-us/windows/arm/arm64ec),
[ARM64X forwarder construction](https://learn.microsoft.com/en-us/windows/arm/arm64x-build).

The ordinary ARM64 view of `neptune_umd.dll` exports exactly
`OpenAdapter10_2 → neptune_umd_arm64.OpenAdapter10_2` and
`OpenAdapter12 → neptune_umd_arm64.OpenAdapter12`. Its bytes also contain the
two corresponding `neptune_umd_ec` forwarders, a nonzero CHPE metadata pointer
(version 2), and an `.a64xrm` section. The EC DLL has nonzero CHPE v2 metadata
and a CodeView PDB path containing `mesa-build-arm64ec`. The three substantive
UMDs export those two adapter entry points. **The Windows loader's alternate
view, DLL selection and successful adapter creation have not been observed.**

The SYS RT_VERSION fixed version is `100.6.101.58000`, matching the INF.
REA found no resource entries in the four UMDs or Vulkan DLL, so the SYS version
must not be presented as an independently recovered DLL version. Vulkan exports
three ICD entry points, and its manifest claims API 1.4.340. These are packaging
facts, not evidence that Vulkan or D3D12 works with the experimental D3D11 host.

## INF target and requested effects

These are observed declarations in the exact packaged INF, not installation
outcomes. Its source template at the release commit is
[viogpu3d.inx](https://github.com/osy/kvm-guest-drivers-windows/blob/769e75cd645fc48f4aaae716ca8a74795fe5e241/viogpu/viogpu3d/viogpu3d.inx).

| Field | Packaged value |
| --- | --- |
| Class / GUID | Display / {4d36e968-e325-11ce-bfc1-08002be10318} |
| Provider string | Red Hat, Inc. |
| Date / driver version | 08/30/2026 / 100.6.101.58000 |
| Catalog / lockdown | viogpu3d.cat / PnpLockdown=1 |
| Models decoration | RHEL.NTARM64.10.0...16299 |
| Hardware ID | PCI\VEN_1AF4&DEV_1050&SUBSYS_11001AF4&REV_01 |
| Compatible ID | PCI\VEN_1AF4&DEV_1050 |
| Destination | DIRID 13 / DriverStore |
| Device description | Red Hat VirtIO GPU 3D controller |
| Include / rank | msdv.inf / FeatureScore F9 |

The decoration declares ARM64, NT 10.0 and minimum build 16299; it is not a
claim that all Windows builds have been qualified. Windows 11 also reports NT
10.0, and its build must be considered separately.
[Microsoft TargetOSVersion semantics](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/inf-manufacturer-section).

Two services are requested:

* `VioGpu3D`: associated function driver (AddService flag 0x2),
  kernel driver type 1, demand start 3, error control 0,
  `%13%\viogpu3d.sys`.
* `vgpusrv`: Win32 own-process type 0x10, automatic start 2, error control 1,
  `%13%\vgpusrv.exe`, and AddService flag 0x800 requests starting it after
  installation. The INF comments describe LocalSystem and brokering
  `viogpuap.exe` into the interactive session; no explicit account override is
  present. Actual service account/process creation is unobserved.
  [Microsoft AddService semantics](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/inf-addservice-directive).

Device settings request HWCursor=0, FlexResolution=1, UsePhysicalMemory=0,
native UMD registration through `neptune_umd.dll`, WOW UMD registration through
`neptune_umd_x86.dll`, and a Vulkan manifest registration. MSI is explicitly
disabled with MSISupported=0 (MessageNumberLimit=4 is also declared).
`z.dll` appears in SourceDisksFiles but its CopyFiles entry is commented out;
its absence from the archive is not evidence that an active copied file is
missing.

**Material trial gate:** two AddReg directives address HKLM globally, beyond the
display device's HKR settings:

```text
SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Scheduler : EnablePreemption = DWORD 0
SYSTEM\CurrentControlSet\Control\GraphicsDrivers           : TdrDebugMode = DWORD 1
```

Microsoft defines TdrDebugMode 1 as ignoring timeouts and reserves these keys
for targeted driver development/debugging. This would change graphics recovery
behaviour in the clone; it is not implied by the words “signed driver.”
The precise effect of EnablePreemption on the intended Windows build remains
unmeasured; its explicit global write is established.
[Microsoft TDR registry documentation](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/tdr-registry-keys).

No test-signing toggle, Secure Boot change, certificate import or BCD command
appears in the supplied INF. That bounded observation does not prove that
Windows will accept or run this package. Do not edit the signed INF to remove
its settings and then continue calling it this verified release package: its
catalog binding would change. Before installation, either obtain an upstream
signed package with the intended settings or explicitly review a disposable
clone trial including these effects and rollback. This report does not
authorize that installation.

## Embedded signing and catalog evidence

All eight PEs contain a revision-0x0200 WIN_CERTIFICATE with PKCS#7 data. A
nested signature is also present: osslsigncode identifies primary Turing
Software and nested Microsoft signatures in **each of the eight** images.
The catalog's signer metadata identifies Microsoft Windows Hardware
Compatibility Publisher.

| Signing metadata | Observed identity |
| --- | --- |
| Primary leaf | TURING SOFTWARE LLC |
| Primary issuer | TrustID EV Code Signing CA 4, IdenTrust |
| Primary serial | 40019D2B53FB05365730694B40E57DF0 |
| Primary leaf validity | 2026-03-26 18:06:57 to 2027-03-27 18:05:57 UTC |
| Primary leaf certificate SHA-256 | b52266ca3bdb592f007924edf8024454675ff60540a6376bb777386afff7c210 |
| Nested / CAT leaf | Microsoft Windows Hardware Compatibility Publisher |
| Nested / CAT issuer | Microsoft Windows Third Party Component CA 2014 |
| Nested / CAT serial | 33000000849686AEDFB4B66376000000000084 |
| Nested / CAT leaf validity | 2026-05-13 18:17:34 to 2027-05-11 18:17:34 UTC |
| Nested / CAT leaf certificate SHA-256 | 735521239659d359cc4aaef67a4432d36ca585b4db26e93593905a77f5b3efa4 |
| Microsoft intermediate certificate SHA-256 | a0f259a07039908eeb943e223fdf996e5e1e131d9aa6a602ff4672f7b9298aee |

For the SYS, signing metadata records a DigiCert timestamp at
2026-08-31 05:27:22 UTC and a nested Microsoft timestamp at 05:37:42 UTC.
Timestamp authenticity/revocation was not verified.

Using existing osslsigncode 2.14 (OpenSSL 4.0.3) with
`-ignore-cdp -ignore-crl -ignore-timestamp`, all sixteen embedded signature
views report equal stored and calculated SHA-256 Authenticode image digests.
This is a static digest consistency observation. The catalog records match the
calculated Authenticode digests for all eight PEs and full-file SHA-256 for the
INF and JSON: ten matching payload entries. Authenticode image digests differ
from the full-file hashes in the table because the signature/checksum regions
are handled separately.

**Full verification returned exit 1**, with missing local issuer certificates
in this Mac's CA chain. No roots were downloaded, imported or trusted to turn
that result into a pass. Timestamp and revocation checks were deliberately
disabled to keep this inspection offline. “Number of verified signatures” in
the tool's diagnostic output is not treated as success when its final
verification result fails. Generic INF/JSON files are not parsed as signed
executables by osslsigncode; their catalog entry digests were compared directly.

No Windows WinVerifyTrust/SignTool policy validation, attestation-vs-HLK
qualification, HVCI compatibility, DriverStore acceptance, loaded driver,
service execution or successful UMD loading is established. Certificate names
alone establish none of those facts.
[Windows release-signature verification](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/signtool).

## Build provenance: what is and is not connected

* Proven: current release asset digest → the supplied ZIP → the exact eleven
  member hashes above; current v0.3 tag → KMD source commit 769e75cd….
* Observed: the SYS/helper PDB paths include
  `kvm-guest-drivers-windows\...\objfre_win11_arm64\arm64`; the EC UMD path
  includes `build-mesa\mesa-build-arm64ec\...\neptune_umd.pdb`.
  These are embedded strings, not access to the build machine or PDBs.
* The tagged KMD project requests WindowsKernelModeDriver10.0 and
  `$(LatestTargetPlatformVersion)`; it does not pin an exact installed
  SDK/compiler version.
  [Tagged project](https://github.com/osy/kvm-guest-drivers-windows/blob/769e75cd645fc48f4aaae716ca8a74795fe5e241/viogpu/viogpu3d/viogpu3d.vcxproj).
* The tagged workflow directory contains only clang-format and issue labelling.
  Its Windows driver/ARM64X signing and release assembly are not described by
  those workflows. The Actions API currently returns zero retained runs for
  this exact commit; that does not prove no private, manual or expired build ran.
  [Tagged workflows](https://github.com/osy/kvm-guest-drivers-windows/tree/769e75cd645fc48f4aaae716ca8a74795fe5e241/.github/workflows).
* The generic tagged `build/signAll.bat` signs SYS/CAT files using
  `VirtIOTestCert.pfx`. It does not describe the Microsoft-signed ARM64X asset's
  build/signing pipeline and is not an asset provenance attestation. No test
  certificate or certificate installer is among the eleven released members.
* No exact UMD source revision was recovered from a version resource, PDB
  identity-to-source mapping or bounded build-string search. The bundled Vulkan
  DLL contains `Mesa 26.1.0-devel`, which is not a commit identifier.
* No release lockfile, reproducible-build match or signed build attestation
  tying this asset to exact Mesa/Neptune UMD, host QEMU/renderer, DXMT, ANGLE
  revisions and build inputs was established. The host research pin
  `bf536bba65454900d782fa7417bc95c1608d7483` must remain a research pin, not be
  relabelled as the source of these signed UMD binaries.

## Evidence records and repeatability

REA inventory inspection parent:
`ev_d9d1cb1c61df651eed4814676e19c0a375307de7585b288bb712c07c86acc6bb`;
artifact manifest:
`agm_d1e462f90fe7eb35150065b7f8d5a25f73c85b7f31c3cb91873e815b00feb7c7`;
safe extraction:
`ev_1c79435c0a3ddf26c707b217f57f1a6307583fce70696a551d748eedb3d3f46a`.

REA PE resource inventories:

| Member | Evidence ID |
| --- | --- |
| neptune_umd.dll | ev_2b44e91483649b0b3b0d0007fe65c950a14b27c860b0de55d7b01e0008efae76 |
| neptune_umd_arm64.dll | ev_6dd78d90ef668f628cc714bfc7aa6b5a34b5890c48c23ce06a4a47f613440ac3 |
| neptune_umd_ec.dll | ev_c34b687b5e5422f06eaa4d302f584a19238510d0a55ca9b13f9822802f626761 |
| neptune_umd_x86.dll | ev_0ae23bf558745d38895bbb68a89204ee16547f8b4d2bb59e4c51c2a11b851e71 |
| vgpusrv.exe | ev_e08bf38fcd450cc7637c43dc82962d4794c4afb01803c56657650f5be135a303 |
| viogpu3d.sys | ev_be4b9220d173bb64de2bc0b7107d2ff7d467389298fb4a0bf0f86228434d2a19 |
| viogpuap.exe | ev_0f63d3d39700244c633a4aa02004ef735282cee97dd6835e14984ad60307ba57 |
| vulkan_virtio.dll | ev_007720372bc53a637e5075a08f82a669d64320c5e47667faab56d203a27900a9 |

Complete local evidence is under the ignored private directory
`.tools/graphics-experiment/research/driver-release-v0.3/`:
`rea-evidence.json`, `package-inspection.json`, `catalog-membership.json`,
`certificate-metadata.json`, `signatures-summary.json`, exact release/tag/
workflow API responses, fetched tagged source templates, and literal offline
verification output. The DER/PE parsing was execution-free; no shipped member
was run. REA resource analysis records resource locations/hashes but leaves
opaque payload semantics to the separately recorded byte parser.

A repeatable offline signing inspection, using existing tools, is:

```sh
osslsigncode verify -ignore-cdp -ignore-crl -ignore-timestamp -verbose -in viogpu3d.sys
osslsigncode verify -ignore-cdp -ignore-crl -ignore-timestamp -catalog viogpu3d.cat -in viogpu3d.sys
```

Preserve their actual nonzero status and policy limitations; these are not
instructions to install anything.

## Checklist for a later, separately reviewed clone trial

- [x] ZIP identity equals the exact advertised ARM64X asset digest.
- [x] All eleven member identities and eight PE machine/resource inventories recorded.
- [x] Embedded primary/nested signer metadata and ten catalog digest matches recorded.
- [x] INF hardware IDs, architecture/minimum build, services and global registry effects reviewed.
- [ ] Decide the explicit policy for the supplied INF's global TDR/scheduler changes;
      preserve the original package, do not silently edit/re-sign or weaken Windows policy.
- [ ] Prepare an independently recoverable offline clone with its own disk, NVRAM and
      TPM state. Preserve existing hardware/PCI addresses and security baselines.
- [ ] In that clone, record actual OS build, Secure Boot, HVCI/Device Guard, BCD signing
      policy and existing values of both global graphics registry keys.
- [ ] Verify catalog and kernel policy on the actual Windows build with SignTool
      (including `/kp /c` for INF/SYS and the relevant OS `/o` target), and verify
      UMD package/embedded signatures. Preserve failures; no certificate import,
      test-signing or integrity-policy bypass.
- [ ] Only after the installation effects are reviewed, install the unchanged
      package in the clone and record Device Manager/SetupAPI/CodeIntegrity results,
      the selected INF/version/SYS, actual service account, and loaded UMD paths.
      Qualify the supplied resolution service alongside Perpendicular's existing
      resize channel; compatible coexistence has not been established.
- [ ] Run a native ARM64, single-device D3D11 **hardware** adapter scene with the
      intended exclusive single-ring/one-fence scope. Observe actual resource/blob/
      writer/export/import/fence events; an adapter name or dxdiag alone is insufficient.
- [ ] Prove scanout pixels, device-loss/reset cleanup, frame ordering and exact Present
      association; DWM imports or additional fences must remain unsupported until qualified.
- [ ] Keep resize and fluidity measurements separate from driver-load success. Record
      sustained timing under controlled conditions; the O0 host fixture is not an FPS claim.

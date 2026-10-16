# Corrected loader precedence and paused HVF 4 KB mapping gate

This is a separate checkpoint after the frozen native backend test. No existing
source, candidate executable, library, app, helper or Windows VM was changed.
It does not establish which backend any earlier Windows trial actually loaded.

The loader can select an older same-basename dylib through `DYLD_LIBRARY_PATH`
even when the application passed a new absolute path to `dlopen`. Therefore a
logged requested path is insufficient. The scoped order tested here is:

1. `.tools/graphics-wire1/prefix/lib`
2. `.tools/graphics-wire1-backend/prefix/lib`
3. `.tools/graphics-experiment/prefix/lib`
4. `.tools/graphics-experiment/prefix/ANGLE.xcarchive/Products/usr/local/lib`

`DYLD_FALLBACK_LIBRARY_PATH` uses the same order. `RENDER_SERVER_EXEC_PATH`
selects the matching Wire 1 server. All three `NPT_*_LIBRARY_PATH` variables
select the new backend explicitly. This does not enable D3D12 in that backend.
Actual dyld records, rather than the requested-path messages, qualify loading.

## Successful separate fixtures

Run from the repository root; each refuses to overwrite its output directory:

```sh
.tools/build-venv/bin/python experimental/neptune-wire1-backend/loader-check.py
.tools/build-venv/bin/python experimental/neptune-wire1-backend/ipa-check.py
.tools/build-venv/bin/python experimental/neptune-wire1-backend/ipa-check.py --control-default
```

These reuse the frozen `experimental/neptune-wire1/probe.py` in memory, changing
only output destination, selected dependency paths and the explicit fixture
operations documented in their sources. The original fixture/receipt stays
unchanged. They use original QEMU `8d4d5ec3…`, Cocoa ES and a private diskless
128 MiB machine paused under HVF. No guest CPU executes, no Windows/VM disk is
opened and no Neptune COM or SUBMIT_3D packet is sent.

| Output under `.tools/graphics-wire1-backend/` | Result |
| --- | --- |
| `loader-check/result.json` | Exit 0; actual Wire 1 renderer, matching server and new backend loaded; old renderer/backend absent; capset 7 embeds wire 1, size 60. |
| `ipa-check-4k-maponly/result.json` | Exit 0 with `-accel hvf,ipa-granule-size=4096`; three HOST_VISIBLE mappings accepted without alignment warnings. |
| `ipa-check-default-maponly/result.json` | Exit 0 for the expected negative control; the same mappings produce exactly three HVF alignment-rejection warnings at default 16 KB. |

The mapping fixture sends a normal VirtIO CTX_CREATE for capset 7, then
RESOURCE_CREATE_BLOB with HOST3D memory, USE_MAPPABLE, zero entries and blob_id
0. The pinned renderer handles this as anonymous shared fd/mmap allocation,
without D3D/COM commands. It maps:

- 4 KB at aperture offset `0x4001000`;
- `0x201000` bytes at offset 0;
- a separate 1 MiB backing at the adjacent offset `0x201000`.

Qtest writes and reads fixed values at each region's ends and on both sides of
the adjacent boundary; values stay distinct. Backings are not rounded or
combined. QMP records the memory tree and confirms the CPU remains paused.
QMP quit returns 0, after which the fixture cleans up only its owned process
group and temporary sockets. Dyld evidence in the 4 KB case includes both the
QEMU process and the matching server worker loading backend `4fade330…`.

The negative control reports rejection for guest ranges
`0x24001000–0x24002000`, `0x20000000–0x20201000` and
`0x20201000–0x20301000`, each “not aligned to page size (0x4000)”. The explicit
4 KB case reports none. Qtest accesses QEMU's memory view and can still succeed
when HVF rejects a mapping, so these reads alone are **not** proof of guest CPU
access. The causal result is removal of the source's real HVF alignment
rejection; actual Windows CPU execution and crash resolution remain a later
operator test. No assertion is removed and no public/private API code is
patched by these fixtures.

## Retained failed first teardown attempt

`ipa-check-4k/qemu.log` preserves the first attempted case. Its 4 KB create/map
and two qtest endpoint checks completed, but guest RESOURCE_UNREF (`0x102`)
after RESOURCE_UNMAP_BLOB (`0x209`) did not complete within ten seconds while
the machine was paused. The host fixture raised a timeout and cleaned up its
owned group. This is a **failed teardown probe**, not part of the successful
mapping gate and not evidence of a resolved resource-release path.

The final mapping-only cases keep their three small regions alive until QMP
quit, rather than claim guest UNREF succeeds. They do not test runtime unmap,
remap or sustained resource churn. Worker logs also retain missing optional
`D3D12CreateDevice`, `dxmt_shared_handle_close` and
`dxmt_open_existing_heap_from_fd` exports; these are not hidden or qualified by
the mapping result.

All receipts retain exact commands, paths, library evidence, fixed metadata and
protected artifact hashes. `loader-checkpoint.json` binds these additional
scripts/receipts/logs without modifying the earlier `checkpoint.json`.

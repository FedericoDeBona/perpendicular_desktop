# Local Windows WebGL2 triangle probe

Original static Apache-2.0 diagnostic, prepared on 2026-10-16. No dependency,
installation, external resource, automatic upload or browser/VM invocation is
part of this directory. A native Windows Edge run and its scope are recorded
below; host syntax checks alone are not GPU evidence.

Serve this directory through the operator's local HTTP test server and open
`index.html` in the actual Windows browser. Keep the tab visible and click
**Start once**. It requests WebGL2 exactly once, with no WebGL1/Canvas2D retry.
The fixed drawing buffer is 800×450; CSS may scale its presentation without
changing that workload. A vertex buffer, original GLSL ES 3.00 vertex/fragment
shaders and a changing rotation uniform draw one coloured triangle on black.
The report records shader compilation/linking and bounded compiler logs,
context loss, periodic `getError` checks, and the actual standard renderer,
vendor, version and shading-language strings. Optional unmasked strings are
reported only if `WEBGL_debug_renderer_info` is available. A requested WebGL2
context, renderer label or successful shader does not classify hardware versus
software or prove the host Metal path; browser-internal fallback is not ruled
out. Browser policies/settings are never changed by this page.

There are two seconds of animation warm-up, followed by a 30-second callback
measurement budget. Initialization/shader compilation is outside warm-up and
measurement. rAF timestamp differences yield median, nearest-rank p95,
minimum, maximum and a count of gaps strictly over 50 ms. UI updates occur at
most four times per second; `getError` is checked every 60 draws and at the end.
That instrumentation remains part of the callback workload. The terminal rAF
callback contributes its interval but submits no measured draw, so
`measured_raf_callbacks` can exceed `draws.measured`. Intervals are capped at
20,000. No nominal or physical FPS, GPU duration or input-latency result is
calculated. Scheduling, browser/compositor load, guest/host work and throttling
can all affect these intervals.

Any `visibilitychange` during the run invalidates it, even if the tab becomes
visible again. Context loss ends the run without a resume/retry. Timer guards
fail a warm-up or measurement that is not serviced within its budget plus one
second. Browser callbacks/timers cannot interrupt a stuck main thread, shader
compiler, GPU or driver: this is not a hard watchdog. The report retains actual
elapsed values and partial counters for failures, never substitutes a nominal
result. Reload for another explicit run.

After timing ends, one additional draw and **one centre-pixel readback** run
outside the timing samples. The triangle contains its centre at every angle;
any nonzero RGB channel against the black clear is the bounded verification.
It does not verify the whole image, every earlier draw, screen presentation,
physical frame rate or sustained stability. `valid=true` requires successful
completion, no visibility/context invalidation and this non-black pixel.
Visible triangle output still needs independent observation.

**Download JSON** saves `windows-browser-webgl2.json`. **Send to local test
server** is a separate optional click and POSTs precisely `./result`, with a
five-second abort timer, no credentials/referrer, no redirects and no response
body processing. The server must provide that same-origin route (for a page at
`/probe/index.html`, it is `/probe/result`); a static-only server can still serve
the test and download. No server is installed or started here. Treat received
JSON as untrusted diagnostic data. Payloads contain no user agent, account,
page URL, paths, cookies, network address or persistent identifier; the actual
renderer strings and bounded diagnostic logs are included intentionally.

Host checks, without browser/GPU execution:

```sh
node --check experimental/windows-browser-probe/probe.js
git diff --check -- experimental/windows-browser-probe
```

## Actual Windows Edge run

On 2026-10-16 the existing Windows ARM64 3D trial ran these exact page/shader
sources in Edge155.0.4283.45. Both shaders compiled and linked, and the real
console showed the rotating RGB triangle. After120 warm-up draws, the measured
30,004.3ms interval recorded1,762 draw calls. rAF spacing was median16.1ms,
p9531.7ms, minimum1.3ms, maximum34.5ms, with no gaps over50ms. The run stayed
visible, reported no context loss or GL errors, and its post-timing centre
pixel was RGBA[97,78,80,255]. status=completed and valid=true.

The unmasked renderer names ANGLE/VirtIO1AF4:1050/Direct3D11. The browser's
separate internal GPU report selects that same adapter. The probe itself
still leaves hardware_classification=not_determined and
host_acceleration_verified=false. This is a tiny fixed WebGL2 workload, one
run under the diagnostic optimization0 runtime and1280×1024 Windows desktop;
it does not establish physical FPS, input latency, general app performance,
video acceleration, WebGPU, Parallels parity or long-run stability.

Raw private report `.tools/windows-browser-webgl2-ipa4k1.json`, SHA-256
`139703738f77a6cc8c0c2810222b439b04d21d56d141d1931d3b7ca3e206d3d2`.
Page SHA-256 `1fe3bc4612eed5a3809cfd596fc803539d3a9836a2ec3020f419c338941b89fa`;
JavaScript `1cafde3d54ed396d3d3ff27129797648b6a4270da4c5440befcd42a936d04f57`;
stylesheet `ccc6f3b899f4a271dfa38af1526acbd8b68883a85175687dbf7dc4c7b6ba2e12`.
See the [configuration and remaining gaps](../../docs/NEPTUNE_WINDOWS_3D_CHECKPOINT.md).

Contracts: [WebGL2 specification](https://registry.khronos.org/webgl/specs/2.0.0/),
[animation callbacks](https://html.spec.whatwg.org/multipage/imagebitmap-and-animations.html#animation-frames),
[renderer extension](https://registry.khronos.org/webgl/extensions/WEBGL_debug_renderer_info/).
All four files in this directory are original, licensed under Apache-2.0 as in the
repository root. No third-party shader, library or asset is copied here.

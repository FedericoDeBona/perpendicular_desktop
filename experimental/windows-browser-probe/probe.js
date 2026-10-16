// SPDX-License-Identifier: Apache-2.0
// Original, explicit, one-run WebGL2 diagnostic. No external code or GPU fallback.
(() => {
  "use strict";
  const WIDTH = 800, HEIGHT = 450, WARMUP_MS = 2000, MEASURE_MS = 30000;
  const MAX_INTERVALS = 20000, ERROR_CHECK_EVERY = 60;
  const canvas = document.getElementById("canvas");
  const start = document.getElementById("start");
  const download = document.getElementById("download");
  const send = document.getElementById("send");
  const state = document.getElementById("state");
  const output = document.getElementById("report");
  const vertexSource = `#version 300 es
layout(location = 0) in vec2 position;
layout(location = 1) in vec3 color;
uniform float angle;
out vec3 vertexColor;
void main() {
  float c = cos(angle), s = sin(angle);
  vec2 rotated = mat2(c, s, -s, c) * position;
  gl_Position = vec4(rotated.x * (450.0 / 800.0), rotated.y, 0.0, 1.0);
  vertexColor = color;
}`;
  const fragmentSource = `#version 300 es
precision highp float;
in vec3 vertexColor;
out vec4 outputColor;
void main() { outputColor = vec4(vertexColor, 1.0); }`;
  let gl = null, program = null, buffer = null, vao = null, angle = null;
  let active = false, raf = 0, watchdog = 0, runStart = 0, measureStart = null;
  let previous = null, lastUi = 0, lastAngle = 0, json = null, report = null;
  const shaders = [], intervals = [];
  const rounded = value => Number(value.toFixed(3));

  function fail(stage, message) {
    const error = new Error(message); error.stage = stage; throw error;
  }
  function spacingSummary() {
    if (intervals.length === 0) return { median: null, p95: null, min: null, max: null };
    const sorted = intervals.slice().sort((a, b) => a - b), n = sorted.length;
    return {
      median: rounded(n % 2 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2),
      p95: rounded(sorted[Math.ceil(n * 0.95) - 1]),
      min: rounded(sorted[0]), max: rounded(sorted[n - 1])
    };
  }
  function checkErrors(stage) {
    const code = gl.getError();
    if (code === gl.NO_ERROR) return;
    if (code === gl.CONTEXT_LOST_WEBGL) report.context_lost = true;
    report.gl_errors.push({ stage, code: "0x" + code.toString(16).toUpperCase() });
    fail("webgl_error", "WebGL getError reported an error at " + stage + ".");
  }
  function compile(type, source, label) {
    const shader = gl.createShader(type);
    if (!shader) fail("shader_create", "Could not allocate the " + label + " shader.");
    shaders.push(shader);
    report.shaders[label + "_compile_attempts"]++;
    gl.shaderSource(shader, source); gl.compileShader(shader);
    const ok = Boolean(gl.getShaderParameter(shader, gl.COMPILE_STATUS));
    report.shaders[label + "_compiled"] = ok;
    report.shaders[label + "_log"] = (gl.getShaderInfoLog(shader) || "").slice(0, 4096);
    if (!ok) fail("shader_compile", label + " shader compilation failed; see the compiler log.");
    return shader;
  }
  function initialize() {
    gl = canvas.getContext("webgl2", {
      alpha: false, antialias: false, depth: false, stencil: false,
      premultipliedAlpha: false, preserveDrawingBuffer: false
    });
    if (!gl) fail("webgl2_unavailable", "WebGL2 context creation failed. No WebGL1 or Canvas2D fallback was attempted.");
    report.webgl2_context_created = true;
    report.context_attributes = gl.getContextAttributes();
    report.drawing_buffer = { width: gl.drawingBufferWidth, height: gl.drawingBufferHeight };
    if (gl.drawingBufferWidth !== WIDTH || gl.drawingBufferHeight !== HEIGHT)
      fail("drawing_buffer_size", "The actual drawing buffer does not match the fixed 800 by 450 workload.");
    report.renderer = {
      vendor: gl.getParameter(gl.VENDOR), renderer: gl.getParameter(gl.RENDERER),
      version: gl.getParameter(gl.VERSION), shading_language_version: gl.getParameter(gl.SHADING_LANGUAGE_VERSION),
      debug_extension_available: false, unmasked_vendor: null, unmasked_renderer: null
    };
    const debug = gl.getExtension("WEBGL_debug_renderer_info");
    if (debug) {
      report.renderer.debug_extension_available = true;
      report.renderer.unmasked_vendor = gl.getParameter(debug.UNMASKED_VENDOR_WEBGL);
      report.renderer.unmasked_renderer = gl.getParameter(debug.UNMASKED_RENDERER_WEBGL);
    }
    const vs = compile(gl.VERTEX_SHADER, vertexSource, "vertex");
    const fs = compile(gl.FRAGMENT_SHADER, fragmentSource, "fragment");
    program = gl.createProgram();
    if (!program) fail("program_create", "Could not allocate a WebGL program.");
    gl.attachShader(program, vs); gl.attachShader(program, fs);
    report.shaders.link_attempts++; gl.linkProgram(program);
    report.shaders.linked = Boolean(gl.getProgramParameter(program, gl.LINK_STATUS));
    report.shaders.link_log = (gl.getProgramInfoLog(program) || "").slice(0, 4096);
    if (!report.shaders.linked) fail("program_link", "Program linking failed; see the linker log.");
    buffer = gl.createBuffer(); vao = gl.createVertexArray();
    if (!buffer || !vao) fail("geometry_create", "Could not allocate triangle geometry.");
    gl.bindVertexArray(vao); gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
       0.00,  0.65, 1, 0, 0,
      -0.55, -0.40, 0, 1, 0,
       0.55, -0.40, 0, 0, 1
    ]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 20, 0);
    gl.enableVertexAttribArray(1); gl.vertexAttribPointer(1, 3, gl.FLOAT, false, 20, 8);
    gl.useProgram(program); angle = gl.getUniformLocation(program, "angle");
    if (angle === null) fail("uniform", "Rotation uniform was not found.");
    gl.viewport(0, 0, WIDTH, HEIGHT); gl.clearColor(0, 0, 0, 1);
    checkErrors("initialization");
  }
  function draw(rotation) {
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(program); gl.bindVertexArray(vao); gl.uniform1f(angle, rotation);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
  function cleanup() {
    if (!gl || gl.isContextLost()) return;
    gl.bindVertexArray(null); gl.bindBuffer(gl.ARRAY_BUFFER, null); gl.useProgram(null);
    if (vao) gl.deleteVertexArray(vao);
    if (buffer) gl.deleteBuffer(buffer);
    if (program) gl.deleteProgram(program);
    for (const shader of shaders) gl.deleteShader(shader);
  }
  function finish(status, failure = null) {
    if (!active) return;
    active = false; cancelAnimationFrame(raf); clearTimeout(watchdog);
    report.status = status; report.failure = failure;
    report.timing.interval_samples = intervals.length;
    report.timing.raf_spacing_ms = spacingSummary();
    report.timing.gaps_over_50_ms = intervals.filter(value => value > 50).length;
    report.timing.total_elapsed_ms = rounded(performance.now() - runStart);
    report.timing.measurement_until_stop_ms = measureStart === null ? null : rounded(performance.now() - measureStart);
    if (status === "completed") {
      try {
        if (gl.isContextLost()) fail("context_lost", "WebGL context was lost before verification.");
        // A new verification draw and exactly one pixel read are OUTSIDE all
        // measured callback samples. readPixels may synchronize with the GPU.
        draw(lastAngle); report.draws.verification++;
        const pixel = new Uint8Array(4);
        report.pixel_check.attempted = true;
        gl.readPixels(WIDTH / 2, HEIGHT / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
        checkErrors("single_pixel_verification");
        report.pixel_check = { attempted: true, outside_timing: true, x: WIDTH / 2, y: HEIGHT / 2,
          rgba: Array.from(pixel), rgb_nonzero: pixel[0] !== 0 || pixel[1] !== 0 || pixel[2] !== 0 };
        if (!report.pixel_check.rgb_nonzero) fail("black_center_pixel", "The triangle centre read back black.");
      } catch (error) { report.status = "failed"; report.failure = { stage: error.stage || "verification", message: error.message.slice(0, 512) }; }
    }
    if (gl && gl.isContextLost()) report.context_lost = true;
    if (document.visibilityState !== "visible") {
      report.visibility_changed = true; report.status = "invalid";
      report.failure = { stage: "visibility_changed", message: "The tab was not visible at verification completion." };
    }
    report.valid = report.status === "completed" && !report.context_lost && !report.visibility_changed && report.pixel_check.rgb_nonzero === true;
    try { cleanup(); } catch (_) { /* Cleanup cannot invent a successful GPU result. */ }
    json = JSON.stringify(report, null, 2) + "\n";
    output.textContent = json; download.disabled = false; send.disabled = false;
    state.textContent = report.valid
      ? "Completed · " + report.draws.measured + " measured draw calls · rAF median " + report.timing.raf_spacing_ms.median + " ms, p95 " + report.timing.raf_spacing_ms.p95 + " ms · centre pixel non-black."
      : "Run " + report.status + ": " + (report.failure ? report.failure.message : "Results are invalid.");
  }
  function frame(timestamp) {
    if (!active) return;
    try {
      if (document.visibilityState !== "visible") { report.visibility_changed = true; fail("visibility_changed", "Tab visibility changed; timing is invalid."); }
      if (gl.isContextLost()) { report.context_lost = true; fail("context_lost", "WebGL context was lost."); }
      const elapsed = timestamp - runStart;
      lastAngle = elapsed / 1000;
      if (elapsed < WARMUP_MS) { draw(lastAngle); report.draws.warmup++; }
      else {
        if (measureStart === null) {
          measureStart = timestamp; report.timing.warmup_elapsed_ms = rounded(elapsed);
          // Fails closed if rAF stops being serviced while the tab stays visible.
          clearTimeout(watchdog);
          watchdog = setTimeout(() => finish("failed", { stage: "animation_timeout", message: "Animation callbacks exceeded the measurement budget." }), MEASURE_MS + 1000);
        }
        report.timing.measured_raf_callbacks++;
        if (previous !== null) {
          if (intervals.length === MAX_INTERVALS) fail("sample_limit", "Animation sample limit exceeded.");
          intervals.push(timestamp - previous);
        }
        previous = timestamp;
        report.timing.measurement_elapsed_ms = rounded(timestamp - measureStart);
        if (timestamp - measureStart >= MEASURE_MS) { checkErrors("measurement_end"); finish("completed"); return; }
        draw(lastAngle); report.draws.measured++;
      }
      if ((report.draws.warmup + report.draws.measured) % ERROR_CHECK_EVERY === 0) checkErrors("periodic_draw_check");
      if (timestamp - lastUi > 250) {
        lastUi = timestamp;
        state.textContent = measureStart === null ? "Warm-up · " + report.draws.warmup + " draw calls"
          : "Measuring · " + report.draws.measured + " draw calls · " + (report.timing.measurement_elapsed_ms / 1000).toFixed(1) + " / 30 seconds";
      }
      raf = requestAnimationFrame(frame);
    } catch (error) { finish(error.stage === "visibility_changed" ? "invalid" : "failed", { stage: error.stage || "javascript", message: error.message.slice(0, 512) }); }
  }
  start.addEventListener("click", () => {
    start.disabled = true; active = true; runStart = performance.now();
    report = {
      schema_version: 1, probe: "perpendicular-webgl2-geometry", status: "running", valid: false,
      hardware_classification: "not_determined", host_acceleration_verified: false,
      webgl2_context_created: false, requested_canvas: { width: WIDTH, height: HEIGHT },
      context_lost: false, visibility_changed: false,
      shaders: { vertex_compile_attempts: 0, vertex_compiled: false, fragment_compile_attempts: 0, fragment_compiled: false, link_attempts: 0, linked: false },
      gl_errors: [], draws: { warmup: 0, measured: 0, verification: 0 },
      timing: { warmup_requested_ms: WARMUP_MS, measurement_requested_ms: MEASURE_MS, warmup_elapsed_ms: null,
        measurement_elapsed_ms: 0, measured_raf_callbacks: 0, interval_samples: 0, error_check_every_draws: ERROR_CHECK_EVERY },
      pixel_check: { attempted: false, outside_timing: true, rgb_nonzero: null },
      evidence_scope: "Browser rAF spacing and a single WebGL2 shader pixel; not physical FPS, input latency, hardware classification or host acceleration proof."
    };
    try {
      if (document.visibilityState !== "visible") { report.visibility_changed = true; fail("visibility_changed", "Start with this tab visible."); }
      initialize();
      // Initialization/compilation is outside warm-up and timing.
      runStart = performance.now();
      watchdog = setTimeout(() => finish("failed", { stage: "warmup_timeout", message: "Animation callbacks did not complete warm-up." }), WARMUP_MS + 1000);
      raf = requestAnimationFrame(frame);
    } catch (error) { finish(error.stage === "visibility_changed" ? "invalid" : "failed", { stage: error.stage || "initialization", message: error.message.slice(0, 512) }); }
  });
  document.addEventListener("visibilitychange", () => {
    if (active) { report.visibility_changed = true; finish("invalid", { stage: "visibility_changed", message: "Tab visibility changed; timing is invalid." }); }
  });
  canvas.addEventListener("webglcontextlost", event => {
    event.preventDefault();
    if (active) { report.context_lost = true; finish("failed", { stage: "context_lost", message: "WebGL context was lost; the run will not resume." }); }
  });
  download.addEventListener("click", () => {
    if (json === null) return;
    const url = URL.createObjectURL(new Blob([json], { type: "application/json" }));
    const link = document.createElement("a"); link.href = url; link.download = "windows-browser-webgl2.json";
    link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  send.addEventListener("click", async () => {
    if (json === null) return;
    if (location.protocol !== "http:" && location.protocol !== "https:") { state.textContent = "Sending requires the local HTTP test server. Download JSON remains available."; return; }
    send.disabled = true;
    const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 5000);
    try {
      const response = await fetch("./result", { method: "POST", headers: { "Content-Type": "application/json" }, body: json,
        credentials: "omit", cache: "no-store", redirect: "error", referrerPolicy: "no-referrer", signal: controller.signal });
      if (!response.ok) { state.textContent = "Local server rejected the report (HTTP " + response.status + "). Download JSON remains available."; return; }
      state.textContent = "Report sent to the local test server. This is a transfer acknowledgement.";
    } catch (error) { state.textContent = "Local report transfer failed (" + error.name + "). Download JSON remains available."; }
    finally { clearTimeout(timeout); send.disabled = false; }
  });
})();

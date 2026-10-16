# Bounded local RFB cursor value

`RFBCursor.swift` implements our negotiated RFB32/depth24 little-endian RGB888
Cursor/RichCursor pseudo-encoding `-239`. The raw-pixels-plus-MSB-first,
byte-padded-per-row shape layout follows
[RFC6143 section7.8.1](https://www.rfc-editor.org/rfc/rfc6143#section-7.8.1).
This is independent source code, with no Parallels implementation or runtime.

Integration order:

1. Handle encoding `RFBCursor.encoding` separately from framebuffer rectangles:
   x/y are image hotspots, not framebuffer offsets. Do not resize or mark the
   framebuffer damaged for a cursor-shape update.
2. Call `RFBCursor.payloadLength(width:height:hotspotX:hotspotY:)` before reading
   any pixels. It rejects invalid/oversized headers before multiplication or
   allocation. Each dimension is at most512; maximum payload is1,081,344 bytes.
3. Read exactly that bounded size, then call
   `RFBCursor.decode(width:height:hotspotX:hotspotY:payload:)`. Truncation AND
   surplus bytes are invalid. A rejected header is a protocol failure, not an
   invitation to read its advertised unbounded length.
4. Hand off the immutable `Sendable` value through a bounded/coalescing UI path.
   Its `pixelsBGRA` is top-row-first, alpha255 for mask1, RGBA zero for mask0.
   The wire fourth byte is ignored; unused mask padding bits are ignored.

A hide update is explicitly0×0, hotspot(0,0), empty payload. A single zero
axis or a nonzero hotspot on that empty image is rejected. A positive-sized,
fully transparent image remains a shape update, distinct from this hide value.
These are the client's strict admission rules; they do not invoke a global
host-cursor hide operation.

`cursor.fittedGeometry(framebufferSize:viewBounds:)` returns nil for hidden
updates, otherwise an `RFBCursorGeometry` with aspect-fit `framebufferRect`,
`imageSize`, `hotspot` and `pointsPerGuestPixel`. Supply VIEW POINTS with a
flipped/top-left coordinate convention, not drawable/backing pixels. Geometry
requires finite positive sizes, finite extents and a finite nonzero scale.
`geometry.imageRect(atViewPoint:)` anchors the image at pointer minus scaled
hotspot; it returns nil outside the fitted framebuffer/inside letterboxing or
for nonfinite points. It does not read, move, warp or inject a pointer. The separate `RFBCursorPresentation.swift` adapter and `VMFramebufferView`
integration control local cursor rectangles and connection/focus lifecycle,
as described below.

Run the standalone, UI-free value checks:

```sh
bash macos/Tests/run-rfb-cursor-tests.sh
```

The runner compiles only the new decoder and its harness with Swift6/macOS14,
then checks fixed pixel/mask oracles, padding and Data slices, non-square and
maximum shapes, hotspot/header rejection before payload reads, exact payload
length, hidden state, fractional/integer fit, letterboxing, NaN/infinite and
overflowing geometry. A separate PRIVATE mutated decoder changes only mask
bit order from MSB to LSB; the same fixed oracle must fail. No server, window,
VM, NSCursor visibility operation or input is used. The value runner remains UI-free; the normal check runner also executes it,
and console fixtures separately exercise protocol and AppKit integration.

## Console integration

The normal console now advertises `-239` and handles it before framebuffer
bounds checks. `RFBConnection.onCursor` delivers a bounded immutable value;
cursor-only messages never publish a frame, change desktop size, or request a
full refresh. The existing incremental RFB request continues normally. A
latest-value relay holds at most one pending shape and one main-actor delivery,
independently of the framebuffer relay. Generation and connection identity
checks reject obsolete deliveries. Failure/disconnect clears the shape.

`RFBCursorPresentation.swift` supplies actual premultiplied BGRA CGImage-backed
NSCursor objects, with image size and hotspot scaled in view points. A 0x0 hide
uses an explicit transparent pixel in a local cursor rectangle. No global hide,
warp, association, event posting, mouse tap or system pointer capture is used.
Cursor rectangles apply only inside the aspect-fit display of a key, connected
window with pixels; letterboxing retains the host cursor. Resizing, native-frame
dimensions, focus changes, status changes and disconnect invalidate rectangles.
A server that ignores this optional encoding leaves the prior host cursor policy.

`run-console-tests.sh` adds fragmented wire shape/hide updates, shape dimensions
larger than the framebuffer, a nonzero hotspot outside its framebuffer geometry,
exact alpha/mask bytes, cursor-only callback before any raw pixels, subsequent
raw-stream alignment and four header-only rejection fixtures. The AppKit fixture
constructs real cursor images and verifies point size/hotspot, a transparent
hidden shape, status/disconnect cleanup and a 501-update stalled-main-loop
latest-shape handoff. Key-window state is deliberately supplied by a fixture
window without taking user focus; actual OS cursor-rectangle transitions remain
a live acceptance gate. Standalone decoder tests are included in `scripts/check.sh`.

These tests do not establish Windows cursor shape delivery, absence of a
producer-composited cursor in native scanout, or input-to-image latency. In
particular, a native producer must prove whether its surface already contains
a cursor before claiming that the native+RFB combination avoids double cursors.

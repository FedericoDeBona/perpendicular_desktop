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
for nonfinite points. It does not read, move, warp or inject a pointer. No
NSCursor/AppKit adapter is included; the root-owned integration controls local
cursor rectangles and connection/focus lifecycle separately.

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
VM, NSCursor visibility operation or input is used. Nothing is integrated into
VMConsole or the normal check runner by these files.

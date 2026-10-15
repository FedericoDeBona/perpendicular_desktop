
// Appended to VMConsole.swift by capture-console.sh. This development-only
// executable hosts the real representable and never sends guest input.
@MainActor
private extension VMFramebufferView {
    var captureImage: CGImage? { framebuffer }
    var captureStatus: String { status }
}

private enum ConsoleCaptureError: LocalizedError {
    case invalidArguments
    case timedOut(String)
    case imageEncoding

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: capture-console.sh SOCKET OUTPUT.png [TIMEOUT_SECONDS]"
        case .timedOut(let status): return "No framebuffer received before timeout: \(status)"
        case .imageEncoding: return "Could not encode console image"
        }
    }
}

@MainActor
private func findFramebuffer(in view: NSView) -> VMFramebufferView? {
    if let framebuffer = view as? VMFramebufferView { return framebuffer }
    for child in view.subviews {
        if let found = findFramebuffer(in: child) { return found }
    }
    return nil
}

@MainActor
private func captureLiveConsole() throws {
    let args = CommandLine.arguments
    guard args.count >= 3, args[1].hasPrefix("/"), args[2].hasPrefix("/") else {
        throw ConsoleCaptureError.invalidArguments
    }
    let timeout = args.count > 3 ? Double(args[3]) ?? 20 : 20
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let size = CGSize(width: 1280, height: 800)
    let root = VMConsoleView(socketPath: args[1], isActive: true)
        .frame(width: size.width, height: size.height)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let started = ProcessInfo.processInfo.systemUptime
    let deadline = Date().addingTimeInterval(max(1, min(timeout, 120)))
    var framebufferView: VMFramebufferView?
    var firstFrameAt: TimeInterval?
    var observedFrames = 0
    var previousImage: CGImage?
    while Date() < deadline {
        host.layoutSubtreeIfNeeded()
        framebufferView = findFramebuffer(in: host)
        if let image = framebufferView?.captureImage, image !== previousImage {
            observedFrames += 1
            previousImage = image
            if firstFrameAt == nil { firstFrameAt = ProcessInfo.processInfo.systemUptime }
        }
        if let firstFrameAt, ProcessInfo.processInfo.systemUptime - firstFrameAt >= 1 { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    guard let view = framebufferView, let image = view.captureImage else {
        throw ConsoleCaptureError.timedOut(framebufferView?.captureStatus ?? "View was not created")
    }
    defer { view.disconnect() }
    window.displayIfNeeded()
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw ConsoleCaptureError.imageEncoding
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let rendered = bitmap.representation(using: .png, properties: [:]),
          let raw = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw ConsoleCaptureError.imageEncoding
    }
    let output = URL(fileURLWithPath: args[2])
    let rawOutput = output.deletingPathExtension().appendingPathExtension("framebuffer.png")
    let ppmOutput = output.deletingPathExtension().appendingPathExtension("framebuffer.ppm")
    let metadataOutput = output.deletingPathExtension().appendingPathExtension("json")
    try rendered.write(to: output)
    try raw.write(to: rawOutput)
    // Preserve exact received RGB bytes independently of AppKit colour conversion.
    // This permits a byte-level comparison with QEMU's read-only QMP screendump.
    guard let source = image.dataProvider?.data else { throw ConsoleCaptureError.imageEncoding }
    let pixelCount = image.width * image.height
    var rgb = Data(count: pixelCount * 3)
    let sourceData = source as Data
    rgb.withUnsafeMutableBytes { destination in
        sourceData.withUnsafeBytes { bytes in
            for pixel in 0..<pixelCount {
                destination[pixel * 3] = bytes[pixel * 4 + 2]
                destination[pixel * 3 + 1] = bytes[pixel * 4 + 1]
                destination[pixel * 3 + 2] = bytes[pixel * 4]
            }
        }
    }
    var ppm = Data("P6\n\(image.width) \(image.height)\n255\n".utf8)
    ppm.append(rgb)
    try ppm.write(to: ppmOutput)
    let metadata: [String: Any] = [
        "socket_path": args[1], "framebuffer_width": image.width, "framebuffer_height": image.height,
        "view_width_points": size.width, "view_height_points": size.height,
        "rendered_width_pixels": bitmap.pixelsWide, "rendered_height_pixels": bitmap.pixelsHigh,
        "first_frame_latency_ms": ((firstFrameAt ?? started) - started) * 1000,
        "observed_frame_changes": observedFrames,
        "observation_seconds": ProcessInfo.processInfo.systemUptime - started,
        "guest_input_sent": false, "status": view.captureStatus,
        "rendered_png": output.path, "framebuffer_png": rawOutput.path,
        "framebuffer_ppm": ppmOutput.path
    ]
    let json = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: metadataOutput)
    print(String(decoding: json, as: UTF8.self))
}

do { try captureLiveConsole() }
catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

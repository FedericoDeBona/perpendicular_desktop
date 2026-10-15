import AppKit
import Metal

@MainActor
private func texture(_ renderer: VMMetalRenderer, _ width: Int, _ height: Int) -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
    return renderer.device.makeTexture(descriptor: descriptor)!
}

@MainActor
private func render(_ renderer: VMMetalRenderer, _ frame: VMDisplayFrame,
                    _ width: Int, _ height: Int) throws -> (any MTLTexture) {
    let target = texture(renderer, width, height)
    let command = renderer.queue.makeCommandBuffer()!
    try renderer.encode(frame, into: target, commandBuffer: command)
    command.commit(); command.waitUntilCompleted()
    precondition(command.status == .completed, "Real GPU command failed")
    return target
}

private func rgba(_ texture: any MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return [pixel[2], pixel[1], pixel[0], pixel[3]]
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
}

@MainActor
private func benchmark(_ renderer: VMMetalRenderer, width: Int, height: Int,
                       targetWidth: Int, targetHeight: Int) throws -> [String: Any] {
    let frame = VMDisplayFrame(width: width, height: height, pixels: Data(repeating: 127, count: width * height * 4))
    let target = texture(renderer, targetWidth, targetHeight)
    let colors = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: targetWidth, height: targetHeight,
        bitsPerComponent: 8, bytesPerRow: targetWidth * 4, space: colors,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let rect = VMDisplayGeometry.fit(source: CGSize(width: width, height: height),
        destination: CGSize(width: targetWidth, height: targetHeight))
    var cg: [Double] = [], metalMain: [Double] = [], metalCompletion: [Double] = []
    // Warm-up includes shader/texture allocation; reported samples exclude it.
    for index in 0..<65 {
        let start = ProcessInfo.processInfo.systemUptime
        let provider = CGDataProvider(data: frame.pixels as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colors,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        context.interpolationQuality = .none // The previous renderer's exact filtering policy.
        context.draw(image, in: rect)
        let cpu = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let began = ProcessInfo.processInfo.systemUptime
        let command = renderer.queue.makeCommandBuffer()!
        try renderer.encode(frame, into: target, commandBuffer: command)
        command.commit()
        let submitted = (ProcessInfo.processInfo.systemUptime - began) * 1000
        command.waitUntilCompleted()
        precondition(command.status == .completed)
        let completed = (ProcessInfo.processInfo.systemUptime - began) * 1000
        if index >= 5 { cg.append(cpu); metalMain.append(submitted); metalCompletion.append(completed) }
    }
    func summary(_ values: [Double]) -> [String: Any] {
        ["p50_ms": percentile(values, 0.5), "p95_ms": percentile(values, 0.95),
         "over_16_67_ms": values.filter { $0 > 16.67 }.count, "samples": values.count]
    }
    return ["source": "\(width)x\(height)", "destination": "\(targetWidth)x\(targetHeight)",
            "old_coregraphics_main": summary(cg), "metal_upload_encode_main": summary(metalMain),
            "metal_offscreen_completion": summary(metalCompletion)]
}

@main
private enum DisplayPresenterCheck {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        guard let renderer = VMMetalRenderer() else { fatalError("Real Metal device/pipeline unavailable; GPU checks did not pass") }
        let quadrants = VMDisplayFrame(width: 2, height: 2, pixels: Data([
            0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0
        ]))
        for (width, height) in [(12, 8), (7, 11), (2, 2), (32, 16)] {
            let image = try render(renderer, quadrants, width, height)
            let rect = VMDisplayGeometry.fit(source: CGSize(width: 2, height: 2), destination: CGSize(width: width, height: height))
            let left = Int(rect.minX + rect.width * 0.2), right = Int(rect.minX + rect.width * 0.8)
            let top = Int(rect.minY + rect.height * 0.2), bottom = Int(rect.minY + rect.height * 0.8)
            precondition(rgba(image, left, top) == [255, 0, 0, 255], "Red channel/top origin mismatch")
            precondition(rgba(image, right, top) == [0, 255, 0, 255], "Green mismatch")
            precondition(rgba(image, left, bottom) == [0, 0, 255, 255], "Blue/vertical orientation mismatch")
            precondition(rgba(image, right, bottom) == [255, 255, 255, 255], "Opaque padding conversion mismatch")
            if rect.minX >= 1 { precondition(rgba(image, 0, height / 2) == [0, 0, 0, 255], "Horizontal margin not black") }
            if rect.minY >= 1 { precondition(rgba(image, width / 2, 0) == [0, 0, 0, 255], "Vertical margin not black") }
        }
        let edge = VMDisplayFrame(width: 2, height: 1, pixels: Data([0, 0, 0, 0, 255, 255, 255, 0]))
        let integer = try render(renderer, edge, 8, 4)
        precondition(rgba(integer, 3, 1)[0] == 0 && rgba(integer, 4, 1)[0] == 255, "Integer scaling blurred pixels")
        let fractional = try render(renderer, edge, 7, 4)
        precondition((100...155).contains(Int(rgba(fractional, 3, 1)[0])), "Fractional scaling did not interpolate")
        let changed = VMDisplayFrame(width: 3, height: 1, pixels: Data([255, 0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0]))
        let resized = try render(renderer, changed, 9, 3)
        precondition(rgba(resized, 1, 1) == [0, 0, 255, 255] && rgba(resized, 7, 1) == [255, 0, 0, 255], "Guest framebuffer resize reused a stale texture")
        let command: any MTLCommandBuffer
        weak var released: VMMetalRenderer?
        do {
            var temporary: VMMetalRenderer? = VMMetalRenderer()!
            released = temporary
            let target = texture(temporary!, 256, 256)
            command = temporary!.queue.makeCommandBuffer()!
            try temporary!.encode(quadrants, into: target, commandBuffer: command)
            command.commit()
            temporary = nil
        }
        precondition(released == nil, "Renderer retained after teardown")
        command.waitUntilCompleted()
        precondition(command.status == .completed, "In-flight resources were destroyed during teardown")
        weak var releasedView: VMMetalDisplayView?
        autoreleasepool {
            let display = VMMetalDisplayView.make()!
            releasedView = display
            for _ in 0..<100 { display.present(quadrants) }
            precondition(display.coalescedFrames == 99, "Pending frames are not coalesced")
            precondition(display.hitTest(.zero) == nil && display.acceptsFirstResponder == false, "Presenter intercepted guest input")
            // A hidden, disposable native window owns a real CAMetalLayer drawable.
            // It is never ordered on screen and has no engine, socket or guest input.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = display
            display.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            display.draw(in: display)
            for _ in 0..<100 { display.present(changed); display.draw(in: display) }
            let deadline = Date().addingTimeInterval(5)
            while display.completedFrames < 2 && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                if display.completedFrames < 2 { display.draw(in: display) }
            }
            precondition(display.completedFrames >= 2 && display.maximumInFlight == 1,
                         "Real drawable did not complete bounded GPU presentation")
            display.frame.size = CGSize(width: 650, height: 400)
            display.mtkView(display, drawableSizeWillChange: display.drawableSize)
            let previous = display.completedFrames
            display.draw(in: display)
            let resizeDeadline = Date().addingTimeInterval(5)
            while display.completedFrames == previous && Date() < resizeDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                if display.completedFrames == previous { display.draw(in: display) }
            }
            precondition(display.completedFrames > previous, "Resize lost the current frame without a guest update")
            display.reset(); display.stop()
            window.contentView = nil
            window.close()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(releasedView == nil, "Presenter delegate/callback retained the view")
        let results = try [benchmark(renderer, width: 800, height: 600, targetWidth: 1600, targetHeight: 1000),
                           benchmark(renderer, width: 1920, height: 1080, targetWidth: 2560, targetHeight: 1600)]
        let report: [String: Any] = ["device": renderer.device.name, "verified": ["BGRA channels", "top-row orientation", "letterbox", "opaque alpha", "integer sharp", "fractional linear", "framebuffer resize", "bounded pending frame", "input pass-through", "in-flight teardown"],
            "scope": "Synthetic offscreen rendering and hidden-window drawable checks only; no VM, guest frame rate, visible compositor latency or screen capture measured", "benchmarks": results]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try json.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic) }
        print(String(decoding: json, as: UTF8.self))
    }
}

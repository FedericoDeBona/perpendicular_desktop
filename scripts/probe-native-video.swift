// Minimal host-side VP9 feasibility check; not a Windows decoder or runtime payload.
// Accepts the first frame of a profile-0, 8-bit 4:2:0 IVF stream only.
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import CryptoKit

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw ProbeError("\(operation): \(status)") }
}
final class Output {
    var status: OSStatus = noErr
    var image: CVPixelBuffer?
}

func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw ProbeError("Usage: probe-native-video <profile-0.ivf>")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    func little(_ offset: Int, _ bytes: Int) -> UInt64 {
        (0..<bytes).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }
    guard data.count >= 44, data.prefix(4) == Data("DKIF".utf8),
          little(4, 2) == 0, little(6, 2) == 32,
          data[8..<12] == Data("VP90".utf8) else { throw ProbeError("Expected IVF VP9 header") }
    let width = Int(little(12, 2)), height = Int(little(14, 2))
    let size = Int(little(32, 4))
    guard width > 0, height > 0, width <= 4096, height <= 2160,
          size > 0, size <= 32 * 1024 * 1024, data.count >= 44 + size else {
        throw ProbeError("Invalid or out-of-scope first frame")
    }
    // VP9 uncompressed header: frame marker 10, profile bits 00, no show-existing-frame.
    // Reject interframes: this probe has no reference pictures.
    let first = data[44]
    guard first & 0xfc == 0x80 else { throw ProbeError("Expected a profile-0 VP9 keyframe") }
    let payload = data.subdata(in: 44..<(44 + size))
    // vpcC full-box version 1; profile 0, level unspecified, 8-bit 4:2:0,
    // unspecified colour primaries/transfer/matrix. No codec initialization data.
    let config = Data([1, 0, 0, 0, 0, 0, 0x82, 2, 2, 2, 0, 0])
    let extensions: [CFString: Any] = [
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vpcC": config]
    ]
    var format: CMVideoFormatDescription?
    try check(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
        codecType: kCMVideoCodecType_VP9, width: Int32(width), height: Int32(height),
        extensions: extensions as CFDictionary, formatDescriptionOut: &format), "format")
    guard let format else { throw ProbeError("No format") }
    let output = Output()
    var callback = VTDecompressionOutputCallbackRecord(
        decompressionOutputCallback: { opaque, _, status, _, image, _, _ in
            guard let opaque else { return }
            let output = Unmanaged<Output>.fromOpaque(opaque).takeUnretainedValue()
            output.status = status
            output.image = image
        }, decompressionOutputRefCon: Unmanaged.passUnretained(output).toOpaque())
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
    let specification: [CFString: Any] = [
        kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
    ]
    let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
    ]
    var session: VTDecompressionSession?
    try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
        formatDescription: format, decoderSpecification: specification as CFDictionary,
        imageBufferAttributes: attributes as CFDictionary, outputCallback: &callback,
        decompressionSessionOut: &session), "session")
    guard let session else { throw ProbeError("No session") }
    defer { VTDecompressionSessionInvalidate(session) }
    var block: CMBlockBuffer?
    try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
        memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: size, flags: 0,
        blockBufferOut: &block), "block")
    guard let block else { throw ProbeError("No block") }
    try payload.withUnsafeBytes { bytes in
        try check(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
            offsetIntoDestination: 0, dataLength: size), "payload")
    }
    var sample: CMSampleBuffer?
    var sampleSize = size
    try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
        sampleBufferOut: &sample), "sample")
    guard let sample else { throw ProbeError("No sample") }
    let started = DispatchTime.now().uptimeNanoseconds
    try check(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
        flags: [], frameRefcon: nil, infoFlagsOut: nil), "decode")
    try check(VTDecompressionSessionWaitForAsynchronousFrames(session), "wait")
    try check(output.status, "callback")
    guard let image = output.image,
          CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height,
          CVPixelBufferGetPlaneCount(image) == 2,
          CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { throw ProbeError("Missing/invalid NV12 output") }
    let decodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    var hardwareReference: Unmanaged<CFTypeRef>?
    try check(VTSessionCopyProperty(session,
        key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        allocator: kCFAllocatorDefault, valueOut: &hardwareReference), "hardware property")
    let hardware = hardwareReference?.takeRetainedValue()
    guard let device = MTLCreateSystemDefaultDevice() else { throw ProbeError("No Metal device") }
    var cache: CVMetalTextureCache?
    try check(CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache), "Metal cache")
    guard let cache else { throw ProbeError("No Metal cache") }
    var luma: CVMetalTexture?, chroma: CVMetalTexture?
    try check(CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, image, nil,
        .r8Unorm, width, height, 0, &luma), "Metal luma")
    try check(CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, image, nil,
        .rg8Unorm, (width + 1) / 2, (height + 1) / 2, 1, &chroma), "Metal chroma")
    guard let luma, let chroma, CVMetalTextureGetTexture(luma) != nil,
          CVMetalTextureGetTexture(chroma) != nil else { throw ProbeError("No Metal plane textures") }
    try check(CVPixelBufferLockBaseAddress(image, .readOnly), "lock")
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    var bytes = Data()
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, plane) else { throw ProbeError("No pixels") }
        let rows = CVPixelBufferGetHeightOfPlane(image, plane)
        let rowBytes = CVPixelBufferGetWidthOfPlane(image, plane) * (plane == 0 ? 1 : 2)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
        for row in 0..<rows { bytes.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: rowBytes) }
    }
    let result: [String: Any] = ["codec": "vp9", "width": width, "height": height,
        "hardware": (hardware as? NSNumber)?.boolValue ?? false,
        "decodeMillisecondsFirstFrame": decodeMilliseconds,
        "metalPlanes": 2, "pixelBytes": bytes.count,
        "nv12SHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
    let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: json, as: UTF8.self))
}
do { try run() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

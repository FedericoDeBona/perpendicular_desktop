import Foundation
import CoreGraphics
import Metal
import Compression

/// One received BGRA image. The receiver is its only writer before publication;
/// after publication these bytes remain immutable for every CPU/GPU reader.
/// TCP still copies received chunks into this buffer; this removes the later
/// accumulated Data image and texture.replace upload from the Metal path.
final class GuestFrameSurface:@unchecked Sendable {
    private static let device=MTLCreateSystemDefaultDevice()
    static let maximumBytes=32*1024*1024
    let width:Int
    let height:Int
    let stride:Int
    let byteCount:Int
    let buffer:any MTLBuffer
    let texture:any MTLTexture
    var contents:UnsafeMutableRawPointer {buffer.contents()}

    private init(width:Int,height:Int,stride:Int,buffer:any MTLBuffer,texture:any MTLTexture){
        self.width=width;self.height=height;self.stride=stride;byteCount=stride*height
        self.buffer=buffer;self.texture=texture
    }
    static func allocate(width:Int,height:Int,stride:Int,decodeGuard:Bool=false)->GuestFrameSurface? {
        guard width>0,height>0,width<=16_384,height<=16_384,width<=8_388_608/height,
              stride>=width*4,stride%256==0,stride<=maximumBytes/height,
              let device else{return nil}
        let alignment=device.minimumLinearTextureAlignment(for:.bgra8Unorm)
        guard alignment>0,stride%alignment==0 else{return nil}
        let length=stride*height
        let allocation=length+(decodeGuard ? 1:0)
        guard allocation<=device.maxBufferLength,
              let buffer=device.makeBuffer(length:allocation,options:.storageModeShared) else{return nil}
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage = .shaderRead
        guard let texture=buffer.makeTexture(descriptor:descriptor,offset:0,bytesPerRow:stride) else{return nil}
        return GuestFrameSurface(width:width,height:height,stride:stride,buffer:buffer,texture:texture)
    }

    /// Used only by CPU fallback or an explicit image query. The provider owns
    /// this immutable surface, including its padded rows, until CG releases it.
    func makeImage()->CGImage? {
        let owner=Unmanaged.passRetained(self).toOpaque()
        guard let provider=CGDataProvider(dataInfo:owner,data:contents,size:byteCount,releaseData:{info,_,_ in
            if let info {Unmanaged<GuestFrameSurface>.fromOpaque(info).release()}
        }) else{Unmanaged<GuestFrameSurface>.fromOpaque(owner).release();return nil}
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:stride,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],
            provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
}

/// The extra destination byte makes an overlong decoded image distinguishable
/// from an exact fit: Compression's buffer API may report a full destination.
enum GuestFrameCodec {
    static func decodeLZ4(_ encoded:Data,into destination:UnsafeMutableRawBufferPointer,expected:Int)->Bool {
        guard expected>0,expected<=34*1024*1024,destination.count>expected,!encoded.isEmpty,encoded.count<expected,
            let output=destination.bindMemory(to:UInt8.self).baseAddress else{return false}
        return encoded.withUnsafeBytes { source in
            compression_decode_buffer(output,expected+1,source.bindMemory(to:UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZ4_RAW) == expected
        }
    }
}

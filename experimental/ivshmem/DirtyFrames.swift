import Foundation
import CryptoKit

/// Qualification only: retain an immutable base, copy to a new owned Metal
/// surface, patch, and compare every padded byte to the guest full-frame oracle.
final class ExperimentalDirtyFrames {
    private var key:String?
    private var sequence:UInt32=0
    private var base:GuestFrameSurface?
    func reconstruct(_ header:inout [String:Any],source:UnsafeRawPointer,count:Int,width:Int,height:Int,stride:Int)throws->GuestFrameSurface {
        let started=ProcessInfo.processInfo.systemUptime
        guard let window=header["window"] as? String,let epoch=header["guestWorkerEpoch"] as? String,
              let generation=header["generation"] as? Int,let current=header["ivshmemSequence"] as? UInt32,
              let expected=header["guestPixelsSHA256"] as? String,
              let full=header["dirtyFull"] as? Bool,
              let surface=GuestFrameSurface.allocate(width:width,height:height,stride:stride) else{throw CocoaError(.coderReadCorrupt)}
        let incoming="\(window)|\(epoch)|\(generation)|\(width)|\(height)|\(stride)"
        if full {
            guard header["encoding"] as? String == "raw",count==surface.byteCount else{throw CocoaError(.coderReadCorrupt)}
            surface.contents.copyMemory(from:source,byteCount:count)
            header["dirtyHostBaseCopyMilliseconds"]=0
        }else{
            guard header["encoding"] as? String == "dirty-raw",key==incoming,let base,
                  header["dirtyBaseIVSequence"] as? UInt32 == sequence,
                  let rectangles=header["guestDirtyRects"] as? [[Int]],rectangles.count<=32 else{throw CocoaError(.coderReadCorrupt)}
            let copied=ProcessInfo.processInfo.systemUptime
            surface.contents.copyMemory(from:base.contents,byteCount:surface.byteCount)
            header["dirtyHostBaseCopyMilliseconds"]=(ProcessInfo.processInfo.systemUptime-copied)*1000
            var offset=0
            for r in rectangles {
                guard r.count==4 else{throw CocoaError(.coderReadCorrupt)}
                let (x,y,w,h)=(r[0],r[1],r[2],r[3])
                guard x>=0,y>=0,x<width,y<height,w>0,h>0,w<=width-x,h<=height-y,
                      w*4<=(count-offset)/h else{throw CocoaError(.coderReadCorrupt)}
                for row in y..<y+h {
                    surface.contents.advanced(by:row*stride+x*4).copyMemory(from:source.advanced(by:offset),byteCount:w*4)
                    offset+=w*4
                }
            }
            guard offset==count else{throw CocoaError(.coderReadCorrupt)}
        }
        let data=Data(bytesNoCopy:surface.contents,count:surface.byteCount,deallocator:.none)
        let actual=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        header["hostPixelsSHA256"]=actual;header["hostPixelsMatchGuest"]=expected==actual
        guard expected==actual else{throw CocoaError(.coderReadCorrupt)}
        header["dirtyHostReconstructionMilliseconds"]=(ProcessInfo.processInfo.systemUptime-started)*1000
        // Only publish an immutable owned image; neither this nor the old base
        // is modified again, including while a previous Metal draw still reads it.
        self.key=incoming;self.sequence=current;self.base=surface
        return surface
    }
}

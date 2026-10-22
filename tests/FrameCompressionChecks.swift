import Foundation
import Compression

@main
struct FrameCompressionChecks {
    static func main(){
        let original=Data((0..<4096).map{UInt8(($0/16)%256)})
        var encoded=Data(count:original.count)
        let count=encoded.withUnsafeMutableBytes { output in original.withUnsafeBytes { source in
            compression_encode_buffer(output.bindMemory(to:UInt8.self).baseAddress!,output.count,
                source.bindMemory(to:UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZ4_RAW)
        }}
        precondition(count>0 && count<original.count);encoded.count=count
        var decoded=Data(count:original.count+1)
        let valid=decoded.withUnsafeMutableBytes{GuestFrameCodec.decodeLZ4(encoded,into:$0,expected:original.count)}
        precondition(valid && decoded.prefix(original.count) == original)
        for expected in [original.count-1,original.count+1] {
            var output=Data(count:expected+1)
            precondition(!output.withUnsafeMutableBytes{GuestFrameCodec.decodeLZ4(encoded,into:$0,expected:expected)})
        }
        var output=Data(count:original.count+1)
        precondition(!output.withUnsafeMutableBytes{GuestFrameCodec.decodeLZ4(Data(encoded.prefix(3)),into:$0,expected:original.count)})
        print("LZ4 raw: exact pixels accepted; short, overlong and truncated frames rejected.")
    }
}

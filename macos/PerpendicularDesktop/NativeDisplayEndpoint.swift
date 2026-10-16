import Foundation

/// An owned runtime endpoint supplied by the engine after validating the VM's
/// live control identity. The transport independently verifies the peer again.
struct NativeDisplayEndpoint: Codable, Hashable, Sendable {
    let socketPath: String
    let serverPID: Int32
    let expectedUID: UInt32
    let sessionHi: UInt64
    let sessionLo: UInt64
    let epoch: UInt64
    enum CodingKeys: String, CodingKey {
        case socketPath, sessionHi, sessionLo, epoch
        case serverPID = "serverPid"
        case expectedUID = "expectedUid"
    }
}

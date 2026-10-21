import Foundation
import Darwin

/// One request per connection. The private directory and peer UID are the
/// authorization boundary; the guest authentication token never enters this API.
final class MacLocalControl: @unchecked Sendable {
    typealias Reply = @Sendable (Data) -> Void
    typealias Handler = @MainActor @Sendable (Data, @escaping Reply) -> Void
    private let queue = DispatchQueue(label: "perpendicular.local-control")
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private let path: String
    private let handler: Handler
    private var clients = 0 // Accessed only on queue.
    private var stopped = false
    private static let requestLimit = 16_384
    private static let responseLimit = 1_048_576

    init(directory: URL, handler: @escaping Handler) throws {
        let directoryPath = directory.path
        if Darwin.mkdir(directoryPath, 0o700) != 0 && errno != EEXIST {
            throw Self.failure("Could not create the local control directory.")
        }
        var metadata = stat()
        guard Darwin.lstat(directoryPath, &metadata) == 0,
              metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFDIR,
              Darwin.chmod(directoryPath, 0o700) == 0 else {
            throw Self.failure("The local control directory must belong to this user.")
        }
        path = directory.appendingPathComponent("control.sock").path
        var address = try Self.address(path)
        if Darwin.lstat(path, &metadata) == 0 {
            guard metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFSOCK else {
                throw Self.failure("An unexpected file occupies the local control socket.")
            }
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw Self.failure("Could not check local control.") }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let reason = errno
            Darwin.close(probe)
            guard connected != 0 else { throw Self.failure("Another Perpendicular app already owns local control.") }
            guard reason == ECONNREFUSED || reason == ENOENT else {
                throw Self.failure("The existing local control socket could not be checked.")
            }
            guard Darwin.unlink(path) == 0 || errno == ENOENT else {
                throw Self.failure("Could not replace a stale local control socket.")
            }
        } else if errno != ENOENT {
            throw Self.failure("Could not check the local control socket.")
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.failure("Could not open local control.") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); throw Self.failure("Could not bind local control.") }
        guard Darwin.chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            Darwin.close(fd); Darwin.unlink(path)
            throw Self.failure("Could not secure local control.")
        }
        descriptor = fd
        self.handler = handler
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    deinit { source.cancel() }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            source.cancel()
            Darwin.unlink(path)
        }
    }

    private func acceptClients() {
        guard !stopped else { return }
        while true {
            let fd = Darwin.accept(descriptor, nil, nil)
            guard fd >= 0 else { return }
            var uid = uid_t(0), gid = gid_t(0)
            guard clients < 4, getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
                Darwin.close(fd); continue
            }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            var noSignal: Int32 = 1
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                Darwin.close(fd); continue
            }
            clients += 1
            DispatchQueue.global(qos: .utility).async { [self] in
                guard let length = Self.read(fd, 4) else { finish(fd, Self.error("Incomplete local request.")); return }
                let count = length.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
                guard count > 0, count <= Self.requestLimit, let data = Self.read(fd, count) else {
                    finish(fd, Self.error("Local requests must be at most 16 KiB.")); return
                }
                Task { @MainActor [self] in
                    handler(data) { [self] response in
                        DispatchQueue.global(qos: .utility).async { [self] in finish(fd, response) }
                    }
                }
            }
        }
    }

    private func finish(_ fd: Int32, _ response: Data) {
        let data = response.count <= Self.responseLimit ? response : Self.error("Local response exceeded 1 MiB.")
        var length = UInt32(data.count).littleEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(data)
        packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                offset += count
            }
        }
        Darwin.close(fd)
        queue.async { [self] in clients -= 1 }
    }

    private static func read(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < count {
                let received = Darwin.recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { return false }
                offset += received
            }
            return true
        }
        return complete ? data : nil
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw failure("The local control socket path is too long.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        return address
    }

    private static func error(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LocalControl", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

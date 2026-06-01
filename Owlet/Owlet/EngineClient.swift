import Foundation

/// Blocking Unix-domain-socket client for the `owlet-engine` sidecar (feat-021,
/// Step 3a). Connects, writes length-prefixed frames, and reads framed replies.
///
/// This is the low-level IPC unit: it is synchronous and meant to be driven from a
/// background queue (a `Ping`/`Pong` health check, or — in Step 3b — a persistent
/// read loop). The streaming integration and supersession logic live above it.
final class EngineClient {
    enum Failure: Error, Equatable {
        case pathTooLong(Int)
        case connectFailed(Int32)
        case notConnected
        case writeFailed(Int32)
        case readFailed(Int32)
    }

    private var fd: Int32 = -1
    /// Persists across reads so bytes for a not-yet-complete (or a following) frame
    /// already pulled off the socket are not lost between `readMessage()` calls.
    private let buffer = FrameBuffer()

    var isConnected: Bool { fd >= 0 }

    /// Connect to a Unix domain socket. The path must fit `sockaddr_un.sun_path`
    /// (~104 bytes on macOS — the same limit the engine guards, design §5.4).
    func connect(socketPath: String) throws {
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path) // 104 on Darwin
        guard socketPath.utf8.count < capacity else {
            throw Failure.pathTooLong(socketPath.utf8.count)
        }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw Failure.connectFailed(errno) }

        // Don't let a write to a dead engine raise SIGPIPE and kill the host process.
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: capacity) { dstC in
                    strlcpy(dstC, src, capacity)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { rawPtr in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(sock)
            throw Failure.connectFailed(err)
        }
        fd = sock
    }

    /// Write one length-prefixed message frame (blocks until fully written).
    func send(_ msg: HostMessage) throws {
        guard fd >= 0 else { throw Failure.notConnected }
        let data = try EngineFraming.encodeFrame(msg)
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = write(fd, base + written, data.count - written)
                if n <= 0 { throw Failure.writeFailed(errno) }
                written += n
            }
        }
    }

    /// Block until the next complete message arrives. Returns nil on a clean EOF
    /// (the engine closed the connection at a frame boundary).
    func readMessage() throws -> EngineMessage? {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if let msg = try buffer.nextEngineMessage() { return msg }
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return nil }
            if n < 0 { throw Failure.readFailed(errno) }
            buffer.append(Data(chunk[0..<n]))
        }
    }

    /// Bound `read()` so a hung or dead engine can't block the caller forever.
    /// On expiry `readMessage()` throws `readFailed` (errno `EAGAIN`).
    func setReadTimeout(seconds: Double) {
        guard fd >= 0 else { return }
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

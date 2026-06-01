import Foundation

/// Blocking Unix-domain-socket client for the `owlet-engine` sidecar (feat-021).
/// Connects, writes length-prefixed frames, and reads framed replies.
///
/// Thread model: a background reader thread owns the read loop and is the *sole*
/// closer of the descriptor. All access to `fd` goes through `fdLock`, and the blocking
/// `read()` runs on a snapshot taken under that lock — so a sender on another thread,
/// teardown, and the reader never race on the descriptor (TSan-clean), and the snapshot
/// can never name a freed/reused fd (the owner only closes after its loop has exited).
/// A read timeout lets the reader poll for teardown instead of being unblocked by a
/// cross-thread `close()`.
final class EngineClient {
    enum Failure: Error, Equatable {
        case pathTooLong(Int)
        case connectFailed(Int32)
        case notConnected
        case writeFailed(Int32)
        case readFailed(Int32)
        case timedOut
    }

    private let fdLock = NSLock()
    private var fd: Int32 = -1
    /// Touched only by the reader thread (in `readMessage`), so it needs no lock.
    private let buffer = FrameBuffer()

    var isConnected: Bool { fdLock.withLock { fd >= 0 } }

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
        // Bound writes so a live-but-not-draining engine can't block a sender forever.
        var sndTimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &sndTimeout, socklen_t(MemoryLayout<timeval>.size))

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
        fdLock.withLock { fd = sock }
    }

    /// Bound `read()` so the reader can poll for teardown (a timed-out read throws
    /// `.timedOut`, which the loop treats as "check the stop signal and retry").
    func setReadTimeout(seconds: Double) {
        let usec = Int32((seconds - Double(Int(seconds))) * 1_000_000)
        var tv = timeval(tv_sec: Int(seconds), tv_usec: usec)
        fdLock.withLock {
            guard fd >= 0 else { return }
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    /// Write one length-prefixed message frame. Held under `fdLock` (frames are tiny
    /// and `SO_SNDTIMEO` bounds the worst case) so it is atomic w.r.t. `close()`.
    func send(_ msg: HostMessage) throws {
        let data = try EngineFraming.encodeFrame(msg)
        try fdLock.withLock {
            guard fd >= 0 else { throw Failure.notConnected }
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
    }

    /// Block until the next complete message arrives. Returns nil on a clean EOF.
    /// Throws `.timedOut` when a read timeout (set via `setReadTimeout`) elapses with
    /// no data, so the caller can re-check its stop signal.
    func readMessage() throws -> EngineMessage? {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if let msg = try buffer.nextEngineMessage() { return msg }
            let snapshotFD = fdLock.withLock { fd }
            guard snapshotFD >= 0 else { return nil }
            let n = read(snapshotFD, &chunk, chunk.count)
            if n == 0 { return nil } // clean EOF
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw Failure.timedOut }
                throw Failure.readFailed(errno)
            }
            buffer.append(Data(chunk[0..<n]))
        }
    }

    /// Idempotent. Called by the reader thread that owns the read loop (after the loop
    /// exits) and by `deinit`; never races a live `read()` because the owner only
    /// closes once it has stopped reading.
    func close() {
        fdLock.withLock {
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

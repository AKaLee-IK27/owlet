import Foundation
import os.log

/// Background socket I/O for the engine connection. One reader thread per connection
/// owns its `EngineClient` end-to-end: it connects, reads frames, and is the *sole*
/// closer of its descriptor. Teardown/reconnect just bump `epoch`; the reader notices
/// within one read timeout, exits, and closes — so no other thread ever closes a
/// descriptor a blocked `read()` is using. `send` writes from the caller's thread
/// (the locked `EngineClient.send` is atomic w.r.t. close). `@unchecked Sendable`: the
/// lock + epoch provide the safety the compiler can't verify.
final class EngineIO: @unchecked Sendable {
    private static let readTimeout = 0.5

    private let lock = NSLock()
    private var client: EngineClient?
    /// Bumped on every start()/stop(); a reader whose captured epoch no longer matches
    /// is stale, exits at its next read timeout, and fires no callbacks.
    private var epoch = 0

    func start(socketPath: String,
               onMessage: @escaping @Sendable (EngineMessage) -> Void,
               onClosed: @escaping @Sendable () -> Void) {
        // Don't close the prior client here — its own reader owns closing it and will
        // exit within one read timeout once it observes this epoch bump.
        let myEpoch: Int = lock.withLock { epoch += 1; return epoch }
        let thread = Thread { [weak self] in
            self?.runLoop(epoch: myEpoch, socketPath: socketPath, onMessage: onMessage, onClosed: onClosed)
        }
        thread.name = "co.greenpassport.owlet.engine-io"
        thread.start()
    }

    func send(_ message: HostMessage) {
        let client = lock.withLock { self.client }
        try? client?.send(message)
    }

    func stop() {
        lock.withLock { epoch += 1 } // the reader self-exits + closes within a read timeout
    }

    private func runLoop(epoch myEpoch: Int,
                         socketPath: String,
                         onMessage: @Sendable (EngineMessage) -> Void,
                         onClosed: @Sendable () -> Void) {
        func isCurrent() -> Bool { lock.withLock { epoch == myEpoch } }
        // Decide-and-fire atomically so a callback can't slip out after an epoch bump.
        func fireIfCurrent(_ body: () -> Void) { lock.withLock { if epoch == myEpoch { body() } } }

        let client = EngineClient()
        var connected = false
        for _ in 0..<40 {
            if !isCurrent() { client.close(); return } // superseded while connecting
            do { try client.connect(socketPath: socketPath); connected = true; break }
            catch { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard connected else { client.close(); fireIfCurrent { onClosed() }; return }

        let installed: Bool = lock.withLock {
            guard epoch == myEpoch else { return false }
            self.client = client
            return true
        }
        guard installed else { client.close(); return }

        client.setReadTimeout(seconds: Self.readTimeout)
        send(.ping) // handshake via the locked send path — no unlocked write racing send()

        while isCurrent() {
            do {
                guard let message = try client.readMessage() else { break } // clean EOF
                fireIfCurrent { onMessage(message) }
            } catch EngineClient.Failure.timedOut {
                continue // poll: re-check isCurrent()
            } catch {
                break
            }
        }

        lock.withLock { if self.client === client { self.client = nil } }
        client.close() // sole closer, only after the read loop has exited
        fireIfCurrent { onClosed() }
    }
}

/// Production transport: spawns/supervises `owlet-engine` and streams suggestions over
/// a persistent UDS connection. `updateContext` fires a `ContextUpdate` frame; the
/// engine streams `Suggestion`s back through the reader, which this hops to the main
/// actor (FIFO) and forwards via `onSuggestion` (keyed by seq, so the controller drops
/// stale ones). On a dropped connection it reconnects while the supervisor respawns.
@MainActor
final class SidecarTransport: SuggestionTransport {
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "autocomplete")

    var onSuggestion: ((UInt64, TransportSuggestion) -> Void)?
    /// Fires when the engine answers the handshake `Ping` (model loaded / ready).
    var onReady: (() -> Void)?

    private let supervisor: EngineSupervisor
    private let io: EngineIO
    private let socketPath: String
    private var started = false
    private var reconnectScheduled = false

    init(config: EngineSupervisor.Config, supervisor: EngineSupervisor? = nil, io: EngineIO = EngineIO()) {
        self.socketPath = config.socketPath
        self.supervisor = supervisor ?? EngineSupervisor(config: config)
        self.io = io
    }

    func start() {
        guard !started else { return }
        started = true
        supervisor.start()
        connect()
    }

    private func connect() {
        io.start(
            socketPath: socketPath,
            onMessage: { [weak self] message in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(message) } }
            },
            onClosed: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleClosed() } }
            })
    }

    private func handle(_ message: EngineMessage) {
        switch message {
        case let .suggestion(seq, tier, text, replaceRange):
            onSuggestion?(seq, TransportSuggestion(tier: tier, text: text, replaceRange: replaceRange))
        case .pong:
            onReady?()
        case let .error(seq, message):
            Self.logger.error("engine error (seq \(String(describing: seq))): \(message, privacy: .public)")
        }
    }

    private func handleClosed() {
        guard started, !reconnectScheduled else { return }
        // The connection dropped (engine crashed and the supervisor is respawning).
        // Reconnect once after a short delay; EngineIO.start retries the connect until
        // the respawned engine binds. The guard collapses overlapping close callbacks.
        reconnectScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconnectScheduled = false
                guard self.started else { return }
                self.connect()
            }
        }
    }

    func updateContext(_ request: ContextRequest) {
        io.send(.contextUpdate(
            seq: request.seq,
            prefix: request.prefix,
            suffix: request.suffix,
            appID: request.appID,
            trigger: request.trigger))
    }

    func cancel(seq: UInt64) {
        io.send(.cancel(seq: seq))
    }

    func stop() {
        started = false
        reconnectScheduled = false
        io.stop()
        supervisor.stop()
    }
}

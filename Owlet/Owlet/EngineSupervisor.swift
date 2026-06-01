import Foundation

/// A handle to a launched engine process, abstracted so tests can inject a fake
/// without spawning a real `Process`.
protocol EngineProcessHandle: AnyObject {
    /// Invoked on the main actor when the process exits (expectedly or by crash).
    var onTerminate: (@MainActor () -> Void)? { get set }
    /// Ask the process to exit.
    func terminate()
}

/// Spawns and supervises the `owlet-engine` sidecar (feat-021, Step 3a).
///
/// Responsibilities: unlink any stale socket before each (re)spawn so `bind()` can't
/// fail `EADDRINUSE` after a hard crash (design §5.4), launch the helper, and respawn
/// it (with a scheduled backoff) if it dies while the host still wants it running.
/// `stop()` marks intent so a deliberate shutdown does not trigger a respawn.
@MainActor
final class EngineSupervisor {
    struct Config {
        let executableURL: URL
        let socketPath: String
        let modelPath: String?

        init(executableURL: URL, socketPath: String, modelPath: String? = nil) {
            self.executableURL = executableURL
            self.socketPath = socketPath
            self.modelPath = modelPath
        }
    }

    private let config: Config
    private let launch: @MainActor (Config) throws -> EngineProcessHandle
    private let unlinkSocket: (String) -> Void
    private let scheduleRespawn: @MainActor (@escaping @MainActor () -> Void) -> Void

    private var process: EngineProcessHandle?
    private var stopping = false

    /// Number of times a process has been (re)spawned — for tests and diagnostics.
    private(set) var spawnCount = 0

    var isRunning: Bool { process != nil }

    init(config: Config,
         launch: @escaping @MainActor (Config) throws -> EngineProcessHandle = EngineSupervisor.spawnProcess,
         unlinkSocket: @escaping (String) -> Void = { try? FileManager.default.removeItem(atPath: $0) },
         scheduleRespawn: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = EngineSupervisor.defaultRespawnSchedule) {
        self.config = config
        self.launch = launch
        self.unlinkSocket = unlinkSocket
        self.scheduleRespawn = scheduleRespawn
    }

    func start() {
        stopping = false
        guard process == nil else { return }
        spawn()
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    private func spawn() {
        // Stale-socket fix: the prior helper's socket file survives a hard crash and
        // would make the next bind() fail EADDRINUSE. Remove it before (re)spawning.
        unlinkSocket(config.socketPath)
        do {
            let handle = try launch(config)
            spawnCount += 1
            handle.onTerminate = { [weak self] in self?.handleTermination() }
            process = handle
        } catch {
            process = nil
            if !stopping {
                scheduleRespawn { [weak self] in self?.respawnIfWanted() }
            }
        }
    }

    private func handleTermination() {
        process = nil
        guard !stopping else { return }
        scheduleRespawn { [weak self] in self?.respawnIfWanted() }
    }

    private func respawnIfWanted() {
        guard !stopping, process == nil else { return }
        spawn()
    }

    // MARK: - Defaults

    /// Backoff before a respawn so a crash-looping helper doesn't spin the CPU.
    @MainActor
    static func defaultRespawnSchedule(_ block: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            MainActor.assumeIsolated { block() }
        }
    }

    /// Production launcher: spawns the real helper with `--socket` (and `--model`
    /// once Tier 2 lands) and bridges `terminationHandler` to the main actor.
    static func spawnProcess(_ config: Config) throws -> EngineProcessHandle {
        let process = Process()
        process.executableURL = config.executableURL
        var args = ["--socket", config.socketPath]
        if let modelPath = config.modelPath { args += ["--model", modelPath] }
        process.arguments = args

        let handle = ProcessEngineHandle(process)
        process.terminationHandler = { [weak handle] _ in
            handle?.fireTerminate()
        }
        try process.run()
        return handle
    }

    /// Default bundled-helper location and the app-container socket path (design §5.4).
    static func defaultConfig() -> Config {
        let executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/owlet-engine")
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Owlet", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let socketPath = supportDir.appendingPathComponent("engine.sock").path
        return Config(executableURL: executableURL, socketPath: socketPath)
    }
}

/// Wraps a real `Process`. `@unchecked Sendable` because `terminationHandler` fires on
/// an arbitrary queue; it only reads `onTerminate` and hops the call to the main actor.
final class ProcessEngineHandle: EngineProcessHandle, @unchecked Sendable {
    var onTerminate: (@MainActor () -> Void)?
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    fileprivate func fireTerminate() {
        let callback = onTerminate
        Task { @MainActor in callback?() }
    }
}

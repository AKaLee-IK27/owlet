import Foundation

/// Spawns the owlet-rewriter binary and returns its stdout.
/// On timeout or task cancellation, calls `process.terminate()` so the
/// child is actually killed (Swift cancellation alone does not stop a Process).
final class OllamaClient {

    enum Failure: Error, Equatable {
        case timeout
        case emptyOutput
        case backendError(String)         // stderr text
        case launchFailed(String)
    }

    private let executablePath: String
    private let arguments: [String]
    private let environment: [String: String]
    private let timeoutSeconds: TimeInterval

    /// - Parameters:
    ///   - executablePath: absolute path to the executable to spawn (the
    ///     owlet-rewriter Rust binary in production, OR the fixture script in tests).
    ///   - arguments: command-line arguments passed to the executable.
    ///   - environment: extra env vars merged into the child's environment.
    ///   - timeoutSeconds: max wall-clock seconds before the child is terminated.
    init(executablePath: String,
         arguments: [String] = [],
         environment: [String: String] = [:],
         timeoutSeconds: TimeInterval = 30) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }

    func rewrite(_ input: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() }
        catch { throw Failure.launchFailed("\(error)") }

        // Write stdin and close.
        if let data = input.data(using: .utf8) {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdin.fileHandleForWriting.close()

        // Single-resume-site wrapper: tracks whether timeout fired so
        // terminationHandler (the only site that calls cont.resume) can
        // pick the right error. NSLock-guarded to be safe across queues.
        final class TimeoutFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var _didTimeout = false
            var didTimeout: Bool {
                get { lock.withLock { _didTimeout } }
                set { lock.withLock { _didTimeout = newValue } }
            }
        }

        let flag = TimeoutFlag()

        // Race: process completion vs timeout vs Task cancellation.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                // Wrap DispatchWorkItem in unchecked Sendable box so Swift 6
                // strict-concurrency is satisfied when it's captured by terminationHandler.
                struct Box: @unchecked Sendable { let work: DispatchWorkItem }

                let timeoutWork = DispatchWorkItem {
                    if process.isRunning {
                        flag.didTimeout = true
                        process.terminate()
                        // do NOT call cont.resume here — terminationHandler is
                        // the single resume site; it reads flag.didTimeout.
                    }
                }
                let box = Box(work: timeoutWork)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

                process.terminationHandler = { proc in
                    box.work.cancel()
                    if flag.didTimeout {
                        cont.resume(throwing: Failure.timeout)
                        return
                    }
                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let outText = String(data: outData, encoding: .utf8) ?? ""
                    let errText = String(data: errData, encoding: .utf8) ?? ""
                    if proc.terminationStatus != 0 {
                        cont.resume(throwing: Failure.backendError(errText))
                        return
                    }
                    let cleaned = outText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.isEmpty {
                        cont.resume(throwing: Failure.emptyOutput)
                    } else {
                        cont.resume(returning: cleaned)
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

protocol Rewriting: Sendable {
    func rewrite(_ input: String) async throws -> String
}

extension OllamaClient: Rewriting {}

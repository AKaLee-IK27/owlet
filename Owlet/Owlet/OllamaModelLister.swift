import Foundation
import os.log

/// Discovers locally pulled Ollama models by shelling out to `ollama list`.
/// The subprocess invocation is wrapped in a 1-second timeout so opening the
/// Settings window can't hang on a stuck Ollama daemon. Parsing is a pure
/// function (table layout: header row, then whitespace-delimited columns;
/// first column is the model name).
enum OllamaModelLister {

    enum Failure: Error {
        case spawnFailed(String)
        case timedOut
        case nonZeroExit(Int32, String)
    }

    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "modellister")
    private static let timeoutSeconds: TimeInterval = 1.0
    private static let binary = "/usr/local/bin/ollama"
    private static let altBinary = "/opt/homebrew/bin/ollama"

    /// Spawn `ollama list`, return parsed model names. Returns the empty
    /// array on any failure — callers should layer their own fallback
    /// (e.g. `["qwen3:8b"]`) when the result is empty so the picker remains usable.
    static func list() async -> [String] {
        do {
            let raw = try await runOllamaList()
            return parse(raw)
        } catch {
            logger.warning("ollama list failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Pure parser. Skips the header row, takes the first whitespace-delimited
    /// column of each subsequent non-empty line.
    static func parse(_ raw: String) -> [String] {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1 else { return [] }
        return lines.dropFirst().compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)
        }
    }

    // MARK: subprocess

    private static func runOllamaList() async throws -> String {
        let exe = FileManager.default.fileExists(atPath: binary) ? binary : altBinary
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["list"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() }
        catch { throw Failure.spawnFailed("\(error)") }

        return try await withCheckedThrowingContinuation { cont in
            // Wraps mutable state that crosses @Sendable closure boundaries.
            // NSLock guards all mutations; @unchecked Sendable is safe here.
            final class State: @unchecked Sendable {
                private let lock = NSLock()
                private var _timedOut = false
                private var _work: DispatchWorkItem?

                var timedOut: Bool {
                    get { lock.withLock { _timedOut } }
                    set { lock.withLock { _timedOut = newValue } }
                }

                func setWork(_ w: DispatchWorkItem) { lock.withLock { _work = w } }
                func cancelWork() { lock.withLock { _work?.cancel() } }
            }

            let state = State()
            let work = DispatchWorkItem {
                if process.isRunning {
                    state.timedOut = true
                    process.terminate()
                }
            }
            state.setWork(work)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: work)

            process.terminationHandler = { proc in
                state.cancelWork()
                if state.timedOut {
                    cont.resume(throwing: Failure.timedOut); return
                }
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outText = String(data: outData, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    cont.resume(throwing: Failure.nonZeroExit(proc.terminationStatus, errText)); return
                }
                cont.resume(returning: outText)
            }
        }
    }
}

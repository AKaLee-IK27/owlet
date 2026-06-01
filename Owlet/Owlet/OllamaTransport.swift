import Foundation
import os.log

/// Rollback transport: wraps the existing one-shot `OllamaPredictor` in the push
/// `SuggestionTransport` shape. Owns its own debounce (Ollama is slow and one-shot,
/// so rapid keystrokes must coalesce here) and the Ollama-specific output cleanup,
/// then pushes a single Tier-0 suggestion. This keeps the pre-sidecar autocomplete
/// path intact behind the Settings engine/Ollama toggle.
@MainActor
final class OllamaTransport: SuggestionTransport {
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "autocomplete")

    var onSuggestion: ((UInt64, TransportSuggestion) -> Void)?

    private let predictor: Predicting
    private let debounceNanos: UInt64
    private var task: Task<Void, Never>?

    init(predictor: Predicting = OllamaPredictor(), debounceNanos: UInt64 = 120_000_000) {
        self.predictor = predictor
        self.debounceNanos = debounceNanos
    }

    func updateContext(_ request: ContextRequest) {
        task?.cancel()
        let debounce = debounceNanos
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: debounce) } catch { return }
            guard let self else { return }
            do {
                let raw = try await self.predictor.suggest(
                    prefix: request.prefix, model: request.model, maxTokens: request.maxTokens)
                if Task.isCancelled { return }
                guard let cleaned = Self.clean(raw, prefix: request.prefix) else {
                    // Cleaned to nothing (prefix echo / quotes only). Correct to drop,
                    // but log so a prefix-echoing model is distinguishable from a
                    // genuine "no continuation" during diagnosis.
                    Self.logger.debug("autocomplete cleaned to empty (prefix len \(request.prefix.count))")
                    return
                }
                self.onSuggestion?(request.seq,
                                   TransportSuggestion(tier: .complete, text: cleaned, replaceRange: nil))
            } catch {
                if Self.isCancellation(error) { return } // normal supersession, not a failure
                // A misconfigured model (not pulled → badStatus, or one that always
                // returns empty) fails on EVERY keystroke with no user-visible ghost.
                // Log those at .error so the no-suggestion cause is diagnosable without
                // re-running the f2ebbf3 investigation; transient blips stay at .debug.
                switch error {
                case OllamaPredictor.Failure.badStatus, OllamaPredictor.Failure.emptyResponse:
                    Self.logger.error("autocomplete model error (check the selected model): \(String(describing: error), privacy: .public)")
                default:
                    Self.logger.debug("ollama prediction failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func cancel(seq: UInt64) {
        task?.cancel()
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Task cancellation surfaces as `CancellationError` from `Task.sleep` and as
    /// `URLError(.cancelled)` from a cancelled `URLSession` request — both are normal
    /// supersession, not failures.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    deinit { task?.cancel() }

    /// Strip the prefix echo and wrapping quotes a chat-ish model sometimes emits,
    /// preserving leading spaces (semantically important for inline insertion). Returns
    /// nil when nothing usable remains. (Moved from the controller — this cleanup is
    /// Ollama-output-specific; the sidecar engine returns a clean suffix already.)
    static func clean(_ raw: String, prefix: String) -> String? {
        var suggestion = raw.trimmingCharacters(in: .newlines)
        guard !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        if suggestion.hasPrefix(prefix) {
            suggestion.removeFirst(prefix.count)
            suggestion = suggestion.trimmingCharacters(in: .newlines)
        }
        if suggestion.hasPrefix("\"") && suggestion.hasSuffix("\"") && suggestion.count >= 2 {
            suggestion.removeFirst()
            suggestion.removeLast()
        }
        return suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : suggestion
    }
}

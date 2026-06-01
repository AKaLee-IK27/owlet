import AppKit
import ApplicationServices
import os.log

struct CaretContext: Equatable {
    let textBeforeCaret: String
    let caretScreenRect: NSRect?
}

protocol AutocompleteAXBridging {
    func currentFocus() -> FocusSnapshot?
    func isPasswordField(_ element: AXUIElement) -> Bool
    func readCaretContext(from element: AXUIElement) -> CaretContext?
    func insertAtCaret(_ text: String, in element: AXUIElement) -> AXBridge.ReplaceResult
}

extension AXBridgeAdapter: AutocompleteAXBridging {
    func currentFocus() -> FocusSnapshot? { AXBridge.currentFocus() }
    func isPasswordField(_ element: AXUIElement) -> Bool { AXBridge.isPasswordField(element) }
    func readCaretContext(from element: AXUIElement) -> CaretContext? { AXBridge.readCaretContext(from: element) }
    func insertAtCaret(_ text: String, in element: AXUIElement) -> AXBridge.ReplaceResult {
        AXBridge.insertAtCaret(text, in: element)
    }
}

@MainActor
final class AutocompleteController {
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "autocomplete")
    private static let debounceNanos: UInt64 = 120_000_000
    private static let maxPrefixCharacters = 1_000

    private let ax: AutocompleteAXBridging
    private let predictor: Predicting
    private let overlay: GhostTextOverlaying
    private let modelProvider: @MainActor () -> String
    private let enabledProvider: @MainActor () -> Bool
    private let maxTokensProvider: @MainActor () -> Int
    private let onVisibilityChanged: @MainActor (Bool) -> Void

    private var debounceTask: Task<Void, Never>?
    private var predictionTask: Task<Void, Never>?
    private var requestID = 0
    private var focusedElement: AXUIElement?
    private var currentSuggestion: String?

    private(set) var suggestionVisible = false {
        didSet {
            if oldValue != suggestionVisible { onVisibilityChanged(suggestionVisible) }
        }
    }

    init(ax: AutocompleteAXBridging = AXBridgeAdapter(),
         predictor: Predicting = OllamaPredictor(),
         overlay: GhostTextOverlaying = GhostTextOverlay(),
         modelProvider: @escaping @MainActor () -> String = { Preferences.shared.autocompleteModel },
         enabledProvider: @escaping @MainActor () -> Bool = { Preferences.shared.autocompleteEnabled },
         maxTokensProvider: @escaping @MainActor () -> Int = { Preferences.shared.suggestionLength.maxTokens },
         onVisibilityChanged: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.ax = ax
        self.predictor = predictor
        self.overlay = overlay
        self.modelProvider = modelProvider
        self.enabledProvider = enabledProvider
        self.maxTokensProvider = maxTokensProvider
        self.onVisibilityChanged = onVisibilityChanged
    }

    func textChanged() {
        guard enabledProvider() else {
            stop()
            return
        }
        debounceTask?.cancel()
        predictionTask?.cancel()
        hideSuggestion()

        debounceTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.debounceNanos) }
            catch { return }
            await self?.beginPrediction()
        }
    }

    func accept() {
        guard suggestionVisible, let suggestion = currentSuggestion, let focusedElement else { return }
        _ = ax.insertAtCaret(suggestion, in: focusedElement)
        stop()
    }

    func dismiss() {
        stop()
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        predictionTask?.cancel()
        predictionTask = nil
        focusedElement = nil
        currentSuggestion = nil
        hideSuggestion()
    }

    private func beginPrediction() {
        guard enabledProvider() else { stop(); return }
        guard let focus = ax.currentFocus() else { hideSuggestion(); return }
        guard !ax.isPasswordField(focus.focusedElement) else { hideSuggestion(); return }
        guard let context = ax.readCaretContext(from: focus.focusedElement),
              let rect = context.caretScreenRect,
              !context.textBeforeCaret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hideSuggestion()
            return
        }

        let prefix = String(context.textBeforeCaret.suffix(Self.maxPrefixCharacters))
        let model = modelProvider()
        let maxTokens = maxTokensProvider()
        let id = requestID + 1
        requestID = id
        focusedElement = focus.focusedElement

        predictionTask?.cancel()
        predictionTask = Task { [weak self, predictor] in
            do {
                let raw = try await predictor.suggest(prefix: prefix, model: model, maxTokens: maxTokens)
                let suggestion = Self.cleanSuggestion(raw, prefix: prefix)
                await MainActor.run {
                    guard let self, self.requestID == id, let suggestion, !suggestion.isEmpty else { return }
                    self.currentSuggestion = suggestion
                    self.suggestionVisible = true
                    self.overlay.show(suggestion, at: rect)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self, self.requestID == id else { return }
                    Self.logger.debug("prediction failed: \(String(describing: error), privacy: .public)")
                    self.hideSuggestion()
                }
            }
        }
    }

    static func cleanSuggestion(_ raw: String, prefix: String) -> String? {
        // Preserve leading spaces: they are semantically important for inline
        // insertion ("hello" + " world"), even though they are easy to miss in
        // the ghost-text overlay. Only strip line breaks around Ollama output.
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

    private func hideSuggestion() {
        overlay.hide()
        suggestionVisible = false
    }
}

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
    private let pausedProvider: @MainActor () -> Bool
    private let deniedAppsProvider: @MainActor () -> Set<String>
    private let onVisibilityChanged: @MainActor (Bool) -> Void

    private var debounceTask: Task<Void, Never>?
    private var predictionTask: Task<Void, Never>?
    private var requestID = 0
    private var focusedElement: AXUIElement?
    private var currentSuggestion: String?
    /// The not-yet-accepted suggestion split into word tokens (each carries its
    /// own leading whitespace so re-joining is lossless). Tab consumes one.
    private var remainingWords: [String] = []
    /// A focused field that returned text but no caret bounds. Cached so we stop
    /// re-querying AX every keystroke for a field that can't position a ghost;
    /// cleared when focus moves to a different element.
    private var unsupportedElement: AXUIElement?

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
         pausedProvider: @escaping @MainActor () -> Bool = { false },
         deniedAppsProvider: @escaping @MainActor () -> Set<String> = { Preferences.shared.autocompleteDeniedApps },
         onVisibilityChanged: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.ax = ax
        self.predictor = predictor
        self.overlay = overlay
        self.modelProvider = modelProvider
        self.enabledProvider = enabledProvider
        self.maxTokensProvider = maxTokensProvider
        self.pausedProvider = pausedProvider
        self.deniedAppsProvider = deniedAppsProvider
        self.onVisibilityChanged = onVisibilityChanged
    }

    func textChanged() {
        guard enabledProvider(), !pausedProvider() else {
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

    /// Tab accepts the next word of the suggestion. On AX-write fields we stay in
    /// partial mode and re-anchor the remaining ghost; on the paste fallback we
    /// can't (the synthetic Cmd+V re-enters our event tap), so we insert the rest
    /// whole and finish — an explicit, documented degrade.
    func accept() {
        guard suggestionVisible, let focusedElement, !remainingWords.isEmpty else { return }

        let next = remainingWords.removeFirst()
        switch ax.insertAtCaret(next, in: focusedElement) {
        case .okAX:
            if remainingWords.isEmpty {
                stop()
            } else {
                reshowRemainder(in: focusedElement)
            }
        case .okPaste, .failed:
            if !remainingWords.isEmpty {
                _ = ax.insertAtCaret(remainingWords.joined(), in: focusedElement)
            }
            stop()
        }
    }

    /// Re-read the caret after a partial accept and redraw the remaining words.
    /// If the field can't report caret bounds at the new position (e.g. a WebKit
    /// degenerate rect — feat-013's deferred case), the accepted text stays and
    /// the ghost simply ends.
    private func reshowRemainder(in element: AXUIElement) {
        let remainder = remainingWords.joined()
        guard let context = ax.readCaretContext(from: element),
              let rect = context.caretScreenRect else {
            stop()
            return
        }
        currentSuggestion = remainder
        overlay.show(remainder, at: rect)
        if suggestionVisible {
            // didSet won't fire (already visible); the event tap cleared its
            // "suggestion visible" flag on the accepted Tab, so re-assert it to
            // keep the next Tab routed to accept.
            onVisibilityChanged(true)
        } else {
            suggestionVisible = true
        }
    }

    /// Split a suggestion into word tokens, each prefixed with its own leading
    /// whitespace, so `tokens.joined() == input`. Leading spaces are semantically
    /// important for inline insertion ("hello" + " world").
    static func splitIntoWordTokens(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWord = false
        for ch in input {
            if ch == " " || ch == "\t" {
                if inWord {
                    tokens.append(current)
                    current = String(ch)
                    inWord = false
                } else {
                    current.append(ch)
                }
            } else {
                current.append(ch)
                inWord = true
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
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
        remainingWords = []
        hideSuggestion()
    }

    private func beginPrediction() {
        guard enabledProvider(), !pausedProvider() else { stop(); return }
        guard let focus = ax.currentFocus() else { hideSuggestion(); return }
        guard !deniedAppsProvider().contains(focus.appBundleID) else { hideSuggestion(); return }
        guard !ax.isPasswordField(focus.focusedElement) else { hideSuggestion(); return }

        // Forget a stale "unsupported" mark once focus moves elsewhere.
        if let unsupported = unsupportedElement, !CFEqual(unsupported, focus.focusedElement) {
            unsupportedElement = nil
        }
        // A field we already know never returns caret bounds: don't re-read AX or
        // predict on every keystroke — just stay quiet until focus changes.
        if let unsupported = unsupportedElement, CFEqual(unsupported, focus.focusedElement) {
            hideSuggestion()
            return
        }

        guard let context = ax.readCaretContext(from: focus.focusedElement) else {
            hideSuggestion()
            return
        }
        guard let rect = context.caretScreenRect else {
            // Text present but no caret bounds → mark unsupported so we degrade
            // cleanly instead of thrashing AX every keystroke.
            unsupportedElement = focus.focusedElement
            hideSuggestion()
            return
        }
        guard !context.textBeforeCaret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
                    self.remainingWords = Self.splitIntoWordTokens(suggestion)
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

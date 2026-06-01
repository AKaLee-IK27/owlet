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

/// Drives inline autocomplete. On each keystroke it reads the caret context and sends
/// a `ContextRequest` to the `SuggestionTransport` *immediately* (no Swift debounce —
/// debounce lives in the transport/engine, design §3). Suggestions arrive asynchronously
/// via `receive(seq:suggestion:)` and are shown only if they match the latest `seq`, so a
/// stale or late result for superseded typing never appears.
@MainActor
final class AutocompleteController {
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "autocomplete")
    private static let maxPrefixCharacters = 1_000

    private let ax: AutocompleteAXBridging
    private let transport: SuggestionTransport
    private let overlay: GhostTextOverlaying
    private let modelProvider: @MainActor () -> String
    private let enabledProvider: @MainActor () -> Bool
    private let maxTokensProvider: @MainActor () -> Int
    private let pausedProvider: @MainActor () -> Bool
    private let deniedAppsProvider: @MainActor () -> Set<String>
    private let onVisibilityChanged: @MainActor (Bool) -> Void

    /// Monotonic generation for the latest caret context. Suggestions tagged with an
    /// older generation are dropped. (This is the `seq` carried on the wire.)
    private var requestID: UInt64 = 0
    /// Rank of the highest tier already shown for the current generation, so a lower
    /// tier can't regress a higher one if results arrive out of order (-1 = none yet).
    private var shownTierRank = -1
    private var focusedElement: AXUIElement?
    /// Caret rect captured for `requestID`; where the matching suggestion is drawn.
    private var currentCaretRect: NSRect?
    private var currentSuggestion: String?
    /// The not-yet-accepted suggestion split into word tokens (each carries its own
    /// leading whitespace so re-joining is lossless). Tab consumes one.
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
         transport: SuggestionTransport = OllamaTransport(),
         overlay: GhostTextOverlaying = GhostTextOverlay(),
         modelProvider: @escaping @MainActor () -> String = { Preferences.shared.autocompleteModel },
         enabledProvider: @escaping @MainActor () -> Bool = { Preferences.shared.autocompleteEnabled },
         maxTokensProvider: @escaping @MainActor () -> Int = { Preferences.shared.suggestionLength.maxTokens },
         pausedProvider: @escaping @MainActor () -> Bool = { false },
         deniedAppsProvider: @escaping @MainActor () -> Set<String> = { Preferences.shared.autocompleteDeniedApps },
         onVisibilityChanged: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.ax = ax
        self.transport = transport
        self.overlay = overlay
        self.modelProvider = modelProvider
        self.enabledProvider = enabledProvider
        self.maxTokensProvider = maxTokensProvider
        self.pausedProvider = pausedProvider
        self.deniedAppsProvider = deniedAppsProvider
        self.onVisibilityChanged = onVisibilityChanged
        transport.onSuggestion = { [weak self] seq, suggestion in
            self?.receive(seq: seq, suggestion: suggestion)
        }
    }

    func textChanged() {
        guard enabledProvider(), !pausedProvider() else {
            stop()
            return
        }
        // The displayed ghost is stale the moment the text changes; hide it and ask
        // for a fresh suggestion. The transport/engine coalesces rapid keystrokes.
        hideSuggestion()
        beginPrediction()
    }

    /// Synchronous guard + AX read, then fire a `ContextRequest`. Runs on every
    /// keystroke; the expensive inference is the transport's problem.
    private func beginPrediction() {
        // Supersede prior in-flight work BEFORE the guards — even when this keystroke is
        // suppressed — so a late result for the previous generation can never satisfy
        // the `seq == requestID` gate or draw at a stale caret. (The pre-refactor
        // controller cancelled unconditionally at the top of textChanged; moving cancel
        // into updateContext lost that for every guard early-return.)
        let seq = newGeneration()
        currentCaretRect = nil
        transport.cancel(seq: seq)

        guard let focus = ax.currentFocus() else { return }
        guard !deniedAppsProvider().contains(focus.appBundleID) else { return }
        guard !ax.isPasswordField(focus.focusedElement) else { return }

        // Forget a stale "unsupported" mark once focus moves elsewhere.
        if let unsupported = unsupportedElement, !CFEqual(unsupported, focus.focusedElement) {
            unsupportedElement = nil
        }
        // A field we already know never returns caret bounds: don't re-read AX or
        // predict on every keystroke — just stay quiet until focus changes.
        if let unsupported = unsupportedElement, CFEqual(unsupported, focus.focusedElement) {
            return
        }

        guard let context = ax.readCaretContext(from: focus.focusedElement) else { return }
        guard let rect = context.caretScreenRect else {
            // Text present but no caret bounds → mark unsupported so we degrade
            // cleanly instead of thrashing AX every keystroke.
            unsupportedElement = focus.focusedElement
            return
        }
        guard !context.textBeforeCaret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let prefix = String(context.textBeforeCaret.suffix(Self.maxPrefixCharacters))
        focusedElement = focus.focusedElement
        currentCaretRect = rect
        transport.updateContext(ContextRequest(
            seq: seq,
            prefix: prefix,
            suffix: "",
            appID: focus.appBundleID,
            trigger: .keystroke,
            model: modelProvider(),
            maxTokens: maxTokensProvider()))
    }

    /// Advance the generation (the wire `seq`) and reset per-generation display state,
    /// so any in-flight result tagged with an older generation is dropped by `receive`.
    @discardableResult
    private func newGeneration() -> UInt64 {
        requestID += 1
        shownTierRank = -1
        return requestID
    }

    /// A suggestion arrived. Show it only if it still matches the latest keystroke and
    /// doesn't regress an already-shown higher tier for this generation.
    private func receive(seq: UInt64, suggestion: TransportSuggestion) {
        guard seq == requestID, let rect = currentCaretRect else { return }
        // Within one generation the engine may push Tier 0 then Tier 2; a higher tier
        // supersedes (spec §3/§5.4). Never let a lower tier regress an already-shown
        // higher one, even if delivery is reordered.
        let rank = Self.tierRank(suggestion.tier)
        guard rank >= shownTierRank else { return }
        let text = suggestion.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        shownTierRank = rank
        currentSuggestion = text
        remainingWords = Self.splitIntoWordTokens(text)
        suggestionVisible = true
        overlay.show(text, at: rect)
    }

    /// Tier ambition order (spec §3): a later/higher tier supersedes the displayed one.
    private static func tierRank(_ tier: SuggestionTier) -> Int {
        switch tier {
        case .complete: return 0
        case .recorrect: return 1
        case .sentence: return 2
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
        // A partial accept supersedes prior in-flight work: a late same-generation push
        // must not clobber the remaining-words state mid-accept.
        newGeneration()
        currentSuggestion = remainder
        currentCaretRect = rect
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
        let seq = newGeneration()
        transport.cancel(seq: seq)
        focusedElement = nil
        currentCaretRect = nil
        currentSuggestion = nil
        remainingWords = []
        hideSuggestion()
    }

    private func hideSuggestion() {
        overlay.hide()
        suggestionVisible = false
    }
}

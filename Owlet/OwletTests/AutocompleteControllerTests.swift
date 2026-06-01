import XCTest
import ApplicationServices
@testable import Owlet

@MainActor
final class AutocompleteControllerTests: XCTestCase {

    final class MockAX: AutocompleteAXBridging {
        var focus: FocusSnapshot?
        var password = false
        var context: CaretContext?
        var inserted: String?
        private(set) var insertedAll: [String] = []
        var insertResult: AXBridge.ReplaceResult = .okAX
        private(set) var readCount = 0

        func currentFocus() -> FocusSnapshot? { focus }
        func isPasswordField(_ element: AXUIElement) -> Bool { password }
        func readCaretContext(from element: AXUIElement) -> CaretContext? {
            readCount += 1
            return context
        }
        func insertAtCaret(_ text: String, in element: AXUIElement) -> AXBridge.ReplaceResult {
            inserted = text
            insertedAll.append(text)
            return insertResult
        }

        private(set) var replacedRange: NSRange?
        private(set) var replacedText: String?
        func replaceRange(_ range: NSRange, with text: String, in element: AXUIElement) -> AXBridge.ReplaceResult {
            replacedRange = range
            replacedText = text
            return insertResult
        }
    }

    /// A push transport the test drives directly: it records the requests the
    /// controller sends and lets the test deliver suggestions for any `seq`.
    final class MockTransport: SuggestionTransport {
        var onSuggestion: ((UInt64, TransportSuggestion) -> Void)?
        private(set) var requests: [ContextRequest] = []
        private(set) var cancelledSeqs: [UInt64] = []

        func updateContext(_ request: ContextRequest) { requests.append(request) }
        func cancel(seq: UInt64) { cancelledSeqs.append(seq) }
        func stop() {}

        /// Deliver a suggestion as the transport would.
        func push(seq: UInt64, _ text: String, tier: SuggestionTier = .complete) {
            onSuggestion?(seq, TransportSuggestion(tier: tier, text: text, replaceRange: nil))
        }

        var callCount: Int { requests.count }
        var lastSeq: UInt64? { requests.last?.seq }
        var lastPrefix: String? { requests.last?.prefix }
        var lastMaxTokens: Int? { requests.last?.maxTokens }
    }

    final class MockOverlay: GhostTextOverlaying {
        var isVisible = false
        var shownText: String?
        var shownRect: NSRect?
        var showCount = 0

        func show(_ text: String, at caretScreenRect: NSRect) {
            isVisible = true
            shownText = text
            shownRect = caretScreenRect
            showCount += 1
        }

        func hide() { isVisible = false }
    }

    private func makeFocus() -> FocusSnapshot {
        FocusSnapshot(appBundleID: "test", focusedElement: AXUIElementCreateSystemWide())
    }

    private func makeController(ax: MockAX,
                                transport: MockTransport = MockTransport(),
                                overlay: MockOverlay = MockOverlay(),
                                enabled: Bool = true,
                                paused: Bool = false,
                                denied: Set<String> = [],
                                maxTokens: Int = Preferences.SuggestionLength.medium.maxTokens)
        -> AutocompleteController {
        AutocompleteController(
            ax: ax,
            transport: transport,
            overlay: overlay,
            modelProvider: { "qwen2.5:1.5b" },
            enabledProvider: { enabled },
            maxTokensProvider: { maxTokens },
            pausedProvider: { paused },
            deniedAppsProvider: { denied })
    }

    private func contextAt(_ text: String) -> CaretContext {
        CaretContext(textBeforeCaret: text, caretScreenRect: NSRect(x: 10, y: 10, width: 1, height: 18))
    }

    // MARK: - Sending context

    func test_keystrokeSendsOneRequestWithPrefix() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport)

        controller.textChanged()

        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(transport.lastPrefix, "hello")
    }

    func test_eachKeystrokeSendsItsOwnRequest_coalescingIsTheTransportsJob() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport)

        controller.textChanged()
        controller.textChanged()
        controller.textChanged()

        XCTAssertEqual(transport.callCount, 3, "controller sends every keystroke; the transport/engine coalesces")
        XCTAssertEqual(transport.requests.map(\.seq), [1, 2, 3], "seq is monotonic")
    }

    func test_maxTokensFromProviderReachesRequest() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport,
                                        maxTokens: Preferences.SuggestionLength.long.maxTokens)

        controller.textChanged()

        XCTAssertEqual(transport.lastMaxTokens, 32)
    }

    // MARK: - Receiving suggestions

    func test_receiveShowsSuggestionForCurrentSeq() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport(); let overlay = MockOverlay()
        let controller = makeController(ax: ax, transport: transport, overlay: overlay)

        controller.textChanged()
        transport.push(seq: transport.lastSeq!, " world")

        XCTAssertEqual(overlay.shownText, " world")
        XCTAssertTrue(controller.suggestionVisible)
    }

    func test_staleSeqIsIgnored() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport(); let overlay = MockOverlay()
        let controller = makeController(ax: ax, transport: transport, overlay: overlay)

        controller.textChanged() // seq 1
        controller.textChanged() // seq 2 — supersedes
        transport.push(seq: 1, " stale")

        XCTAssertFalse(controller.suggestionVisible, "a suggestion for a superseded seq must not show")
        XCTAssertNil(overlay.shownText)

        transport.push(seq: 2, " fresh")
        XCTAssertEqual(overlay.shownText, " fresh")
        XCTAssertTrue(controller.suggestionVisible)
    }

    func test_emptySuggestionDoesNotShow() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport(); let overlay = MockOverlay()
        let controller = makeController(ax: ax, transport: transport, overlay: overlay)

        controller.textChanged()
        transport.push(seq: transport.lastSeq!, "   ")

        XCTAssertFalse(controller.suggestionVisible)
        XCTAssertNil(overlay.shownText)
    }

    /// Regression for the review's HIGH finding: a keystroke that gets suppressed by a
    /// guard must still supersede prior in-flight work, so a late result for the old
    /// generation can't re-show a ghost over text the user has already changed.
    func test_suppressedKeystrokeDropsStaleInFlightSuggestion() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport(); let overlay = MockOverlay()
        let controller = makeController(ax: ax, transport: transport, overlay: overlay)

        controller.textChanged() // seq 1 sent, "in flight"
        let staleSeq = transport.lastSeq!

        // User clears the field; the next keystroke is suppressed by the empty-text guard.
        ax.context = CaretContext(textBeforeCaret: "   ",
                                  caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        controller.textChanged()
        XCTAssertEqual(transport.callCount, 1, "suppressed keystroke must not send a new request")

        // The seq-1 result lands after the user moved on → must be dropped.
        transport.push(seq: staleSeq, " there")
        XCTAssertFalse(controller.suggestionVisible, "stale suggestion must not re-show after suppression")
        XCTAssertNil(overlay.shownText)
    }

    func test_lowerTierDoesNotRegressHigherTierWithinSeq() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport(); let overlay = MockOverlay()
        let controller = makeController(ax: ax, transport: transport, overlay: overlay)

        controller.textChanged()
        let seq = transport.lastSeq!
        transport.push(seq: seq, " a full sentence", tier: .sentence)
        XCTAssertEqual(overlay.shownText, " a full sentence")

        // A late Tier-0 for the SAME generation must not regress the shown Tier-2.
        transport.push(seq: seq, " word", tier: .complete)
        XCTAssertEqual(overlay.shownText, " a full sentence")
        XCTAssertTrue(controller.suggestionVisible)
    }

    // MARK: - Tier 1 recorrection

    func test_recorrectAcceptReplacesTheWordSpan() {
        let ax = MockAX(); ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "the peple ",
                                  caretScreenRect: NSRect(x: 10, y: 10, width: 1, height: 18))
        let transport = MockTransport(); let overlay = MockOverlay()
        let controller = makeController(ax: ax, transport: transport, overlay: overlay)

        controller.textChanged()
        // The engine sends a recorrection (replaces "peple" → "people").
        transport.push(seq: transport.lastSeq!, "people", tier: .recorrect)
        XCTAssertEqual(overlay.shownText, "people")

        controller.accept()
        // "peple" is UTF-16 range [4, 5-len) in "the peple " → location 4, length 5.
        XCTAssertEqual(ax.replacedRange, NSRange(location: 4, length: 5))
        XCTAssertEqual(ax.replacedText, "people")
        XCTAssertNil(ax.inserted, "a recorrection must replace, not insert at the caret")
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_wordBoundaryPrefixSendsWordBoundaryTrigger() {
        let ax = MockAX(); ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "the peple ",
                                  caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport)

        controller.textChanged()
        XCTAssertEqual(transport.requests.last?.trigger, .wordBoundary)
    }

    func test_midWordPrefixSendsKeystrokeTrigger() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport)

        controller.textChanged()
        XCTAssertEqual(transport.requests.last?.trigger, .keystroke)
    }

    func test_endsAtWordBoundary() {
        XCTAssertTrue(AutocompleteController.endsAtWordBoundary("hello "))
        XCTAssertTrue(AutocompleteController.endsAtWordBoundary("end."))
        XCTAssertFalse(AutocompleteController.endsAtWordBoundary("hello"))
        XCTAssertFalse(AutocompleteController.endsAtWordBoundary("don't"))
        XCTAssertFalse(AutocompleteController.endsAtWordBoundary(""))
    }

    func test_lastCompletedWordUTF16Range() {
        XCTAssertEqual(AutocompleteController.lastCompletedWordUTF16Range(in: "the peple "),
                       NSRange(location: 4, length: 5))
        XCTAssertEqual(AutocompleteController.lastCompletedWordUTF16Range(in: "hello"),
                       NSRange(location: 0, length: 5))
        XCTAssertNil(AutocompleteController.lastCompletedWordUTF16Range(in: "   "))
        XCTAssertNil(AutocompleteController.lastCompletedWordUTF16Range(in: ""))
    }

    func test_higherTierReplacesLowerWithinSeq() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport(); let overlay = MockOverlay()
        let controller = makeController(ax: ax, transport: transport, overlay: overlay)

        controller.textChanged()
        let seq = transport.lastSeq!
        transport.push(seq: seq, " w", tier: .complete)
        XCTAssertEqual(overlay.shownText, " w")
        transport.push(seq: seq, " a full sentence", tier: .sentence)
        XCTAssertEqual(overlay.shownText, " a full sentence", "a higher tier supersedes the displayed one")
    }

    // MARK: - Guards (synchronous: no request sent)

    func test_passwordFieldDoesNotSend() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.password = true; ax.context = contextAt("secret")
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport)

        controller.textChanged()

        XCTAssertEqual(transport.callCount, 0)
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_missingCaretRectDoesNotSend() {
        let ax = MockAX(); ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: nil)
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport)

        controller.textChanged()

        XCTAssertEqual(transport.callCount, 0)
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_disabledStopsBeforeSending() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport, enabled: false)

        controller.textChanged()

        XCTAssertEqual(transport.callCount, 0)
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_pausedDoesNotSend() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport, paused: true)

        controller.textChanged()

        XCTAssertEqual(transport.callCount, 0)
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_deniedAppDoesNotSend() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport, denied: ["test"])

        controller.textChanged()

        XCTAssertEqual(transport.callCount, 0)
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_allowedAppSends() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport, denied: ["some.other.app"])

        controller.textChanged()

        XCTAssertEqual(transport.callCount, 1)
    }

    func test_unsupportedFieldReadOnceThenSkippedUntilFocusChange() {
        let appA = AXUIElementCreateApplication(91)
        let ax = MockAX()
        ax.focus = FocusSnapshot(appBundleID: "test", focusedElement: appA)
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: nil)
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport)

        controller.textChanged()
        controller.textChanged()

        // Second keystroke is served from the unsupported cache — no re-read, no send.
        XCTAssertEqual(ax.readCount, 1)
        XCTAssertEqual(transport.callCount, 0)

        // Focus a different element → cache resets, AX is read again.
        ax.focus = FocusSnapshot(appBundleID: "test", focusedElement: AXUIElementCreateApplication(92))
        controller.textChanged()
        XCTAssertEqual(ax.readCount, 2)
    }

    // MARK: - Accept

    func test_acceptInsertsSingleWordSuggestionAndHides() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("hello")
        let transport = MockTransport(); let overlay = MockOverlay()
        let controller = makeController(ax: ax, transport: transport, overlay: overlay)

        controller.textChanged()
        transport.push(seq: transport.lastSeq!, " there")
        controller.accept()

        XCTAssertEqual(ax.inserted, " there")
        XCTAssertFalse(controller.suggestionVisible)
        XCTAssertFalse(overlay.isVisible)
    }

    func test_wordByWordAcceptInsertsOneWordPerTabThenStops() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("say")
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport)

        controller.textChanged()
        transport.push(seq: transport.lastSeq!, " one two three")

        controller.accept()
        XCTAssertEqual(ax.inserted, " one")
        XCTAssertTrue(controller.suggestionVisible)
        controller.accept()
        XCTAssertEqual(ax.inserted, " two")
        XCTAssertTrue(controller.suggestionVisible)
        controller.accept()
        XCTAssertEqual(ax.inserted, " three")

        XCTAssertEqual(ax.insertedAll, [" one", " two", " three"])
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_pasteFallbackAcceptsRemainderWholeThenStops() {
        let ax = MockAX(); ax.focus = makeFocus(); ax.context = contextAt("say")
        ax.insertResult = .okPaste
        let transport = MockTransport()
        let controller = makeController(ax: ax, transport: transport)

        controller.textChanged()
        transport.push(seq: transport.lastSeq!, " a b c")
        controller.accept()

        // First word via paste, then the rest inserted whole (synthetic Cmd+V can't
        // stay in partial mode), then stop.
        XCTAssertEqual(ax.insertedAll, [" a", " b c"])
        XCTAssertFalse(controller.suggestionVisible)
    }

    // MARK: - Tokenizer

    func test_splitIntoWordTokens_roundTrips() {
        for input in [" world wide web", "hello world", "hi  there", "leading", " ", "trailing ", "a b c"] {
            let tokens = AutocompleteController.splitIntoWordTokens(input)
            XCTAssertEqual(tokens.joined(), input, "round-trip failed for \(input.debugDescription)")
        }
        XCTAssertEqual(AutocompleteController.splitIntoWordTokens(" one two"), [" one", " two"])
        XCTAssertEqual(AutocompleteController.splitIntoWordTokens("hello world"), ["hello", " world"])
    }
}

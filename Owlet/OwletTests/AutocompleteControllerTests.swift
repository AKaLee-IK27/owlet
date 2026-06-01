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
    }

    final class MockPredictor: Predicting, @unchecked Sendable {
        private let lock = NSLock()
        var response = " world"
        var delayNanos: UInt64 = 0
        private(set) var calls: [(prefix: String, mode: SuggestionMode, model: String, maxTokens: Int)] = []

        func suggest(prefix: String, mode: SuggestionMode, model: String, maxTokens: Int) async throws -> String {
            let snapshot = lock.withLock { () -> (UInt64, String) in
                calls.append((prefix, mode, model, maxTokens))
                return (delayNanos, response)
            }
            if snapshot.0 > 0 { try await Task.sleep(nanoseconds: snapshot.0) }
            return snapshot.1
        }

        var lastMode: SuggestionMode? { lock.withLock { calls.last?.mode } }

        var lastMaxTokens: Int? { lock.withLock { calls.last?.maxTokens } }

        var callCount: Int { lock.withLock { calls.count } }
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

        func hide() {
            isVisible = false
        }
    }

    private func makeFocus() -> FocusSnapshot {
        FocusSnapshot(appBundleID: "test", focusedElement: AXUIElementCreateSystemWide())
    }

    func test_debounceCoalescesBursts() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "hello ", caretScreenRect: NSRect(x: 10, y: 10, width: 1, height: 18))
        let predictor = MockPredictor()
        let overlay = MockOverlay()
        let controller = AutocompleteController(
            ax: ax,
            predictor: predictor,
            overlay: overlay,
            modelProvider: { "qwen2.5:1.5b" },
            enabledProvider: { true }
        )

        controller.textChanged()
        controller.textChanged()
        controller.textChanged()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(predictor.callCount, 1)
        XCTAssertEqual(overlay.shownText, " world")
        XCTAssertTrue(controller.suggestionVisible)
    }

    func test_passwordFieldDoesNotPredict() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.password = true
        ax.context = CaretContext(textBeforeCaret: "secret", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        let controller = AutocompleteController(ax: ax, predictor: predictor, enabledProvider: { true })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(predictor.callCount, 0)
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_missingCaretRectDoesNotPredict() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: nil)
        let predictor = MockPredictor()
        let controller = AutocompleteController(ax: ax, predictor: predictor, enabledProvider: { true })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(predictor.callCount, 0)
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_acceptInsertsCurrentSuggestionAndHides() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "hello ", caretScreenRect: NSRect(x: 10, y: 10, width: 1, height: 18))
        let predictor = MockPredictor()
        predictor.response = " there"
        let overlay = MockOverlay()
        let controller = AutocompleteController(ax: ax, predictor: predictor, overlay: overlay, enabledProvider: { true })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 250_000_000)
        controller.accept()

        XCTAssertEqual(ax.inserted, " there")
        XCTAssertFalse(controller.suggestionVisible)
        XCTAssertFalse(overlay.isVisible)
    }

    func test_disabledPreferenceStopsBeforePredicting() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        let controller = AutocompleteController(ax: ax, predictor: predictor, enabledProvider: { false })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(predictor.callCount, 0)
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_maxTokensFromProviderReachesPredictor() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        let controller = AutocompleteController(
            ax: ax,
            predictor: predictor,
            enabledProvider: { true },
            maxTokensProvider: { Preferences.SuggestionLength.long.maxTokens }
        )

        controller.textChanged()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(predictor.lastMaxTokens, 32)
    }

    func test_pausedDoesNotPredict() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        let controller = AutocompleteController(
            ax: ax,
            predictor: predictor,
            enabledProvider: { true },
            pausedProvider: { true }
        )

        controller.textChanged()
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(predictor.callCount, 0)
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_deniedAppDoesNotPredict() async throws {
        let ax = MockAX()
        ax.focus = makeFocus() // appBundleID == "test"
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        let controller = AutocompleteController(
            ax: ax,
            predictor: predictor,
            enabledProvider: { true },
            deniedAppsProvider: { ["test"] }
        )

        controller.textChanged()
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(predictor.callCount, 0)
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_allowedAppPredicts() async throws {
        let ax = MockAX()
        ax.focus = makeFocus() // appBundleID == "test"
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        let controller = AutocompleteController(
            ax: ax,
            predictor: predictor,
            enabledProvider: { true },
            deniedAppsProvider: { ["some.other.app"] }
        )

        controller.textChanged()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(predictor.callCount, 1)
    }

    func test_unsupportedFieldReadOnceThenSkippedUntilFocusChange() async throws {
        // Field returns text but no caret bounds → unsupported.
        let appA = AXUIElementCreateApplication(91)
        let ax = MockAX()
        ax.focus = FocusSnapshot(appBundleID: "test", focusedElement: appA)
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: nil)
        let predictor = MockPredictor()
        let controller = AutocompleteController(ax: ax, predictor: predictor, enabledProvider: { true })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 180_000_000)
        controller.textChanged()
        try await Task.sleep(nanoseconds: 180_000_000)

        // Second keystroke is served from the unsupported cache — no re-read.
        XCTAssertEqual(ax.readCount, 1)
        XCTAssertEqual(predictor.callCount, 0)

        // Focus a different element → cache resets, AX is read again.
        ax.focus = FocusSnapshot(appBundleID: "test", focusedElement: AXUIElementCreateApplication(92))
        controller.textChanged()
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(ax.readCount, 2)
    }

    func test_splitIntoWordTokens_roundTrips() {
        for input in [" world wide web", "hello world", "hi  there", "leading", " ", "trailing ", "a b c"] {
            let tokens = AutocompleteController.splitIntoWordTokens(input)
            XCTAssertEqual(tokens.joined(), input, "round-trip failed for \(input.debugDescription)")
        }
        XCTAssertEqual(AutocompleteController.splitIntoWordTokens(" one two"), [" one", " two"])
        XCTAssertEqual(AutocompleteController.splitIntoWordTokens("hello world"), ["hello", " world"])
    }

    func test_detectMode_trailingLetterOrDigitIsWordCompletion() {
        XCTAssertEqual(AutocompleteController.detectMode(textBeforeCaret: "I am writ"), .wordCompletion)
        XCTAssertEqual(AutocompleteController.detectMode(textBeforeCaret: "abc123"), .wordCompletion)
        XCTAssertEqual(AutocompleteController.detectMode(textBeforeCaret: "x"), .wordCompletion)
    }

    func test_detectMode_trailingWhitespacePunctuationOrEmptyIsContinuation() {
        XCTAssertEqual(AutocompleteController.detectMode(textBeforeCaret: "I am "), .continuation)
        XCTAssertEqual(AutocompleteController.detectMode(textBeforeCaret: "Hello."), .continuation)
        XCTAssertEqual(AutocompleteController.detectMode(textBeforeCaret: "done,"), .continuation)
        XCTAssertEqual(AutocompleteController.detectMode(textBeforeCaret: "line\n"), .continuation)
        XCTAssertEqual(AutocompleteController.detectMode(textBeforeCaret: ""), .continuation)
    }

    func test_cleanSuggestion_wordCompletionStripsLeadingWhitespace() {
        XCTAssertEqual(AutocompleteController.cleanSuggestion(" ing", prefix: "I am writ", mode: .wordCompletion), "ing")
        XCTAssertEqual(AutocompleteController.cleanSuggestion("ing", prefix: "I am writ", mode: .wordCompletion), "ing")
        // A bare-space response collapses to nil rather than an empty ghost.
        XCTAssertNil(AutocompleteController.cleanSuggestion("   ", prefix: "x", mode: .wordCompletion))
    }

    func test_cleanSuggestion_continuationPreservesLeadingSpace() {
        XCTAssertEqual(AutocompleteController.cleanSuggestion(" world", prefix: "hello", mode: .continuation), " world")
    }

    func test_continuationModePassedAfterTrailingSpace() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "I am ", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        let controller = AutocompleteController(ax: ax, predictor: predictor, enabledProvider: { true })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(predictor.lastMode, .continuation)
    }

    func test_wordCompletionModePassedMidWord() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "I am writ", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        predictor.response = "ing"
        let controller = AutocompleteController(ax: ax, predictor: predictor, enabledProvider: { true })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(predictor.lastMode, .wordCompletion)
    }

    func test_wordByWordAcceptInsertsOneWordPerTabThenStops() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "say ", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        predictor.response = " one two three"
        let controller = AutocompleteController(ax: ax, predictor: predictor, enabledProvider: { true })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 250_000_000)

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

    func test_pasteFallbackAcceptsWholeSuggestionAtOnce() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "say ", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        ax.insertResult = .okPaste
        let predictor = MockPredictor()
        predictor.response = " a b c"
        let controller = AutocompleteController(ax: ax, predictor: predictor, enabledProvider: { true })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 250_000_000)

        controller.accept()
        // First word pasted, then the remainder pasted whole; no partial mode.
        XCTAssertEqual(ax.insertedAll, [" a", " b c"])
        XCTAssertFalse(controller.suggestionVisible)
    }

    func test_supersededPredictionDoesNotShowStaleResult() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "first ", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        predictor.delayNanos = 180_000_000
        predictor.response = " stale"
        let overlay = MockOverlay()
        let controller = AutocompleteController(ax: ax, predictor: predictor, overlay: overlay, enabledProvider: { true })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 150_000_000) // first request has started
        ax.context = CaretContext(textBeforeCaret: "second ", caretScreenRect: NSRect(x: 5, y: 5, width: 1, height: 18))
        predictor.response = " fresh"
        predictor.delayNanos = 0
        controller.textChanged()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(overlay.shownText, " fresh")
        XCTAssertEqual(overlay.showCount, 1)
    }
}

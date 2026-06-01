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

        func currentFocus() -> FocusSnapshot? { focus }
        func isPasswordField(_ element: AXUIElement) -> Bool { password }
        func readCaretContext(from element: AXUIElement) -> CaretContext? { context }
        func insertAtCaret(_ text: String, in element: AXUIElement) -> AXBridge.ReplaceResult {
            inserted = text
            return .okAX
        }
    }

    final class MockPredictor: Predicting, @unchecked Sendable {
        private let lock = NSLock()
        var response = " world"
        var delayNanos: UInt64 = 0
        private(set) var calls: [(prefix: String, model: String, maxTokens: Int)] = []

        func suggest(prefix: String, model: String, maxTokens: Int) async throws -> String {
            let snapshot = lock.withLock { () -> (UInt64, String) in
                calls.append((prefix, model, maxTokens))
                return (delayNanos, response)
            }
            if snapshot.0 > 0 { try await Task.sleep(nanoseconds: snapshot.0) }
            return snapshot.1
        }

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
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: NSRect(x: 10, y: 10, width: 1, height: 18))
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
        ax.context = CaretContext(textBeforeCaret: "hello", caretScreenRect: NSRect(x: 10, y: 10, width: 1, height: 18))
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

    func test_supersededPredictionDoesNotShowStaleResult() async throws {
        let ax = MockAX()
        ax.focus = makeFocus()
        ax.context = CaretContext(textBeforeCaret: "first", caretScreenRect: NSRect(x: 0, y: 0, width: 1, height: 18))
        let predictor = MockPredictor()
        predictor.delayNanos = 180_000_000
        predictor.response = " stale"
        let overlay = MockOverlay()
        let controller = AutocompleteController(ax: ax, predictor: predictor, overlay: overlay, enabledProvider: { true })

        controller.textChanged()
        try await Task.sleep(nanoseconds: 150_000_000) // first request has started
        ax.context = CaretContext(textBeforeCaret: "second", caretScreenRect: NSRect(x: 5, y: 5, width: 1, height: 18))
        predictor.response = " fresh"
        predictor.delayNanos = 0
        controller.textChanged()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(overlay.shownText, " fresh")
        XCTAssertEqual(overlay.showCount, 1)
    }
}

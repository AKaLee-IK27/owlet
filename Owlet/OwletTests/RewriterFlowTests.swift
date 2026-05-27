import XCTest
import ApplicationServices
@testable import Owlet

final class RewriterFlowTests: XCTestCase {

    final class MockAX: AXBridging {
        var outcome: CaptureOutcome = .noFocus
        var replaceResult: AXBridge.ReplaceResult = .okAX
        var replaceCallCount = 0
        func capture() -> CaptureOutcome { outcome }
        func replaceSelection(_ text: String, in element: AXUIElement) -> AXBridge.ReplaceResult {
            replaceCallCount += 1
            return replaceResult
        }
    }

    final class MockRewriter: Rewriting, @unchecked Sendable {
        var response: Result<String, Error> = .success("rewritten")
        var callCount = 0
        func rewrite(_ input: String) async throws -> String {
            callCount += 1
            return try response.get()
        }
    }

    @MainActor
    func test_emptySelection_setsErrorStateSelectionEmpty() async {
        let ax = MockAX()
        ax.outcome = .empty
        let flow = RewriterFlow(ax: ax, rewriter: MockRewriter(), popup: PopupWindowController())
        await flow.start()
        XCTAssertEqual(flow.lastObservedState, .error(.selectionEmpty))
    }

    @MainActor
    func test_noFocus_setsErrorStateSelectionEmpty() async {
        let ax = MockAX()
        ax.outcome = .noFocus
        let flow = RewriterFlow(ax: ax, rewriter: MockRewriter(), popup: PopupWindowController())
        await flow.start()
        XCTAssertEqual(flow.lastObservedState, .error(.selectionEmpty))
    }

    @MainActor
    func test_inputTooLong_hardRejects() async {
        let ax = MockAX()
        let bogusElement = unsafeBitCast(0, to: AXUIElement.self)   // not used in this path
        ax.outcome = .captured(SelectionSnapshot(
            text: String(repeating: "a", count: 17_000),
            sourceAppBundleID: "test", focusedElement: bogusElement,
            captureMethod: .ax
        ))
        let rewriter = MockRewriter()
        let flow = RewriterFlow(ax: ax, rewriter: rewriter, popup: PopupWindowController())
        await flow.start()
        XCTAssertEqual(rewriter.callCount, 0, "should reject before calling rewriter")
        if case .error(.inputTooLong(let c)) = flow.lastObservedState {
            XCTAssertEqual(c, 17_000)
        } else { XCTFail("expected inputTooLong, got \(String(describing: flow.lastObservedState))") }
    }

    @MainActor
    func test_emptyRewriteOutput_emptyState() async {
        let ax = MockAX()
        let bogusElement = unsafeBitCast(0, to: AXUIElement.self)
        ax.outcome = .captured(SelectionSnapshot(text: "hello", sourceAppBundleID: "t",
                                        focusedElement: bogusElement, captureMethod: .ax))
        let rewriter = MockRewriter()
        rewriter.response = .success("hello")        // identical → empty state
        let flow = RewriterFlow(ax: ax, rewriter: rewriter, popup: PopupWindowController())
        await flow.start()
        if case .empty(let t) = flow.lastObservedState { XCTAssertEqual(t, "hello") }
        else { XCTFail("expected .empty, got \(String(describing: flow.lastObservedState))") }
    }

    @MainActor
    func test_happyPath_setsResultStateWithDiff() async {
        let ax = MockAX()
        let bogusElement = unsafeBitCast(0, to: AXUIElement.self)
        ax.outcome = .captured(SelectionSnapshot(text: "the cat sat", sourceAppBundleID: "t",
                                        focusedElement: bogusElement, captureMethod: .ax))
        let rewriter = MockRewriter()
        rewriter.response = .success("the dog sat")
        let flow = RewriterFlow(ax: ax, rewriter: rewriter, popup: PopupWindowController())
        await flow.start()
        if case .result(_, let new, let segs, let canReplace) = flow.lastObservedState {
            XCTAssertEqual(new, "the dog sat")
            XCTAssertNotNil(segs)
            XCTAssertTrue(canReplace)
        } else { XCTFail("expected .result, got \(String(describing: flow.lastObservedState))") }
    }

    @MainActor
    func test_ollamaUnreachable_errorOllamaDown() async {
        let ax = MockAX()
        let bogusElement = unsafeBitCast(0, to: AXUIElement.self)
        ax.outcome = .captured(SelectionSnapshot(text: "x", sourceAppBundleID: "t",
                                        focusedElement: bogusElement, captureMethod: .ax))
        let rewriter = MockRewriter()
        rewriter.response = .failure(OllamaClient.Failure.backendError("ConnectionError"))
        let flow = RewriterFlow(ax: ax, rewriter: rewriter, popup: PopupWindowController())
        await flow.start()
        if case .error(let k) = flow.lastObservedState {
            XCTAssertTrue(k == .ollamaDown || k == .backendUnavailable(message: "ConnectionError"))
        } else { XCTFail("expected .error, got \(String(describing: flow.lastObservedState))") }
    }

    @MainActor
    func test_passwordField_setsErrorPasswordField() async {
        let ax = MockAX()
        ax.outcome = .passwordField
        let flow = RewriterFlow(ax: ax, rewriter: MockRewriter(), popup: PopupWindowController())
        await flow.start()
        XCTAssertEqual(flow.lastObservedState, .error(.passwordField))
    }

    @MainActor
    func test_capture_withNilFocus_clipboardOnly() async {
        // Simulates an Electron app: AX gives no focus, but Hammerspoon
        // already put the selection on the clipboard.
        let ax = MockAX()
        ax.outcome = .captured(SelectionSnapshot(
            text: "captured via clipboard",
            sourceAppBundleID: "com.example.electron",
            focusedElement: nil,
            captureMethod: .clipboardFallback
        ))
        let rewriter = MockRewriter()
        rewriter.response = .success("Captured via clipboard.")
        let flow = RewriterFlow(ax: ax, rewriter: rewriter, popup: PopupWindowController())
        await flow.start()
        if case .result(_, _, _, let canReplace) = flow.lastObservedState {
            XCTAssertTrue(canReplace, "canReplace stays true; handleReplace falls back to clipboard write")
        } else {
            XCTFail("expected .result, got \(String(describing: flow.lastObservedState))")
        }
    }
}

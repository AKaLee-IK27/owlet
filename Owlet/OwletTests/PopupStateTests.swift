import XCTest
@testable import Owlet

final class PopupStateTests: XCTestCase {

    func test_loading_isLongFlag_setByLength() {
        let short = PopupState.loading(sourceText: "hi", isLong: false)
        let long = PopupState.loading(sourceText: String(repeating: "a", count: 4001), isLong: true)
        if case .loading(_, let isLong, _) = short { XCTAssertFalse(isLong) } else { XCTFail() }
        if case .loading(_, let isLong, _) = long { XCTAssertTrue(isLong) } else { XCTFail() }
    }

    func test_result_canReplaceFalse_whenOutputTooLong() {
        let s = PopupState.result(original: "x", rewritten: "y", segments: nil, canReplace: false)
        if case .result(_, _, _, let canReplace, _) = s { XCTAssertFalse(canReplace) } else { XCTFail() }
    }

    func test_empty_carriesText() {
        let s = PopupState.empty(text: "looks good")
        if case .empty(let t) = s { XCTAssertEqual(t, "looks good") } else { XCTFail() }
    }

    func test_error_kindRoundtrip() {
        let kinds: [ErrorKind] = [.ollamaDown, .timeout, .emptyOutput, .inputTooLong(charCount: 17000),
                                   .focusLost, .axDenied, .backendUnavailable(message: "boom"),
                                   .selectionEmpty, .passwordField, .selectionUnreadable]
        for k in kinds {
            let s = PopupState.error(k)
            if case .error(let got) = s { XCTAssertEqual(String(describing: got), String(describing: k)) } else { XCTFail() }
        }
    }

    func test_loading_carriesCaptureMethod_ax() {
        let s = PopupState.loading(sourceText: "hello", isLong: false, captureMethod: .ax)
        if case .loading(_, _, let method) = s { XCTAssertEqual(method, .ax) } else { XCTFail() }
    }

    func test_loading_carriesCaptureMethod_clipboard() {
        let s = PopupState.loading(sourceText: "hello", isLong: false, captureMethod: .clipboardFallback)
        if case .loading(_, _, let method) = s { XCTAssertEqual(method, .clipboardFallback) } else { XCTFail() }
    }

    func test_result_carriesCaptureMethod_clipboard() {
        let s = PopupState.result(original: "x", rewritten: "y", segments: nil, canReplace: true, captureMethod: .clipboardFallback)
        if case .result(_, _, _, _, let method) = s { XCTAssertEqual(method, .clipboardFallback) } else { XCTFail() }
    }
}

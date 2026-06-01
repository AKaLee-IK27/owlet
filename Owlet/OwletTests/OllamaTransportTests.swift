import XCTest
@testable import Owlet

@MainActor
final class OllamaTransportTests: XCTestCase {

    final class StubPredictor: Predicting, @unchecked Sendable {
        private let lock = NSLock()
        private var _response = "hello world"
        private var _calls = 0
        var response: String {
            get { lock.withLock { _response } }
            set { lock.withLock { _response = newValue } }
        }
        var callCount: Int { lock.withLock { _calls } }

        func suggest(prefix: String, model: String, maxTokens: Int) async throws -> String {
            lock.withLock { _calls += 1; return _response }
        }
    }

    private func req(seq: UInt64, prefix: String) -> ContextRequest {
        ContextRequest(seq: seq, prefix: prefix, suffix: "", appID: "t",
                       trigger: .keystroke, model: "m", maxTokens: 18)
    }

    // MARK: - Output cleanup (synchronous)

    func test_clean_stripsPrefixEcho() {
        XCTAssertEqual(OllamaTransport.clean("hello world", prefix: "hello"), " world")
    }

    func test_clean_stripsWrappingQuotes() {
        XCTAssertEqual(OllamaTransport.clean("\"hi there\"", prefix: "x"), "hi there")
    }

    func test_clean_dropsEmpty() {
        XCTAssertNil(OllamaTransport.clean("   ", prefix: ""))
        XCTAssertNil(OllamaTransport.clean("\n\n", prefix: ""))
    }

    func test_clean_preservesLeadingSpace() {
        XCTAssertEqual(OllamaTransport.clean(" world", prefix: "hello"), " world")
    }

    // MARK: - Debounce + push (async)

    func test_debounceCoalescesRapidUpdatesToOnePredictorCall() async {
        let predictor = StubPredictor()
        predictor.response = "hello world"
        let transport = OllamaTransport(predictor: predictor, debounceNanos: 30_000_000)
        let exp = expectation(description: "one suggestion")
        var pushedSeq: UInt64?
        var pushedText: String?
        transport.onSuggestion = { seq, suggestion in
            pushedSeq = seq; pushedText = suggestion.text; exp.fulfill()
        }

        transport.updateContext(req(seq: 1, prefix: "hello"))
        transport.updateContext(req(seq: 2, prefix: "hello"))
        transport.updateContext(req(seq: 3, prefix: "hello"))

        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertEqual(predictor.callCount, 1, "only the last update should survive the debounce")
        XCTAssertEqual(pushedSeq, 3)
        XCTAssertEqual(pushedText, " world", "prefix echo stripped, leading space preserved")
    }

    func test_cancelBeforeDebounceElapsesPreventsPush() async {
        let predictor = StubPredictor()
        let transport = OllamaTransport(predictor: predictor, debounceNanos: 80_000_000)
        let exp = expectation(description: "no push")
        exp.isInverted = true
        transport.onSuggestion = { _, _ in exp.fulfill() }

        transport.updateContext(req(seq: 1, prefix: "hello"))
        transport.cancel(seq: 1)

        await fulfillment(of: [exp], timeout: 0.3)
        XCTAssertEqual(predictor.callCount, 0, "cancel before the debounce fires must skip the network call")
    }
}

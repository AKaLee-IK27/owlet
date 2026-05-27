import XCTest
@testable import Owlet

@MainActor
final class CommandDispatcherTests: XCTestCase {
    func test_dispatchRewrite_returnsRewriterFlowTag() {
        let flow = CommandDispatcher.flow(for: .rewrite)
        XCTAssertEqual(flow.tag, "rewriter")
    }
    func test_dispatchTranslate_returnsUnavailableFlow() {
        let flow = CommandDispatcher.flow(for: .translate)
        XCTAssertEqual(flow.tag, "unavailable")
    }
    func test_dispatchUnknown_returnsUnavailableFlow() {
        let flow = CommandDispatcher.flow(for: .unknown(verb: "wibble"))
        XCTAssertEqual(flow.tag, "unavailable")
    }
}

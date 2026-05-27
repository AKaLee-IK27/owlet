import XCTest
@testable import Owlet

final class CleanOutputTests: XCTestCase {

    func test_stripsThinkBlock() {
        let input = "<think>internal monologue\nspans lines</think>\nactual output"
        XCTAssertEqual(CleanOutput.clean(input), "actual output")
    }

    func test_stripsMatchedDoubleQuotes() {
        XCTAssertEqual(CleanOutput.clean("\"hello\""), "hello")
    }

    func test_stripsMatchedSingleQuotes() {
        XCTAssertEqual(CleanOutput.clean("'hi there'"), "hi there")
    }

    func test_doesNotStripUnmatchedQuotes() {
        XCTAssertEqual(CleanOutput.clean("\"hi\" and \"bye\""), "\"hi\" and \"bye\"")
        XCTAssertEqual(CleanOutput.clean("Translate \"x\" please"), "Translate \"x\" please")
    }

    func test_handlesEmpty() {
        XCTAssertEqual(CleanOutput.clean(""), "")
        XCTAssertEqual(CleanOutput.clean("\"\""), "")
    }

    func test_thinkAndQuotesCombined() {
        let input = "<think>thinking</think>\n\"the answer\""
        XCTAssertEqual(CleanOutput.clean(input), "the answer")
    }
}

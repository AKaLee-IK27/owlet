import XCTest
@testable import Owlet

final class URLSchemeTests: XCTestCase {

    func test_parsesRewriteVerb() {
        let url = URL(string: "owlet://rewrite")!
        XCTAssertEqual(URLSchemeParser.parse(url), .rewrite)
    }

    func test_parsesTranslateVerb() {
        let url = URL(string: "owlet://translate")!
        XCTAssertEqual(URLSchemeParser.parse(url), .translate)
    }

    func test_parsesGrammarVerb() {
        let url = URL(string: "owlet://grammar")!
        XCTAssertEqual(URLSchemeParser.parse(url), .grammar)
    }

    func test_unknownVerb() {
        let url = URL(string: "owlet://wibble")!
        XCTAssertEqual(URLSchemeParser.parse(url), .unknown(verb: "wibble"))
    }

    func test_wrongScheme() {
        let url = URL(string: "http://rewrite")!
        XCTAssertNil(URLSchemeParser.parse(url))
    }

    func test_missingHost() {
        let url = URL(string: "owlet://")!
        XCTAssertNil(URLSchemeParser.parse(url))
    }
}

import XCTest
@testable import Owlet

final class ChordMatcherTests: XCTestCase {

    func test_exactChord_matches() {
        let flags = ModifierFlags(fn: true, ctrl: true, cmd: false, alt: false, shift: false)
        XCTAssertTrue(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_missingFn_doesNotMatch() {
        let flags = ModifierFlags(fn: false, ctrl: true, cmd: false, alt: false, shift: false)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_missingCtrl_doesNotMatch() {
        let flags = ModifierFlags(fn: true, ctrl: false, cmd: false, alt: false, shift: false)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_extraCmd_doesNotMatch() {
        let flags = ModifierFlags(fn: true, ctrl: true, cmd: true, alt: false, shift: false)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_extraShift_doesNotMatch() {
        let flags = ModifierFlags(fn: true, ctrl: true, cmd: false, alt: false, shift: true)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_extraAlt_doesNotMatch() {
        let flags = ModifierFlags(fn: true, ctrl: true, cmd: false, alt: true, shift: false)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_wrongKey_doesNotMatch() {
        let flags = ModifierFlags(fn: true, ctrl: true, cmd: false, alt: false, shift: false)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "t", flags: flags))
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "", flags: flags))
    }
}

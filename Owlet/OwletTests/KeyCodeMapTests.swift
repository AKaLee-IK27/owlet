import XCTest
import Carbon.HIToolbox
@testable import Owlet

final class KeyCodeMapTests: XCTestCase {

    func test_lookup_letters() {
        XCTAssertEqual(KeyCodeMap.name(for: Int(kVK_ANSI_R)), "r")
        XCTAssertEqual(KeyCodeMap.name(for: Int(kVK_ANSI_J)), "j")
        XCTAssertEqual(KeyCodeMap.name(for: Int(kVK_ANSI_A)), "a")
    }

    func test_lookup_named_keys() {
        XCTAssertEqual(KeyCodeMap.name(for: Int(kVK_Space)), "space")
        XCTAssertEqual(KeyCodeMap.name(for: Int(kVK_Return)), "return")
        XCTAssertEqual(KeyCodeMap.name(for: Int(kVK_Escape)), "escape")
    }

    func test_lookup_function_keys() {
        XCTAssertEqual(KeyCodeMap.name(for: Int(kVK_F1)), "f1")
        XCTAssertEqual(KeyCodeMap.name(for: Int(kVK_F12)), "f12")
    }

    func test_unknown_keycode_returns_nil() {
        XCTAssertNil(KeyCodeMap.name(for: 999))
    }

    func test_reverse_lookup_letters() {
        XCTAssertEqual(KeyCodeMap.keyCode(for: "r"), Int(kVK_ANSI_R))
        XCTAssertEqual(KeyCodeMap.keyCode(for: "space"), Int(kVK_Space))
    }

    func test_reverse_lookup_unknown_returns_nil() {
        XCTAssertNil(KeyCodeMap.keyCode(for: "zzz"))
    }

    func test_round_trip_every_entry() {
        for (code, name) in KeyCodeMap.allEntries {
            XCTAssertEqual(KeyCodeMap.name(for: code), name, "name(for: \(code)) should yield \(name)")
            XCTAssertEqual(KeyCodeMap.keyCode(for: name), code, "keyCode(for: \(name)) should yield \(code)")
        }
    }
}

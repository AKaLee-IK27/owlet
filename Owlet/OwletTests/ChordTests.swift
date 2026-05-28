import XCTest
@testable import Owlet

final class ChordTests: XCTestCase {

    func test_default_isOptionSpace() {
        let c = Chord.default
        XCTAssertEqual(c.keyCode, 49) // kVK_Space
        XCTAssertTrue(c.modifiers.alt)
        XCTAssertFalse(c.modifiers.cmd)
        XCTAssertFalse(c.modifiers.ctrl)
        XCTAssertFalse(c.modifiers.shift)
        XCTAssertFalse(c.modifiers.fn)
    }

    func test_displayString_optionSpace() {
        XCTAssertEqual(Chord.default.displayString, "⌥ Space")
    }

    func test_displayString_cmdShiftJ() {
        let mods = ModifierFlags(fn: false, ctrl: false, cmd: true, alt: false, shift: true)
        let c = Chord(keyCode: 38, modifiers: mods)
        XCTAssertEqual(c.displayString, "⇧⌘J")
    }

    func test_displayString_ctrlOptionR() {
        let mods = ModifierFlags(fn: false, ctrl: true, cmd: false, alt: true, shift: false)
        let c = Chord(keyCode: 15, modifiers: mods)
        XCTAssertEqual(c.displayString, "⌃⌥R")
    }

    func test_codable_roundtrips() throws {
        let mods = ModifierFlags(fn: true, ctrl: true, cmd: false, alt: false, shift: false)
        let c = Chord(keyCode: 15, modifiers: mods)
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(Chord.self, from: data)
        XCTAssertEqual(decoded, c)
    }

    func test_equality() {
        let mods = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        XCTAssertEqual(Chord(keyCode: 49, modifiers: mods), Chord(keyCode: 49, modifiers: mods))
        XCTAssertNotEqual(Chord(keyCode: 49, modifiers: mods), Chord(keyCode: 50, modifiers: mods))
    }
}

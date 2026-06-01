import XCTest
@testable import Owlet

/// Tests for `HotkeyEventTap.decideModifierAction` — the bare-modifier
/// transition logic that drives double-tap-Shift and Option-hold. These
/// transitions only ever arrive via `flagsChanged`, which is why detecting
/// them in the `keyDown` branch (the original bug) never fired.
final class HotkeyEventTapTests: XCTestCase {

    private let none = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: false, shift: false)
    private let shift = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: false, shift: true)
    private let option = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
    private let optionShift = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: true)
    private let cmdShift = ModifierFlags(fn: false, ctrl: false, cmd: true, alt: false, shift: true)

    private func makeTap() -> HotkeyEventTap {
        let chord = Chord(keyCode: 49, modifiers: none) // Space, no modifiers
        return HotkeyEventTap(chord: chord, onHotkey: {})
    }

    // MARK: - Double-tap Shift

    func test_shiftTappedTwiceWithinThreshold_firesDoubleClick() {
        let tap = makeTap()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(tap.decideModifierAction(flags: shift, now: t0), .none)                 // press 1
        XCTAssertEqual(tap.decideModifierAction(flags: none, now: t0.addingTimeInterval(0.05)), .none) // release 1
        XCTAssertEqual(tap.decideModifierAction(flags: shift, now: t0.addingTimeInterval(0.2)), .doubleClickShift) // press 2
    }

    func test_shiftTappedTwiceTooSlowly_doesNotFire() {
        let tap = makeTap()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(tap.decideModifierAction(flags: shift, now: t0), .none)
        XCTAssertEqual(tap.decideModifierAction(flags: none, now: t0.addingTimeInterval(0.05)), .none)
        // 0.5s > 0.4s threshold → treated as a fresh first tap, not a double-click.
        XCTAssertEqual(tap.decideModifierAction(flags: shift, now: t0.addingTimeInterval(0.5)), .none)
    }

    func test_shiftStillHeld_doesNotCountAsNewTap() {
        let tap = makeTap()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(tap.decideModifierAction(flags: shift, now: t0), .none)
        // Another flagsChanged while shift is still down (e.g. a second modifier
        // is added) is not an absent→present transition, so no double-click.
        XCTAssertEqual(tap.decideModifierAction(flags: cmdShift, now: t0.addingTimeInterval(0.1)), .none)
    }

    func test_shiftWithOtherModifier_isNotACleanTap() {
        let tap = makeTap()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        // Shift+Cmd pressed together is a chord modifier, not a bare-Shift tap.
        XCTAssertEqual(tap.decideModifierAction(flags: cmdShift, now: t0), .none)
        XCTAssertEqual(tap.decideModifierAction(flags: none, now: t0.addingTimeInterval(0.05)), .none)
        XCTAssertEqual(tap.decideModifierAction(flags: cmdShift, now: t0.addingTimeInterval(0.1)), .none)
    }

    // MARK: - Option hold

    func test_optionPressedAlone_startsHold() {
        let tap = makeTap()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(tap.decideModifierAction(flags: option, now: t0), .startOptionHold)
    }

    func test_optionReleased_cancelsHold() {
        let tap = makeTap()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(tap.decideModifierAction(flags: option, now: t0), .startOptionHold)
        XCTAssertEqual(tap.decideModifierAction(flags: none, now: t0.addingTimeInterval(0.1)), .cancelOptionHold)
    }

    func test_optionWithOtherModifier_doesNotStartHold() {
        let tap = makeTap()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        // Option+Shift together is not a bare-Option hold.
        XCTAssertEqual(tap.decideModifierAction(flags: optionShift, now: t0), .none)
    }

    // MARK: - Autocomplete key handling

    func test_tabPassesThroughWhenNoSuggestionVisible() {
        let tap = makeTap()
        XCTAssertEqual(
            tap.decideKeyDownAction(keyCode: 48, keyName: "Tab", flags: none),
            .passThrough
        )
    }

    func test_tabAcceptsOnlyWhenSuggestionVisible() {
        let tap = makeTap()
        tap.setAutocompleteSuggestionVisible(true)
        XCTAssertEqual(
            tap.decideKeyDownAction(keyCode: 48, keyName: "Tab", flags: none),
            .acceptAutocomplete
        )
    }

    func test_escapeDismissesOnlyWhenSuggestionVisible() {
        let tap = makeTap()
        XCTAssertEqual(
            tap.decideKeyDownAction(keyCode: 53, keyName: "Escape", flags: none),
            .passThrough
        )
        tap.setAutocompleteSuggestionVisible(true)
        XCTAssertEqual(
            tap.decideKeyDownAction(keyCode: 53, keyName: "Escape", flags: none),
            .dismissAutocomplete
        )
    }

    func test_printableKeyNotifiesTextChanged() {
        let tap = makeTap()
        XCTAssertEqual(
            tap.decideKeyDownAction(keyCode: 0, keyName: "A", flags: none),
            .passThroughAndNotifyTextChanged
        )
    }

    func test_printableKeyDismissesVisibleSuggestionAndNotifiesTextChanged() {
        let tap = makeTap()
        tap.setAutocompleteSuggestionVisible(true)
        XCTAssertEqual(
            tap.decideKeyDownAction(keyCode: 0, keyName: "A", flags: none),
            .passThroughDismissAndNotifyTextChanged
        )
    }

    func test_chordStillFiresWhenSuggestionVisible() {
        let tap = makeTap()
        tap.setAutocompleteSuggestionVisible(true)
        XCTAssertEqual(
            tap.decideKeyDownAction(keyCode: 49, keyName: "space", flags: none),
            .fireHotkey
        )
    }

    func test_commandShortcutDoesNotNotifyTextChanged() {
        let tap = makeTap()
        let command = ModifierFlags(fn: false, ctrl: false, cmd: true, alt: false, shift: false)
        XCTAssertEqual(
            tap.decideKeyDownAction(keyCode: 8, keyName: "C", flags: command),
            .passThrough
        )
    }
}

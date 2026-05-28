import XCTest
@testable import Owlet

final class PreferencesTests: XCTestCase {

    /// Each test uses an isolated UserDefaults suite so we don't trample
    /// the developer's real Owlet defaults during `xcodebuild test`.
    private var defaults: UserDefaults!
    private let suiteName = "co.greenpassport.owlet.tests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_defaults_on_first_read() {
        let p = Preferences(defaults: defaults)
        XCTAssertEqual(p.hotkey, .default)
        XCTAssertEqual(p.model, "qwen3:8b")
        XCTAssertTrue(p.launchAtLogin)
    }

    func test_hotkey_roundtrip() {
        let p = Preferences(defaults: defaults)
        let mods = ModifierFlags(fn: false, ctrl: true, cmd: false, alt: false, shift: true)
        let chord = Chord(keyCode: 38, modifiers: mods)
        p.hotkey = chord

        let p2 = Preferences(defaults: defaults)
        XCTAssertEqual(p2.hotkey, chord)
    }

    func test_model_roundtrip() {
        let p = Preferences(defaults: defaults)
        p.model = "llama3.1:8b"
        let p2 = Preferences(defaults: defaults)
        XCTAssertEqual(p2.model, "llama3.1:8b")
    }

    func test_launchAtLogin_roundtrip() {
        let p = Preferences(defaults: defaults)
        p.launchAtLogin = false
        let p2 = Preferences(defaults: defaults)
        XCTAssertFalse(p2.launchAtLogin)
    }

    func test_hotkey_change_posts_notification_with_hotkey_payload() {
        let p = Preferences(defaults: defaults)
        let exp = expectation(forNotification: Preferences.changedNotification, object: p) { note in
            (note.userInfo?["change"] as? Preferences.Change) == .hotkey
        }
        let mods = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        p.hotkey = Chord(keyCode: 50, modifiers: mods)
        wait(for: [exp], timeout: 0.5)
    }

    func test_model_change_posts_notification_with_model_payload() {
        let p = Preferences(defaults: defaults)
        let exp = expectation(forNotification: Preferences.changedNotification, object: p) { note in
            (note.userInfo?["change"] as? Preferences.Change) == .model
        }
        p.model = "mistral:7b"
        wait(for: [exp], timeout: 0.5)
    }

    func test_launchAtLogin_change_posts_notification_with_launchAtLogin_payload() {
        let p = Preferences(defaults: defaults)
        let exp = expectation(forNotification: Preferences.changedNotification, object: p) { note in
            (note.userInfo?["change"] as? Preferences.Change) == .launchAtLogin
        }
        p.launchAtLogin = false
        wait(for: [exp], timeout: 0.5)
    }

    func test_corrupt_stored_hotkey_falls_back_to_default() {
        defaults.set("not-a-chord", forKey: "hotkey")
        let p = Preferences(defaults: defaults)
        XCTAssertEqual(p.hotkey, .default)
    }
}

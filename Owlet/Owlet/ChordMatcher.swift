import Foundation

/// Modifier state at the moment a key was pressed. Captured from CGEvent flags
/// (or hs.eventtap flags during testing) and passed into the pure chord matcher.
struct ModifierFlags: Equatable, Codable {
    let fn: Bool
    let ctrl: Bool
    let cmd: Bool
    let alt: Bool
    let shift: Bool
}

/// Pure function: does this key + flag combination match the given chord?
/// Kept pure so it's table-testable without any CGEvent or AppKit dependency.
enum ChordMatcher {

    /// Match against a user-configured `Chord`. Modifiers must match exactly
    /// (no extra modifiers allowed); the key string must match the chord's
    /// keyCode through `KeyCodeMap`.
    static func matches(chord: Chord, key: String, flags: ModifierFlags) -> Bool {
        guard let expectedKey = KeyCodeMap.name(for: chord.keyCode) else { return false }
        return key == expectedKey && flags == chord.modifiers
    }

    /// Backwards-compatible wrapper for the original fn+Ctrl+R chord.
    /// Used by tests and as a sanity check; production code goes through
    /// `matches(chord:)` with `Preferences.shared.hotkey`.
    static func isOwletRewrite(key: String, flags: ModifierFlags) -> Bool {
        return key == "r"
            && flags.fn && flags.ctrl
            && !flags.cmd && !flags.alt && !flags.shift
    }
}

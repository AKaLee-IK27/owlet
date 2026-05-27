import Foundation

/// Modifier state at the moment a key was pressed. Captured from CGEvent flags
/// (or hs.eventtap flags during testing) and passed into the pure chord matcher.
struct ModifierFlags: Equatable {
    let fn: Bool
    let ctrl: Bool
    let cmd: Bool
    let alt: Bool
    let shift: Bool
}

/// Pure function: does this key + flag combination match Owlet's hotkey?
/// Kept pure so it's table-testable without any CGEvent or AppKit dependency.
/// v0.2 hardcodes the chord; v0.3 may make it configurable.
enum ChordMatcher {

    /// Match exactly fn+ctrl+r — no other modifier may be present.
    static func isOwletRewrite(key: String, flags: ModifierFlags) -> Bool {
        return key == "r"
            && flags.fn && flags.ctrl
            && !flags.cmd && !flags.alt && !flags.shift
    }
}

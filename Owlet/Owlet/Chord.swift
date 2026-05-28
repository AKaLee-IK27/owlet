import Foundation
import Carbon.HIToolbox

/// A keyboard chord: one key + a set of modifier flags. Codable so we can
/// persist it through UserDefaults. `displayString` is the human-readable
/// rendering used by the Settings window ("⌥ Space", "⇧⌘J", "⌃⌥R").
struct Chord: Codable, Equatable {
    let keyCode: Int
    let modifiers: ModifierFlags

    /// Owlet's out-of-the-box chord: Option+Space. The recorder can change it.
    /// Note: globally intercepting Option+Space disables NBSP typing while
    /// Owlet runs — documented in the spec as an accepted trade-off.
    static let `default` = Chord(
        keyCode: Int(kVK_Space),
        modifiers: ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
    )

    /// Human-readable rendering. Modifier order follows the macOS convention
    /// (Ctrl, Option, Shift, Cmd). Key name comes from KeyCodeMap.
    /// Space is rendered as the word "Space" prefixed by the modifier glyph;
    /// every other key inlines into the modifier string.
    var displayString: String {
        let mods = modifierString
        if keyCode == Int(kVK_Space) {
            return "\(mods) Space"
        }
        let key = KeyCodeMap.name(for: keyCode) ?? "?"
        return "\(mods)\(key.uppercased())"
    }

    private var modifierString: String {
        var s = ""
        if modifiers.ctrl  { s += "⌃" }
        if modifiers.alt   { s += "⌥" }
        if modifiers.shift { s += "⇧" }
        if modifiers.cmd   { s += "⌘" }
        if modifiers.fn    { s += "fn" }
        return s
    }


}


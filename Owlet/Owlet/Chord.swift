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
    /// (Ctrl, Option, Shift, Cmd). Key name comes from an inline lookup;
    /// Task 3 will replace this with KeyCodeMap.name(for:).
    /// Space is rendered as the word "Space" prefixed by the modifier glyph;
    /// every other key inlines into the modifier string.
    var displayString: String {
        let mods = modifierString
        if keyCode == Int(kVK_Space) {
            return "\(mods) Space"
        }
        let key = inlineKeyName(for: keyCode) ?? "?"
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

    /// Minimal inline keycode→name map. Task 3 (KeyCodeMap) will replace this.
    private func inlineKeyName(for code: Int) -> String? {
        switch code {
        case Int(kVK_Space):        return "space"
        case 0:                     return "a"
        case 1:                     return "s"
        case 2:                     return "d"
        case 3:                     return "f"
        case 4:                     return "h"
        case 5:                     return "g"
        case 6:                     return "z"
        case 7:                     return "x"
        case 8:                     return "c"
        case 9:                     return "v"
        case 11:                    return "b"
        case 12:                    return "q"
        case 13:                    return "w"
        case 14:                    return "e"
        case 15:                    return "r"
        case 16:                    return "y"
        case 17:                    return "t"
        case 31:                    return "o"
        case 32:                    return "u"
        case 34:                    return "i"
        case 35:                    return "p"
        case 37:                    return "l"
        case 38:                    return "j"
        case 40:                    return "k"
        case 45:                    return "n"
        case 46:                    return "m"
        default:                    return nil
        }
    }
}


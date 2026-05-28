import Foundation
import Carbon.HIToolbox

/// Static, bidirectional table of macOS virtual keycodes ↔ lowercase string
/// names. Covers letters, digits, space/return/tab/escape, arrows, and F1–F12.
///
/// **Layout caveat:** the alphanumeric entries assume a US/QWERTY-style
/// layout. On layouts like AZERTY or Dvorak, `kVK_ANSI_A` produces a
/// different character. The layout-correct upgrade path is `UCKeyTranslate`
/// (or `NSEvent.charactersIgnoringModifiers`); deferred to a future patch.
enum KeyCodeMap {

    static let allEntries: [(Int, String)] = [
        // Letters
        (Int(kVK_ANSI_A), "a"), (Int(kVK_ANSI_B), "b"), (Int(kVK_ANSI_C), "c"),
        (Int(kVK_ANSI_D), "d"), (Int(kVK_ANSI_E), "e"), (Int(kVK_ANSI_F), "f"),
        (Int(kVK_ANSI_G), "g"), (Int(kVK_ANSI_H), "h"), (Int(kVK_ANSI_I), "i"),
        (Int(kVK_ANSI_J), "j"), (Int(kVK_ANSI_K), "k"), (Int(kVK_ANSI_L), "l"),
        (Int(kVK_ANSI_M), "m"), (Int(kVK_ANSI_N), "n"), (Int(kVK_ANSI_O), "o"),
        (Int(kVK_ANSI_P), "p"), (Int(kVK_ANSI_Q), "q"), (Int(kVK_ANSI_R), "r"),
        (Int(kVK_ANSI_S), "s"), (Int(kVK_ANSI_T), "t"), (Int(kVK_ANSI_U), "u"),
        (Int(kVK_ANSI_V), "v"), (Int(kVK_ANSI_W), "w"), (Int(kVK_ANSI_X), "x"),
        (Int(kVK_ANSI_Y), "y"), (Int(kVK_ANSI_Z), "z"),
        // Digits
        (Int(kVK_ANSI_0), "0"), (Int(kVK_ANSI_1), "1"), (Int(kVK_ANSI_2), "2"),
        (Int(kVK_ANSI_3), "3"), (Int(kVK_ANSI_4), "4"), (Int(kVK_ANSI_5), "5"),
        (Int(kVK_ANSI_6), "6"), (Int(kVK_ANSI_7), "7"), (Int(kVK_ANSI_8), "8"),
        (Int(kVK_ANSI_9), "9"),
        // Named
        (Int(kVK_Space), "space"), (Int(kVK_Return), "return"),
        (Int(kVK_Tab), "tab"), (Int(kVK_Escape), "escape"),
        (Int(kVK_LeftArrow), "left"), (Int(kVK_RightArrow), "right"),
        (Int(kVK_UpArrow), "up"), (Int(kVK_DownArrow), "down"),
        // Function keys
        (Int(kVK_F1), "f1"), (Int(kVK_F2), "f2"), (Int(kVK_F3), "f3"),
        (Int(kVK_F4), "f4"), (Int(kVK_F5), "f5"), (Int(kVK_F6), "f6"),
        (Int(kVK_F7), "f7"), (Int(kVK_F8), "f8"), (Int(kVK_F9), "f9"),
        (Int(kVK_F10), "f10"), (Int(kVK_F11), "f11"), (Int(kVK_F12), "f12"),
    ]

    private static let codeToName: [Int: String] = Dictionary(uniqueKeysWithValues: allEntries)
    private static let nameToCode: [String: Int] = Dictionary(
        uniqueKeysWithValues: allEntries.map { ($0.1, $0.0) }
    )

    static func name(for keyCode: Int) -> String? { codeToName[keyCode] }
    static func keyCode(for name: String) -> Int? { nameToCode[name.lowercased()] }
}

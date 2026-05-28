# Rewriter UX (v0.3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded `fn+Ctrl+R` hotkey with a user-configurable chord (default `Option+Space`), add a SwiftUI Settings window (`Cmd+,`) hosting a chord recorder + Ollama model picker + launch-at-login toggle, and extend the Rust rewriter binary with a `--model <name>` flag.

**Architecture:** Single `Preferences` struct (UserDefaults-backed, `NotificationCenter`-broadcast) is the source of truth. The Settings window reads/writes it; `AppDelegate` subscribes and rebinds the `HotkeyEventTap` on chord change. The CGEventTap callback stays a pure value-typed predicate (no live UserDefaults reads on the hot path). The Rust binary stays stateless — model arrives as a CLI flag from `OllamaClient`.

**Tech Stack:** Swift / SwiftUI / AppKit (macOS 14+, `SMAppService`), XCTest, Rust (`ureq`, `serde_json`), Ollama CLI.

**Spec reference:** `docs/superpowers/specs/2026-05-28-rewriter-ux-design.md`

---

## File map

**Create:**
- `Owlet/Owlet/Chord.swift`
- `Owlet/Owlet/KeyCodeMap.swift`
- `Owlet/Owlet/Preferences.swift`
- `Owlet/Owlet/OllamaModelLister.swift`
- `Owlet/Owlet/Views/HotkeyRecorderField.swift`
- `Owlet/Owlet/Views/SettingsView.swift`
- `Owlet/OwletTests/ChordTests.swift`
- `Owlet/OwletTests/KeyCodeMapTests.swift`
- `Owlet/OwletTests/PreferencesTests.swift`
- `Owlet/OwletTests/OllamaModelListerTests.swift`

**Modify:**
- `tools/rewriter/src/main.rs` — add `--model <name>` parsing; remove `const MODEL`
- `Owlet/Owlet/ChordMatcher.swift` — add `matches(chord:key:flags:)`, keep `isOwletRewrite` as wrapper
- `Owlet/OwletTests/ChordMatcherTests.swift` — extend with chord-parameterised tests
- `Owlet/Owlet/HotkeyEventTap.swift` — accept `Chord`; use `KeyCodeMap`
- `Owlet/Owlet/LoginItemManager.swift` — add `isRegistered()` and `setRegistered(_:)`; drop `registerIfNeeded()`
- `Owlet/OwletTests/LoginItemManagerTests.swift` — extend
- `Owlet/Owlet/RewriterFlow.swift` — pass `--model` to `OllamaClient`
- `Owlet/Owlet/StatusBarController.swift` — add "Settings…" item
- `Owlet/Owlet/OwletApp.swift` — wire `SettingsView` into Settings scene; subscribe to `OwletPreferencesChanged`; rebind tap on chord change
- `README.md` — version bump, settings blurb, extended manual smoke checklist
- `progress.md`, `feature_list.json` — final status updates

---

## Task 1: Rust binary accepts `--model <name>` flag

**Files:**
- Modify: `tools/rewriter/src/main.rs:6` (remove `const MODEL`) and `:122-133` (`build_payload`)
- Modify: `tools/rewriter/src/main.rs:355-371` (existing `build_payload_has_expected_shape` test)

- [ ] **Step 1: Add failing test for `--model` parsing**

Add this test inside the `#[cfg(test)] mod tests { … }` block in `tools/rewriter/src/main.rs`:

```rust
#[test]
fn parse_model_arg_returns_value_when_present() {
    let args = vec!["owlet-rewriter".to_string(), "--model".to_string(), "llama3.1:8b".to_string()];
    assert_eq!(parse_model_arg(&args), Ok("llama3.1:8b".to_string()));
}

#[test]
fn parse_model_arg_returns_default_when_absent() {
    let args = vec!["owlet-rewriter".to_string()];
    assert_eq!(parse_model_arg(&args), Ok("qwen3:8b".to_string()));
}

#[test]
fn parse_model_arg_errors_when_flag_has_no_value() {
    let args = vec!["owlet-rewriter".to_string(), "--model".to_string()];
    assert!(parse_model_arg(&args).is_err());
}

#[test]
fn parse_model_arg_errors_on_unknown_flag() {
    let args = vec!["owlet-rewriter".to_string(), "--unknown".to_string(), "x".to_string()];
    assert!(parse_model_arg(&args).is_err());
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `(cd tools/rewriter && cargo test parse_model_arg)`
Expected: 4 failures, "cannot find function `parse_model_arg`".

- [ ] **Step 3: Implement `parse_model_arg` and thread it through**

In `tools/rewriter/src/main.rs`, **delete** line 6 (`const MODEL: &str = "qwen3:8b";`).

Add this constant + function near the other constants (after `TIMEOUT_SECS`):

```rust
const DEFAULT_MODEL: &str = "qwen3:8b";

fn parse_model_arg(args: &[String]) -> Result<String, String> {
    // Tiny hand-rolled parser — clap would be overkill for one flag.
    // Accepts: <prog> [--model <name>]. Rejects unknown flags so typos surface early.
    let mut i = 1;
    let mut model: Option<String> = None;
    while i < args.len() {
        match args[i].as_str() {
            "--model" => {
                let value = args.get(i + 1).ok_or_else(|| "--model requires a value".to_string())?;
                model = Some(value.clone());
                i += 2;
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(model.unwrap_or_else(|| DEFAULT_MODEL.to_string()))
}
```

Change `build_payload` to accept the model:

```rust
fn build_payload(prompt: &str, model: &str) -> serde_json::Value {
    serde_json::json!({
        "model": model,
        "messages": [
            { "role": "system", "content": SYSTEM_PROMPT },
            { "role": "user",   "content": prompt },
        ],
        "stream": false,
        "think": false,
        "options": { "temperature": 0.2 }
    })
}
```

Change `call_ollama` to accept and forward the model:

```rust
fn call_ollama(prompt: &str, model: &str) -> Result<String, RewriteError> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(TIMEOUT_SECS))
        .build();
    let payload = build_payload(prompt, model);
    // ... rest unchanged
```

Change `run` to parse args and pass the model:

```rust
fn run(args: &[String]) -> Result<Option<String>, RewriteError> {
    let model = parse_model_arg(args).map_err(RewriteError::Parse)?;
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| RewriteError::Parse(format!("stdin: {e}")))?;
    if input.trim().is_empty() {
        return Ok(None);
    }
    let raw = call_ollama(&input, &model)?;
    let cleaned = clean_output(&raw);
    if cleaned.trim().is_empty() {
        return Err(RewriteError::Empty);
    }
    Ok(Some(cleaned))
}
```

Change `main` to collect args and forward them:

```rust
fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match run(&args) {
        Ok(Some(s)) => {
            let stdout = io::stdout();
            let mut handle = stdout.lock();
            if let Err(e) = handle.write_all(s.as_bytes()) {
                eprintln!("ERROR: stdout write failed: {e}");
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        Ok(None) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("{}", err.stderr_message());
            ExitCode::FAILURE
        }
    }
}
```

Update the existing `build_payload_has_expected_shape` test (currently at `tools/rewriter/src/main.rs:355`). Replace its body with:

```rust
#[test]
fn build_payload_has_expected_shape() {
    let p = build_payload("rewrite me", "qwen3:8b");
    assert_eq!(p["model"], "qwen3:8b");
    assert_eq!(p["stream"], false);
    assert_eq!(p["think"], false);
    assert_eq!(p["options"]["temperature"], 0.2);
    let msgs = p["messages"].as_array().expect("messages array");
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0]["role"], "system");
    assert_eq!(msgs[1]["role"], "user");
    assert_eq!(msgs[1]["content"], "rewrite me");
    let sys_text = msgs[0]["content"].as_str().unwrap();
    assert!(sys_text.contains("prompt engineering assistant"));
    assert!(sys_text.contains("Preserve the language of the input"));
}

#[test]
fn build_payload_uses_provided_model() {
    let p = build_payload("hi", "llama3.1:8b");
    assert_eq!(p["model"], "llama3.1:8b");
}
```

- [ ] **Step 4: Run the full test suite**

Run: `(cd tools/rewriter && cargo test)`
Expected: all tests pass, including the four new `parse_model_arg_*` tests and `build_payload_uses_provided_model`.

- [ ] **Step 5: Verify the binary smoke test still passes**

Run: `(cd tools/rewriter && cargo build --release && bash tests/smoke.sh)`
Expected: smoke passes (binary contract unchanged when no flag is given).

- [ ] **Step 6: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): --model flag selects Ollama model at spawn time"
```

---

## Task 2: `Chord` value type

**Files:**
- Create: `Owlet/Owlet/Chord.swift`
- Create: `Owlet/OwletTests/ChordTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Owlet/OwletTests/ChordTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `(cd Owlet && xcodegen generate && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/ChordTests)`
Expected: build fails — "Cannot find 'Chord' in scope".

- [ ] **Step 3: Implement `Chord`**

Create `Owlet/Owlet/Chord.swift`:

```swift
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
    /// (Ctrl, Option, Shift, Cmd). Key name comes from `KeyCodeMap`.
    /// Space is rendered as the word "Space" prefixed by the modifier glyph;
    /// every other key inlines into the modifier string.
    var displayString: String {
        let mods = modifierString
        let key = KeyCodeMap.name(for: keyCode) ?? "?"
        if keyCode == Int(kVK_Space) {
            return "\(mods) Space"
        }
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

extension ModifierFlags: Codable {
    enum CodingKeys: String, CodingKey {
        case fn, ctrl, cmd, alt, shift
    }
}
```

- [ ] **Step 4: Add Chord.swift to the xcodegen sources**

`Owlet/project.yml` already globs `sources: [Owlet]`, so no change is needed. Re-run xcodegen to confirm:

Run: `(cd Owlet && xcodegen generate)`
Expected: no errors; project regenerated.

- [ ] **Step 5: Run the new tests to confirm they pass**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/ChordTests)`
Expected: all 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Owlet/Owlet/Chord.swift Owlet/OwletTests/ChordTests.swift
git commit -m "feat(owlet): Chord value type with displayString + Codable"
```

---

## Task 3: `KeyCodeMap` table

**Files:**
- Create: `Owlet/Owlet/KeyCodeMap.swift`
- Create: `Owlet/OwletTests/KeyCodeMapTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Owlet/OwletTests/KeyCodeMapTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/KeyCodeMapTests)`
Expected: build fails — "Cannot find 'KeyCodeMap' in scope".

- [ ] **Step 3: Implement `KeyCodeMap`**

Create `Owlet/Owlet/KeyCodeMap.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `(cd Owlet && xcodegen generate && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/KeyCodeMapTests)`
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Owlet/Owlet/KeyCodeMap.swift Owlet/OwletTests/KeyCodeMapTests.swift
git commit -m "feat(owlet): KeyCodeMap — keycode↔name bidirectional table"
```

---

## Task 4: `Preferences` (UserDefaults + change notification)

**Files:**
- Create: `Owlet/Owlet/Preferences.swift`
- Create: `Owlet/OwletTests/PreferencesTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Owlet/OwletTests/PreferencesTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/PreferencesTests)`
Expected: build fails — "Cannot find 'Preferences' in scope".

- [ ] **Step 3: Implement `Preferences`**

Create `Owlet/Owlet/Preferences.swift`:

```swift
import Foundation
import os.log

/// User-facing settings, persisted to UserDefaults. Single source of truth
/// for the hotkey chord, the Ollama model name, and the launch-at-login flag.
/// Posts `Preferences.changedNotification` (with a `Change` value in
/// userInfo["change"]) whenever a setter mutates the underlying defaults.
///
/// Use `Preferences.shared` from production code; tests inject a custom
/// `UserDefaults` suite via the designated initialiser.
final class Preferences {

    enum Change: String { case hotkey, model, launchAtLogin }

    static let changedNotification = Notification.Name("OwletPreferencesChanged")
    static let shared = Preferences(defaults: .standard)

    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "preferences")

    private let defaults: UserDefaults

    private enum Key {
        static let hotkey         = "hotkey"
        static let model          = "model"
        static let launchAtLogin  = "launchAtLogin"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hotkey: Chord {
        get {
            guard let data = defaults.data(forKey: Key.hotkey) else { return .default }
            do {
                return try JSONDecoder().decode(Chord.self, from: data)
            } catch {
                Self.logger.warning("Stored hotkey failed to decode (\(error.localizedDescription, privacy: .public)); falling back to default")
                return .default
            }
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.hotkey)
                post(.hotkey)
            }
        }
    }

    var model: String {
        get { defaults.string(forKey: Key.model) ?? "qwen3:8b" }
        set {
            defaults.set(newValue, forKey: Key.model)
            post(.model)
        }
    }

    /// Default is `true`: preserves the v0.2 behaviour (where
    /// `AppDelegate` called `LoginItemManager.registerIfNeeded()` on every
    /// launch). If a stored value exists, return it as-is.
    var launchAtLogin: Bool {
        get {
            if defaults.object(forKey: Key.launchAtLogin) == nil { return true }
            return defaults.bool(forKey: Key.launchAtLogin)
        }
        set {
            defaults.set(newValue, forKey: Key.launchAtLogin)
            post(.launchAtLogin)
        }
    }

    /// Corrupt-data setter for the rare "I edited UserDefaults by hand" case.
    /// Wipes the stored hotkey blob; the next read returns `.default`.
    func corruptStoredHotkey() {
        defaults.removeObject(forKey: Key.hotkey)
    }

    private func post(_ change: Change) {
        NotificationCenter.default.post(
            name: Self.changedNotification,
            object: self,
            userInfo: ["change": change]
        )
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `(cd Owlet && xcodegen generate && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/PreferencesTests)`
Expected: all 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Owlet/Owlet/Preferences.swift Owlet/OwletTests/PreferencesTests.swift
git commit -m "feat(owlet): Preferences — UserDefaults-backed settings + change notification"
```

---

## Task 5: Refactor `ChordMatcher` for parameterised chords

**Files:**
- Modify: `Owlet/Owlet/ChordMatcher.swift`
- Modify: `Owlet/OwletTests/ChordMatcherTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Owlet/OwletTests/ChordMatcherTests.swift` (do not remove existing tests):

```swift
    // MARK: parameterised matches(chord:)

    func test_matches_optionSpace_chord() {
        let chord = Chord.default
        let mods = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        XCTAssertTrue(ChordMatcher.matches(chord: chord, key: "space", flags: mods))
    }

    func test_matches_rejects_missing_modifier() {
        let chord = Chord.default
        let mods = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: false, shift: false)
        XCTAssertFalse(ChordMatcher.matches(chord: chord, key: "space", flags: mods))
    }

    func test_matches_rejects_extra_modifier() {
        let chord = Chord.default
        let mods = ModifierFlags(fn: false, ctrl: false, cmd: true, alt: true, shift: false)
        XCTAssertFalse(ChordMatcher.matches(chord: chord, key: "space", flags: mods))
    }

    func test_matches_rejects_wrong_key() {
        let chord = Chord.default
        let mods = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        XCTAssertFalse(ChordMatcher.matches(chord: chord, key: "j", flags: mods))
    }

    func test_matches_custom_chord_cmdShiftJ() {
        let mods = ModifierFlags(fn: false, ctrl: false, cmd: true, alt: false, shift: true)
        let chord = Chord(keyCode: 38, modifiers: mods)
        XCTAssertTrue(ChordMatcher.matches(chord: chord, key: "j", flags: mods))
    }
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/ChordMatcherTests)`
Expected: build fails — `matches(chord:key:flags:)` not declared.

- [ ] **Step 3: Add the `matches` function**

Replace the body of `Owlet/Owlet/ChordMatcher.swift` with:

```swift
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
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/ChordMatcherTests)`
Expected: all tests pass (5 new + the existing original-chord tests).

- [ ] **Step 5: Commit**

```bash
git add Owlet/Owlet/ChordMatcher.swift Owlet/OwletTests/ChordMatcherTests.swift
git commit -m "refactor(owlet): ChordMatcher.matches(chord:) parameterised path"
```

---

## Task 6: `HotkeyEventTap` accepts a `Chord` and uses `KeyCodeMap`

**Files:**
- Modify: `Owlet/Owlet/HotkeyEventTap.swift`
- Modify: `Owlet/Owlet/OwletApp.swift` (only the constructor call inside `startNormalLaunch`)

This task changes only the tap's signature. The Settings-driven rebind logic lands in Task 13.

- [ ] **Step 1: Update `HotkeyEventTap` to take a `Chord`**

Replace the contents of `Owlet/Owlet/HotkeyEventTap.swift` with:

```swift
import Foundation
import CoreGraphics
import AppKit
import os.log

/// Global keyboard event tap that listens for Owlet's configured chord.
/// Requires Input Monitoring permission (TCC). Self-heals if disabled.
/// The chord is captured at construction time — to change it, stop the
/// tap and create a fresh one with the new chord.
final class HotkeyEventTap {

    enum StartError: Error, Equatable {
        case tapCreationFailed
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let chord: Chord
    private let onHotkey: @Sendable () -> Void
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "hotkey")

    /// - Parameters:
    ///   - chord: The chord this tap watches for. Read once at construction.
    ///   - onHotkey: Dispatched to a background queue when the chord fires.
    init(chord: Chord,
         onHotkey: @escaping @Sendable () -> Void) {
        self.chord = chord
        self.onHotkey = onHotkey
    }

    @discardableResult
    func start() -> Result<Void, StartError> {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: context
        ) else {
            Self.logger.error("CGEvent.tapCreate returned nil — Input Monitoring likely not granted")
            return .failure(.tapCreationFailed)
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.logger.info("HotkeyEventTap started for chord \(self.chord.displayString, privacy: .public)")
        return .success(())
    }

    func stop() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        self.tap = nil
        self.runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Self.logger.info("Event tap re-enabled after \(String(describing: type), privacy: .public)")
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let keyName = KeyCodeMap.name(for: Int(keyCode)) ?? ""
        let flags = ModifierFlags(
            fn: event.flags.contains(.maskSecondaryFn),
            ctrl: event.flags.contains(.maskControl),
            cmd: event.flags.contains(.maskCommand),
            alt: event.flags.contains(.maskAlternate),
            shift: event.flags.contains(.maskShift)
        )

        guard ChordMatcher.matches(chord: chord, key: keyName, flags: flags) else {
            return Unmanaged.passUnretained(event)
        }

        // Consume the event AND dispatch the work async so the tap doesn't block.
        DispatchQueue.global(qos: .userInitiated).async { [onHotkey] in
            onHotkey()
        }
        return nil
    }
}
```

- [ ] **Step 2: Update the call site in `OwletApp.swift`**

In `Owlet/Owlet/OwletApp.swift`, find the `startNormalLaunch()` method. Replace the lines that build `rewriterTap` (lines 47-52, the block starting `let rewriterTap = HotkeyEventTap(chord: ChordMatcher.isOwletRewrite)`) with:

```swift
        // Rewriter chord — defaults to Option+Space, user-configurable via Settings.
        // The closure is @Sendable; don't capture self.
        let rewriterTap = HotkeyEventTap(chord: Preferences.shared.hotkey) {
            Task { @MainActor in
                let flow = RewriterFlow()
                await flow.start()
            }
        }
```

- [ ] **Step 3: Build the app**

Run: `(cd Owlet && xcodegen generate && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build)`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the full test suite to confirm nothing regressed**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Owlet/Owlet/HotkeyEventTap.swift Owlet/Owlet/OwletApp.swift
git commit -m "refactor(owlet): HotkeyEventTap takes a Chord; reads from Preferences"
```

---

## Task 7: `LoginItemManager` gains `isRegistered` / `setRegistered`

**Files:**
- Modify: `Owlet/Owlet/LoginItemManager.swift`
- Modify: `Owlet/OwletTests/LoginItemManagerTests.swift`
- Modify: `Owlet/Owlet/OwletApp.swift` (replace the `registerIfNeeded()` call)

- [ ] **Step 1: Inspect the existing tests**

Run: `head -50 Owlet/OwletTests/LoginItemManagerTests.swift` to see what's already covered (the file tests `shouldRegister(status:)` against the `SMAppService.Status` enum).

- [ ] **Step 2: Add failing tests for the new API**

Append to `Owlet/OwletTests/LoginItemManagerTests.swift`:

```swift
    // MARK: setRegistered / isRegistered (post v0.3)

    func test_isRegistered_matches_smAppService_enabled() {
        // Pure decision wrapper — we can't actually mutate SMAppService in a
        // unit test, but we can verify the boolean projection.
        XCTAssertTrue(LoginItemManager.isRegistered(status: .enabled))
        XCTAssertFalse(LoginItemManager.isRegistered(status: .notRegistered))
        XCTAssertFalse(LoginItemManager.isRegistered(status: .requiresApproval))
        XCTAssertFalse(LoginItemManager.isRegistered(status: .notFound))
    }
```

- [ ] **Step 3: Run tests to confirm they fail**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/LoginItemManagerTests)`
Expected: build fails — `isRegistered(status:)` not declared.

- [ ] **Step 4: Replace `LoginItemManager` body**

Replace `Owlet/Owlet/LoginItemManager.swift` with:

```swift
import Foundation
import ServiceManagement
import os.log

enum LoginItemManager {

    enum Failure: Error {
        case registerThrew(String)
        case unregisterThrew(String)
    }

    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "loginitem")

    /// Pure projection used by tests. The runtime call sites read
    /// `SMAppService.mainApp.status` directly via `currentlyRegistered()`.
    static func isRegistered(status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled: return true
        case .notRegistered, .requiresApproval, .notFound: return false
        @unknown default: return false
        }
    }

    /// Pure decision used by tests. Skip only if already enabled.
    static func shouldRegister(status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled: return false
        case .notRegistered, .requiresApproval, .notFound: return true
        @unknown default: return true
        }
    }

    /// Current registration status of the main app's login-item helper.
    static func currentlyRegistered() -> Bool {
        isRegistered(status: SMAppService.mainApp.status)
    }

    /// Apply the user's preference. Throws on failure so the Settings UI
    /// can surface the underlying error and revert the toggle.
    static func setRegistered(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            guard shouldRegister(status: service.status) else {
                logger.info("Login item already enabled, no-op")
                return
            }
            do { try service.register() } catch {
                logger.error("register() threw: \(error.localizedDescription, privacy: .public)")
                throw Failure.registerThrew(error.localizedDescription)
            }
            logger.info("Registered Owlet as a login item")
        } else {
            guard isRegistered(status: service.status) else {
                logger.info("Login item already not enabled, no-op")
                return
            }
            do { try service.unregister() } catch {
                logger.error("unregister() threw: \(error.localizedDescription, privacy: .public)")
                throw Failure.unregisterThrew(error.localizedDescription)
            }
            logger.info("Unregistered Owlet as a login item")
        }
    }
}
```

- [ ] **Step 5: Update the AppDelegate call site**

In `Owlet/Owlet/OwletApp.swift`, find the line in `startNormalLaunch()`:

```swift
        // Register login item (no-op if already registered).
        LoginItemManager.registerIfNeeded()
```

Replace it with:

```swift
        // Apply the launch-at-login preference (defaults to true on first launch).
        do {
            try LoginItemManager.setRegistered(Preferences.shared.launchAtLogin)
        } catch {
            Self.logger.warning("Login item apply failed: \(error.localizedDescription, privacy: .public)")
        }
```

- [ ] **Step 6: Run tests to confirm they pass**

Run: `(cd Owlet && xcodegen generate && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/LoginItemManagerTests)`
Expected: all tests pass.

- [ ] **Step 7: Build the app to confirm wiring**

Run: `(cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build)`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Owlet/Owlet/LoginItemManager.swift Owlet/Owlet/OwletApp.swift Owlet/OwletTests/LoginItemManagerTests.swift
git commit -m "feat(owlet): LoginItemManager.setRegistered honours Preferences.launchAtLogin"
```

---

## Task 8: `OllamaModelLister`

**Files:**
- Create: `Owlet/Owlet/OllamaModelLister.swift`
- Create: `Owlet/OwletTests/OllamaModelListerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Owlet/OwletTests/OllamaModelListerTests.swift`:

```swift
import XCTest
@testable import Owlet

final class OllamaModelListerTests: XCTestCase {

    func test_parses_standard_output() {
        let raw = """
        NAME              ID              SIZE      MODIFIED
        qwen3:8b          abc123          4.7 GB    2 days ago
        llama3.1:8b       def456          4.7 GB    1 week ago
        mistral:7b        ghi789          4.1 GB    3 weeks ago
        """
        XCTAssertEqual(
            OllamaModelLister.parse(raw),
            ["qwen3:8b", "llama3.1:8b", "mistral:7b"]
        )
    }

    func test_parses_single_model() {
        let raw = """
        NAME      ID      SIZE    MODIFIED
        qwen3:8b  abc     4.7 GB  2 days ago
        """
        XCTAssertEqual(OllamaModelLister.parse(raw), ["qwen3:8b"])
    }

    func test_header_only_returns_empty() {
        let raw = "NAME    ID    SIZE    MODIFIED\n"
        XCTAssertEqual(OllamaModelLister.parse(raw), [])
    }

    func test_completely_empty_returns_empty() {
        XCTAssertEqual(OllamaModelLister.parse(""), [])
    }

    func test_blank_lines_are_skipped() {
        let raw = """
        NAME      ID      SIZE    MODIFIED
        qwen3:8b  abc     4.7 GB  2 days ago

        llama3.1:8b  def  4.7 GB  1 week ago
        """
        XCTAssertEqual(OllamaModelLister.parse(raw), ["qwen3:8b", "llama3.1:8b"])
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/OllamaModelListerTests)`
Expected: build fails — `OllamaModelLister` not declared.

- [ ] **Step 3: Implement `OllamaModelLister`**

Create `Owlet/Owlet/OllamaModelLister.swift`:

```swift
import Foundation
import os.log

/// Discovers locally pulled Ollama models by shelling out to `ollama list`.
/// The subprocess invocation is wrapped in a 1-second timeout so opening the
/// Settings window can't hang on a stuck Ollama daemon. Parsing is a pure
/// function (table layout: header row, then whitespace-delimited columns;
/// first column is the model name).
enum OllamaModelLister {

    enum Failure: Error {
        case spawnFailed(String)
        case timedOut
        case nonZeroExit(Int32, String)
    }

    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "modellister")
    private static let timeoutSeconds: TimeInterval = 1.0
    private static let binary = "/usr/local/bin/ollama"
    private static let altBinary = "/opt/homebrew/bin/ollama"

    /// Spawn `ollama list`, return parsed model names. Returns the empty
    /// array on any failure — callers should layer their own fallback
    /// (e.g. `["qwen3:8b"]`) when the result is empty so the picker remains usable.
    static func list() async -> [String] {
        do {
            let raw = try await runOllamaList()
            return parse(raw)
        } catch {
            logger.warning("ollama list failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Pure parser. Skips the header row, takes the first whitespace-delimited
    /// column of each subsequent non-empty line.
    static func parse(_ raw: String) -> [String] {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1 else { return [] }
        return lines.dropFirst().compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)
        }
    }

    // MARK: subprocess

    private static func runOllamaList() async throws -> String {
        let exe = FileManager.default.fileExists(atPath: binary) ? binary : altBinary
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["list"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() }
        catch { throw Failure.spawnFailed("\(error)") }

        return try await withCheckedThrowingContinuation { cont in
            final class Flag: @unchecked Sendable {
                private let lock = NSLock()
                private var _timedOut = false
                var timedOut: Bool { get { lock.withLock { _timedOut } } set { lock.withLock { _timedOut = newValue } } }
            }
            let flag = Flag()
            let timeoutWork = DispatchWorkItem {
                if process.isRunning {
                    flag.timedOut = true
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

            process.terminationHandler = { proc in
                timeoutWork.cancel()
                if flag.timedOut {
                    cont.resume(throwing: Failure.timedOut); return
                }
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outText = String(data: outData, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    cont.resume(throwing: Failure.nonZeroExit(proc.terminationStatus, errText)); return
                }
                cont.resume(returning: outText)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `(cd Owlet && xcodegen generate && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/OllamaModelListerTests)`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Owlet/Owlet/OllamaModelLister.swift Owlet/OwletTests/OllamaModelListerTests.swift
git commit -m "feat(owlet): OllamaModelLister — shell out to 'ollama list' + parser"
```

---

## Task 9: `RewriterFlow` passes `--model` to `OllamaClient`

**Files:**
- Modify: `Owlet/Owlet/RewriterFlow.swift:29-37`

- [ ] **Step 1: Update `makeDefaultRewriter`**

In `Owlet/Owlet/RewriterFlow.swift`, replace the body of `makeDefaultRewriter()` (currently lines 29-37) with:

```swift
    private static func makeDefaultRewriter() -> Rewriting {
        let fallback = NSString(string: "~/repos/owlet/tools/rewriter").expandingTildeInPath
        let dir = UserDefaults.standard.string(forKey: "rewriterDirectory") ?? fallback
        // Read the model lazily on each construction — picks up Settings changes
        // without needing a tap restart or notification subscription here.
        let model = Preferences.shared.model
        return OllamaClient(
            executablePath: "\(dir)/owlet-rewriter",
            arguments: ["--model", model],
            timeoutSeconds: 30
        )
    }
```

- [ ] **Step 2: Build + run the Swift test suite**

Run: `(cd Owlet && xcodegen generate && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')`
Expected: all tests pass.

- [ ] **Step 3: Run the Rust smoke test (binary contract)**

Run: `(cd tools/rewriter && cargo build --release && bash tests/smoke.sh)`
Expected: smoke passes (the binary handles the new `--model` flag as Task 1 ensured).

- [ ] **Step 4: Commit**

```bash
git add Owlet/Owlet/RewriterFlow.swift
git commit -m "feat(owlet): pass --model to owlet-rewriter from Preferences"
```

---

## Task 10: `HotkeyRecorderField` (NSViewRepresentable)

**Files:**
- Create: `Owlet/Owlet/Views/HotkeyRecorderField.swift`

This view has no unit-testable surface (it's a custom NSView captured by SwiftUI). Manual smoke is the verification path; that lives in Task 14.

- [ ] **Step 1: Confirm `Owlet/Owlet/Views/` exists**

Run: `ls Owlet/Owlet/Views/` to verify (it already holds the v0.4 floater views).
Expected: directory present.

- [ ] **Step 2: Implement `HotkeyRecorderField`**

Create `Owlet/Owlet/Views/HotkeyRecorderField.swift`:

```swift
import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Borderless field that captures the next modifier-bearing keyDown after
/// the user clicks the "Record" button. The captured `Chord` flows back
/// to SwiftUI via the binding; SettingsView decides whether to persist it.
///
/// The field accepts only events with at least one of cmd/option/control/
/// shift/fn — bare keypresses are ignored so the user can't accidentally
/// record `Space` or `R` alone (which would conflict with normal typing
/// the moment the field loses focus).
struct HotkeyRecorderField: NSViewRepresentable {

    @Binding var chord: Chord
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onChordCaptured = { newChord in
            chord = newChord
            isRecording = false
        }
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.displayChord = chord
        nsView.isRecording = isRecording
        nsView.needsDisplay = true
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    // MARK: NSView subclass

    final class RecorderNSView: NSView {

        var onChordCaptured: ((Chord) -> Void)?
        var onCancel: (() -> Void)?
        var displayChord: Chord = .default
        var isRecording: Bool = false

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            // Border
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 6, yRadius: 6)
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isRecording ? 2 : 1
            path.stroke()

            // Text
            let label = isRecording ? "Press a chord…" : displayChord.displayString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
            let attr = NSAttributedString(string: label, attributes: attrs)
            let textSize = attr.size()
            let textRect = NSRect(
                x: (bounds.width - textSize.width) / 2,
                y: (bounds.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            attr.draw(in: textRect)
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            if event.keyCode == UInt16(kVK_Escape) {
                onCancel?()
                return
            }
            let raw = event.modifierFlags
            let flags = ModifierFlags(
                fn: raw.contains(.function),
                ctrl: raw.contains(.control),
                cmd: raw.contains(.command),
                alt: raw.contains(.option),
                shift: raw.contains(.shift)
            )
            // Require at least one modifier — bare keys are out of scope.
            guard flags.ctrl || flags.alt || flags.cmd || flags.shift || flags.fn else { return }
            let chord = Chord(keyCode: Int(event.keyCode), modifiers: flags)
            onChordCaptured?(chord)
        }

        override func resignFirstResponder() -> Bool {
            if isRecording { onCancel?() }
            return super.resignFirstResponder()
        }
    }
}
```

- [ ] **Step 3: Build the app**

Run: `(cd Owlet && xcodegen generate && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build)`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Owlet/Owlet/Views/HotkeyRecorderField.swift
git commit -m "feat(owlet): HotkeyRecorderField — NSView-backed chord recorder"
```

---

## Task 11: `SettingsView`

**Files:**
- Create: `Owlet/Owlet/Views/SettingsView.swift`

- [ ] **Step 1: Implement `SettingsView`**

Create `Owlet/Owlet/Views/SettingsView.swift`:

```swift
import SwiftUI

/// The General tab of Owlet's Settings window. Three rows: hotkey
/// recorder + reset, Ollama model picker, launch-at-login toggle.
/// Width is fixed at 440 so the layout doesn't reflow as the model
/// list arrives asynchronously.
struct SettingsView: View {

    @State private var hotkey: Chord = Preferences.shared.hotkey
    @State private var isRecording: Bool = false
    @State private var model: String = Preferences.shared.model
    @State private var launchAtLogin: Bool = Preferences.shared.launchAtLogin

    @State private var models: [String] = []
    @State private var modelListFailed: Bool = false
    @State private var loginItemError: String? = nil

    var body: some View {
        Form {
            Section {
                LabeledContent("Hotkey") {
                    HStack(spacing: 8) {
                        HotkeyRecorderField(chord: $hotkey, isRecording: $isRecording)
                            .frame(height: 28)
                            .onChange(of: hotkey) { _, newValue in
                                Preferences.shared.hotkey = newValue
                            }
                        Button(isRecording ? "Cancel" : "Record") {
                            isRecording.toggle()
                        }
                        Button("Reset") {
                            isRecording = false
                            hotkey = .default
                            Preferences.shared.hotkey = .default
                        }
                    }
                }

                LabeledContent("Model") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $model) {
                            ForEach(modelChoices, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: model) { _, newValue in
                            Preferences.shared.model = newValue
                        }
                        if modelListFailed {
                            Text("Couldn't list models — is `ollama serve` running?")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("Launch at login") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { _, newValue in
                                do {
                                    try LoginItemManager.setRegistered(newValue)
                                    Preferences.shared.launchAtLogin = newValue
                                    loginItemError = nil
                                } catch {
                                    loginItemError = "\(error)"
                                    launchAtLogin = !newValue // revert
                                }
                            }
                        if let loginItemError {
                            Text(loginItemError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
        .task {
            await loadModels()
        }
    }

    /// Always include the currently saved model so the Picker has a valid
    /// selection even if `ollama list` returned nothing or failed.
    private var modelChoices: [String] {
        var set = Set(models)
        set.insert(model)
        return Array(set).sorted()
    }

    private func loadModels() async {
        let result = await OllamaModelLister.list()
        await MainActor.run {
            if result.isEmpty {
                modelListFailed = true
                models = [model]
            } else {
                modelListFailed = false
                models = result
            }
        }
    }
}
```

- [ ] **Step 2: Build the app**

Run: `(cd Owlet && xcodegen generate && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build)`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/Views/SettingsView.swift
git commit -m "feat(owlet): SettingsView — hotkey recorder + model picker + login toggle"
```

---

## Task 12: `StatusBarController` adds a "Settings…" menu item

**Files:**
- Modify: `Owlet/Owlet/StatusBarController.swift:41-63` (`rebuildMenu`)

- [ ] **Step 1: Insert the "Settings…" item**

In `Owlet/Owlet/StatusBarController.swift`, find `rebuildMenu()`. Replace its body with:

```swift
    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Owlet — running", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let perms = NSMenuItem(title: permissionsLabel(probePermissions()), action: nil, keyEquivalent: "")
        perms.isEnabled = false
        menu.addItem(perms)

        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(handleSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())

        let restart = NSMenuItem(title: "Restart Owlet", action: #selector(handleRestart), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

        let quit = NSMenuItem(title: "Quit Owlet", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }
```

Add this method to `StatusBarController` (anywhere alongside `handleRestart`/`handleQuit`):

```swift
    @objc private func handleSettings() {
        // Activate the app so the Settings window comes forward over the menu bar.
        NSApp.activate(ignoringOtherApps: true)
        // macOS 14+ selector. SwiftUI's `Settings { ... }` scene wires this up automatically.
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
```

- [ ] **Step 2: Build the app**

Run: `(cd Owlet && xcodegen generate && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build)`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/StatusBarController.swift
git commit -m "feat(owlet): menubar 'Settings…' (⌘,) item opens the Settings window"
```

---

## Task 13: Wire `SettingsView` into the Settings scene + subscribe to `OwletPreferencesChanged`

**Files:**
- Modify: `Owlet/Owlet/OwletApp.swift`

- [ ] **Step 1: Replace the `Settings` scene body**

In `Owlet/Owlet/OwletApp.swift`, replace lines 9-12 (the `var body: some Scene { Settings { EmptyView() } }` block) with:

```swift
    var body: some Scene {
        Settings { SettingsView() }
    }
```

- [ ] **Step 2: Subscribe to `OwletPreferencesChanged` and rebind the tap on chord change**

In `AppDelegate`, add a stored property near the other privates:

```swift
    private var prefsObserver: NSObjectProtocol?
```

Replace the body of `applicationDidFinishLaunching(_:)` with:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        self.statusBar = StatusBarController()

        prefsObserver = NotificationCenter.default.addObserver(
            forName: Preferences.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let change = note.userInfo?["change"] as? Preferences.Change else { return }
            self.handlePreferencesChanged(change)
        }

        let status = PermissionChecker.check()
        lastKnownPermissionStatus = status
        Self.logger.info("Launch: permission status = \(String(describing: status), privacy: .public)")

        switch status {
        case .allGranted:
            startNormalLaunch()
        case .missing(let missing):
            showPermissionModal(missing: missing)
        }
    }
```

Add this method to `AppDelegate`:

```swift
    private func handlePreferencesChanged(_ change: Preferences.Change) {
        switch change {
        case .hotkey:
            rebindHotkeyTap()
        case .launchAtLogin:
            do {
                try LoginItemManager.setRegistered(Preferences.shared.launchAtLogin)
            } catch {
                Self.logger.warning("Login item apply failed: \(error.localizedDescription, privacy: .public)")
            }
        case .model:
            // Nothing to do here — RewriterFlow.makeDefaultRewriter() reads
            // Preferences.shared.model lazily on each invocation.
            break
        }
    }

    private func rebindHotkeyTap() {
        hotkeyTap?.stop()
        let newTap = HotkeyEventTap(chord: Preferences.shared.hotkey) {
            Task { @MainActor in
                let flow = RewriterFlow()
                await flow.start()
            }
        }
        switch newTap.start() {
        case .success:
            hotkeyTap = newTap
            Self.logger.info("Rewriter hotkey rebound to \(Preferences.shared.hotkey.displayString, privacy: .public)")
        case .failure:
            // New tap couldn't start; surface the permission modal so the user
            // can re-grant Input Monitoring. The previous tap is already stopped;
            // worst case the user re-records after granting.
            Self.logger.error("Hotkey rebind failed; showing permission modal")
            showPermissionModal(missing: [.inputMonitoring])
        }
    }
```

- [ ] **Step 3: Build the app**

Run: `(cd Owlet && xcodegen generate && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build)`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the full Swift test suite**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Owlet/Owlet/OwletApp.swift
git commit -m "feat(owlet): Settings scene wired; AppDelegate rebinds tap on chord change"
```

---

## Task 14: README + smoke checklist + harness bookkeeping

**Files:**
- Modify: `README.md`
- Modify: `progress.md`
- Modify: `feature_list.json`

- [ ] **Step 1: Update the README version + add Settings blurb**

In `README.md`, find every "v0.2" and replace with "v0.3" where it refers to the current shipping version. Add a short paragraph (or extend the existing usage section) describing the new Settings window:

> **Settings (v0.3 onward).** Press `Cmd+,` (or pick "Settings…" from the menu-bar icon) to change the hotkey, switch the Ollama model, or toggle "Launch at login". The default hotkey is `Option+Space`; intercepting this disables typing a non-breaking space while Owlet is running. If that bites you, change the chord or click "Reset" to restore the default after retrying with something else.

In the README's manual smoke-test checklist, append:

> **Settings window (v0.3):**
> - [ ] Open via `Cmd+,` or menubar → "Settings…". Three rows visible; Hotkey shows `⌥ Space`.
> - [ ] Click `Record`, press `Ctrl+Shift+J`. The chord is committed on capture (no extra Save click); the field now shows `⌃⇧J`. Trigger a rewrite with the new chord — popup appears.
> - [ ] Press `Option+Space` in a text field — it types a non-breaking space (NBSP), confirming the old binding is released.
> - [ ] Click `Reset`. Trigger with `Option+Space`; popup appears.
> - [ ] Switch the model picker to a different locally-pulled model. Trigger a rewrite. In `Console.app` (filter `subsystem:co.greenpassport.owlet`), verify the spawned `owlet-rewriter` was invoked with the new `--model` value.
> - [ ] Toggle "Launch at login" off, relaunch the Mac (or run `osascript -e 'tell application "Owlet" to quit'`), confirm Owlet doesn't auto-start. Re-toggle on, confirm it does.

- [ ] **Step 2: Run the full verification suite**

Run: `./init.sh`
Expected: clean run (Rust build + tests, Swift build + tests).

- [ ] **Step 3: Walk the manual smoke checklist**

Install the new build and walk every checkbox added in Step 1. If anything fails, fix it in a new commit before declaring the feature done.

Run: `./install.sh`
Then walk the checklist. Note the result line.

- [ ] **Step 4: Update `feature_list.json` and `progress.md`**

In `feature_list.json`, set `feat-003.status` to `"done"` and paste the smoke-test result line (e.g. `"./init.sh PASS on 2026-05-28; manual smoke walked (all 6 Settings steps)"`) into `feat-003.evidence`.

Mark `feat-004` (README v0.3 refresh) as `"done"` with evidence `"README updated as part of feat-003 (see Task 14, Step 1)"` so we don't carry duplicate work.

In `progress.md`, update **Last Updated**, move feat-003 from "What's Next" to "What's Done", and note the v0.3 milestone.

- [ ] **Step 5: Commit + final verification**

```bash
git add README.md progress.md feature_list.json
git commit -m "docs(owlet): v0.3 — configurable hotkey + Settings window + model picker"
```

Run one last time: `./init.sh`
Expected: clean.

---

## Self-review checklist (for the executor)

Before declaring this plan complete, verify:

- [ ] Every task ends with a passing test or build command **and** a commit.
- [ ] `git log --oneline` since the spec commit shows 14 commits (one per task).
- [ ] `./init.sh` exits 0 from a clean checkout.
- [ ] Manual smoke (Task 14, Step 3) was actually walked, not just simulated.
- [ ] `feature_list.json` `feat-003.status` is `done` with non-empty `evidence`.
- [ ] No `MODEL` constant remains in `tools/rewriter/src/main.rs`.
- [ ] No `registerIfNeeded()` call remains in `OwletApp.swift`.

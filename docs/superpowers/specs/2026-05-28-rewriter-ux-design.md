# Owlet — Rewriter UX: Configurable Hotkey + Settings Window (v0.3)

**Date:** 2026-05-28
**Status:** Draft, pending user approval
**Scope:** Replace the hardcoded `fn+Ctrl+R` rewriter hotkey with a user-configurable chord (default `Option+Space`), and introduce a dedicated SwiftUI Settings window reachable via `Cmd+,` or the menu-bar "Settings…" item. The Settings window exposes a chord recorder, a "Reset to default" button, an Ollama model picker, and a "Launch at login" toggle. The Rust rewriter binary gains a `--model <name>` flag so the picker is functional end-to-end. The capture/diff/popup pipeline is unchanged.

This spec is the implementation companion to `feat-003` in `feature_list.json`.

## 1. Decisions locked in

| # | Decision | Rationale |
|---|---|---|
| 1 | **Default hotkey: `Option+Space`.** Recorder allows the user to change it. | User reported `fn+Ctrl+R` is hard to press. Option+Space is one-handed and reachable. Trade-off: `Option+Space` is the macOS shortcut for typing a non-breaking space (U+00A0); intercepting it globally means NBSP can no longer be typed while Owlet is running. The user has accepted this trade-off and the recorder + reset path is the escape hatch. |
| 2 | **Settings live in a dedicated SwiftUI Settings window** (the `Settings { ... }` scene already wired in `OwletApp.swift:11`), reachable via `Cmd+,` or a "Settings…" item in the menu-bar dropdown. | Recorder + model picker + toggle would crowd the menu-bar dropdown. The Settings window gives space for help text, focus rings, and future settings without further menu growth. |
| 3 | **Settings scope for v0.3:** hotkey recorder, reset-to-default, Ollama model picker, launch-at-login toggle. No per-feature hotkeys, no chord-conflict detection, no theme/appearance settings. | YAGNI. Each of these four items has a user-visible justification today. |
| 4 | **Tap-restart on hotkey change** rather than a live `Preferences` read inside the CGEventTap callback. | The CGEventTap callback is on a tight, kill-if-slow path. Restarting the tap (~50ms, invisible) keeps the matcher a pure value-typed predicate and avoids coupling the hot path to UserDefaults reads. |
| 5 | **Explicit "Record" button** in the recorder, not capture-on-focus. | Matches macOS convention (System Settings → Keyboard Shortcuts, Karabiner, Raycast, Alfred). Capture-on-focus is too easy to trigger by accident. |
| 6 | **Model list is populated by shelling out to `ollama list` when the Settings window opens.** Falls back to a single-entry list (`["qwen3:8b"]`) on failure. | Always reflects what is actually pulled locally. A hardcoded list would lie when the user pulls a different model. The HTTP API (`/api/tags`) would also work but adds an extra dependency on Ollama being currently serving; shelling out is simpler and consistent with the existing process-spawn pattern. |
| 7 | **`Preferences` is a single struct backed by `UserDefaults.standard`,** with a `static let shared` accessor and a `NotificationCenter` change notification carrying a `Change` payload identifying what changed (`hotkey`, `model`, `launchAtLogin`). | Mirrors the existing UserDefaults usage (`rewriterDirectory` is already read this way in `RewriterFlow.swift:32`). Avoids introducing a Combine/Observation dependency for three settings. |
| 8 | **Rust binary gains `--model <name>` as a CLI flag,** defaulting to `qwen3:8b`. The hardcoded `const MODEL` in `tools/rewriter/src/main.rs:6` is removed. | Required so the picker is functional end-to-end. A flag keeps the binary stateless (no extra env var to document, no UserDefaults equivalent on the Rust side). |
| 9 | **Out of scope for v0.3:** per-feature hotkeys, chord-conflict detection (e.g., warning if the user records something macOS already owns), full layout-correct key translation via `UCKeyTranslate`, dynamic theme switching, exporting/importing preferences. | Keeps the spec to a single shippable feature. `UCKeyTranslate` is noted as a follow-up in `KeyCodeMap.swift` comments. |

## 2. Architecture

```
            ┌──────────────────────────┐
            │  SwiftUI Settings scene  │  ←─── Cmd+, or "Settings…" menu item
            │   (General tab)          │
            └────────────┬─────────────┘
                         │ reads / writes
                         ▼
        ┌────────────────────────────────┐
        │   Preferences (UserDefaults)   │  source of truth
        │   - hotkey: Chord              │
        │   - model: String              │
        │   - launchAtLogin: Bool        │
        └─────┬──────────────────┬───────┘
              │ notifies         │ read at flow construction
              ▼                  ▼
    ┌─────────────────┐  ┌──────────────────┐
    │  Hotkey rebind  │  │   RewriterFlow   │
    │  (in AppDel)    │  │ → OllamaClient   │
    │  stop/start tap │  │   --model <name> │
    └─────────────────┘  └──────────────────┘
```

Owlet remains single-process and single-tap. The Settings window is just another view on the same `Preferences` store. The capture → rewrite → diff → popup pipeline (`RewriterFlow.swift`) is unchanged except that `OllamaClient` reads the current model from `Preferences` when constructed.

## 3. Components

### 3.1 New files

- **`Owlet/Owlet/Preferences.swift`** — Plain struct + `static let shared`, UserDefaults-backed. Reads on init, writes on each setter. Posts `Notification.Name("OwletPreferencesChanged")` whose `userInfo` carries a `Change` value (`.hotkey`, `.model`, or `.launchAtLogin`). Defaults on first launch: `hotkey = Chord.default` (Option+Space), `model = "qwen3:8b"`, `launchAtLogin = true` (preserves the current behaviour, where `applicationDidFinishLaunching` calls `registerIfNeeded()` unconditionally).
- **`Owlet/Owlet/Chord.swift`** — `struct Chord: Codable, Equatable { keyCode: Int; modifiers: ModifierFlags; displayString: String }`. `static let `default`: Chord` = Option+Space. `init?(keyCode:modifiers:)` derives `displayString` via `KeyCodeMap`.
- **`Owlet/Owlet/KeyCodeMap.swift`** — Bidirectional table for the keycodes Owlet needs: alphanumerics (a–z, 0–9), space, return, tab, escape, arrow keys, F1–F12. Exposes `name(for keyCode: Int) -> String?` and `keyCode(for name: String) -> Int?`. A comment notes that this assumes US/QWERTY-style layouts; `UCKeyTranslate` is the layout-correct upgrade path and is deferred.
- **`Owlet/Owlet/Views/SettingsView.swift`** — SwiftUI view, single "General" tab. Three rows: Hotkey (current chord display + `[Record]` + `[Reset to default]`), Model (Picker populated via `.task` from `OllamaModelLister.list()`), `Toggle` for launch-at-login. Width ~440pt.
- **`Owlet/Owlet/Views/HotkeyRecorderField.swift`** — `NSViewRepresentable` wrapping an `NSView` subclass that becomes first responder on `[Record]`, overrides `keyDown(with:)`, accepts the first event whose `modifierFlags` intersect `[.command, .option, .control, .shift, .function]`, and reports the resulting `Chord` back to the SwiftUI binding. Cancel (Escape or losing first-responder status) discards.
- **`Owlet/Owlet/OllamaModelLister.swift`** — `func list() async throws -> [String]`. Shells out to `ollama list` with a 1s timeout, parses the table (skip header row, take the first whitespace-delimited column of each subsequent line). On failure returns `["qwen3:8b"]` so the picker remains usable.
- **`Owlet/OwletTests/PreferencesTests.swift`** — UserDefaults round-trip + change-notification payload assertions.
- **`Owlet/OwletTests/ChordTests.swift`** — Codable round-trip, `displayString` formatting (`⌥ Space`, `⌘⇧J`), equality.
- **`Owlet/OwletTests/KeyCodeMapTests.swift`** — Round-trip for every entry; assert unknown keycode yields `nil`.
- **`Owlet/OwletTests/OllamaModelListerTests.swift`** — Parser only (no subprocess): valid `ollama list` output, empty output, malformed output, single-model output.

### 3.2 Changed files

- **`Owlet/Owlet/ChordMatcher.swift`** — Replace static `isOwletRewrite(key:flags:)` with `static func matches(chord: Chord, key: String, flags: ModifierFlags) -> Bool`. Keep `isOwletRewrite` as a thin wrapper (`matches(chord: .default, key:, flags:)`) for the existing default-chord table tests.
- **`Owlet/Owlet/HotkeyEventTap.swift`** — Replace the closure-based `chord` predicate with a stored `chord: Chord` property; remove the one-case `keyCodeToString` switch and call `KeyCodeMap.name(for:)` instead. Provide `stop()` (already exists) and re-entrant `start()` so the AppDelegate can rebind.
- **`Owlet/Owlet/OwletApp.swift`** — Replace `Settings { EmptyView() }` (line 11) with `Settings { SettingsView() }`. `AppDelegate` subscribes to `OwletPreferencesChanged` in `applicationDidFinishLaunching`; on `.hotkey` it stops the current tap, builds a new one with `Preferences.shared.hotkey`, restarts; on `.launchAtLogin` it calls `LoginItemManager.setRegistered(_:)`. On `.model` no action — the next `RewriterFlow` invocation reads it lazily.
- **`Owlet/Owlet/RewriterFlow.swift`** — In `makeDefaultRewriter()` (line 29) construct `OllamaClient` with `arguments: ["--model", Preferences.shared.model]`.
- **`Owlet/Owlet/LoginItemManager.swift`** — Add `static func isRegistered() -> Bool` and `static func setRegistered(_ on: Bool) throws`. Replace the existing `registerIfNeeded()` call site in `AppDelegate.startNormalLaunch()` (`OwletApp.swift:64`) with `LoginItemManager.setRegistered(Preferences.shared.launchAtLogin)` so the system's registration always reflects the user's preference rather than racing it. Delete `registerIfNeeded()` once no callers remain.
- **`Owlet/Owlet/StatusBarController.swift`** — Insert a `"Settings…"` `NSMenuItem` between the permissions row and the separator (around `rebuildMenu()` at line 41), with `keyEquivalent: ","` and `keyEquivalentModifierMask: .command`. Action: open Settings via the standard `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` (or fallback `showPreferencesWindow:` on macOS < 14).
- **`Owlet/project.yml`** — No changes expected (xcodegen picks up new Swift files automatically from `sources: [Owlet]`).
- **`tools/rewriter/src/main.rs`** — Remove `const MODEL: &str = "qwen3:8b"` (line 6). Parse `--model <name>` from `std::env::args()` (small hand-rolled scan; `clap` is overkill for one flag). Default remains `qwen3:8b`. Replace the `"model": MODEL` field at line 124 with the parsed value. Update the assertion at `main.rs:358` accordingly and add one test case asserting `--model llama3.1:8b` is honored and missing flag falls back to default.
- **`README.md`** — Add the new manual smoke-test steps (see Section 7) and mention the configurable hotkey + Settings window. Version mention bumped to v0.3 once tagged.

## 4. Data flow

### 4.1 Recording a new hotkey

1. User opens Settings (Cmd+, or "Settings…" menu item). `SettingsView` renders the current chord ("⌥ Space") next to a `[Record]` button.
2. User clicks `[Record]` → `HotkeyRecorderField`'s underlying NSView becomes first responder; field renders "Press a chord…" placeholder.
3. NSView overrides `keyDown(with:)`. First event with at least one of `[.command, .option, .control, .shift, .function]` set is accepted; bare-key and modifier-only events are ignored.
4. NSView builds a `Chord` from `event.keyCode` + a `ModifierFlags` derived from `event.modifierFlags`; sends it to the SwiftUI binding.
5. SettingsView shows the new chord. User clicks `[Save]` → `Preferences.shared.hotkey = newChord`. Clicking `[Reset to default]` writes `.default` instead.
6. `Preferences` posts `OwletPreferencesChanged` with payload `.hotkey`. `AppDelegate` calls `hotkeyTap?.stop()`, constructs a fresh `HotkeyEventTap` with the new chord, calls `.start()`. On success, no UI feedback (the new chord is now live). On `.failure(.tapCreationFailed)`, fall back to the previous chord and surface the permissions modal.

### 4.2 Picking a model

1. `SettingsView`'s `.task` modifier runs `OllamaModelLister.list()`; result populates the `Picker`'s options. Current selection is `Preferences.shared.model`.
2. User picks a different model → `Preferences.shared.model = newValue`. Notification posted (`.model`), but `AppDelegate` ignores it.
3. The next `RewriterFlow.start()` invocation calls `makeDefaultRewriter()`, which reads `Preferences.shared.model` and constructs `OllamaClient` with the updated `--model` argument. No restart needed.

### 4.3 Toggling launch at login

1. `Toggle` is bound to `Preferences.shared.launchAtLogin`.
2. On change: notification fires `.launchAtLogin`; `AppDelegate` calls `LoginItemManager.setRegistered(newValue)`.
3. On error, `setRegistered` throws; the AppDelegate writes the error string into a small inline label state shown under the toggle. The toggle reverts to its previous value visually.

## 5. Error handling

| Failure | Handling |
|---|---|
| Recorder dismissed without saving | Discard the in-progress chord, keep the currently saved chord. No notification posted. |
| User records a chord they can't reproduce | `[Reset to default]` is always visible in the Settings window; one click restores Option+Space. |
| Recorded chord conflicts with a system shortcut (e.g., `Cmd+Q`) | Out of scope to detect for v0.3. Documented as a known limitation in the README. User can re-record. |
| `ollama list` fails or Ollama daemon is down | `OllamaModelLister.list()` returns `["qwen3:8b"]` (or `[Preferences.shared.model]` if that differs); picker shows a small "couldn't list models — is `ollama serve` running?" hint below the field. The rewrite flow continues to use whatever model is saved. |
| `LoginItemManager.setRegistered(_:)` throws | Inline red text under the toggle shows the error; the toggle visually reverts. The user can retry. |
| Tap fails to restart with the new chord | Revert `Preferences.shared.hotkey` to the previous value; surface the permission modal (same flow as `applicationDidFinishLaunching`'s `.tapCreationFailed` branch). |
| Old `rewriterDirectory` UserDefault is missing (fresh first launch without install) | Unchanged from today — `RewriterFlow.swift:30` falls back to `~/repos/owlet/tools/rewriter`. |
| User has an old install with an old hotkey saved that doesn't decode | `Preferences.init` catches the decode failure, falls back to `Chord.default`, logs a warning. |

## 6. Testing

### 6.1 Unit tests (XCTest, `Owlet/OwletTests/`)

- **PreferencesTests** — set each field, read it back from a freshly constructed `Preferences`; assert the change notification fires with the correct `Change` payload.
- **ChordTests** — Codable round-trip; `displayString` for `⌥ Space`, `⌘⇧J`, `⌃⌥R`, `F5`; equality and hashability.
- **KeyCodeMapTests** — round-trip for every entry; `name(for: 999)` returns `nil`.
- **ChordMatcherTests** (extended) — table tests for `matches(chord:key:flags:)` across several chords + modifier permutations (exact match, extra modifier present → no match, missing modifier → no match, different key → no match).
- **OllamaModelListerTests** — feed canned `ollama list` outputs into the parser: header + 3 models, header + 1 model, empty (header only), totally empty, garbage. Subprocess invocation itself is integration and is exercised by the manual smoke test.

### 6.2 Rust tests (`tools/rewriter/`, `cargo test`)

- Existing test at `main.rs:358` updated: when `--model` is absent, request body has `model: "qwen3:8b"`.
- New test: when `--model llama3.1:8b` is passed, request body has `model: "llama3.1:8b"`.
- New test: unknown/malformed flag (e.g., `--model` with no value) exits non-zero with a clear error on stderr — same exit-code contract as documented in the binary's existing smoke test.

### 6.3 Manual smoke test (add to README's checklist)

1. Open Settings (Cmd+, **or** menu-bar → "Settings…"). The window shows three rows; the hotkey row shows "⌥ Space".
2. Click `[Record]`, press `Ctrl+Shift+J`, click `[Save]`. The window now shows "⌃⇧J".
3. Place cursor in a text field somewhere (TextEdit, Notes), type a draft prompt, press `Ctrl+Shift+J`. The Improve Prompt popup appears as before.
4. Press Option+Space in the same text field — it should now type a non-breaking space (NBSP), confirming the old binding is released.
5. Click `[Reset to default]`. The window shows "⌥ Space". Repeat step 3 with Option+Space; popup appears.
6. Open Settings, switch the model picker to a different locally-pulled model. Trigger a rewrite. Verify in `Console.app` (filter: `subsystem:co.greenpassport.owlet`) that the spawned `owlet-rewriter` is invoked with the new `--model` value, and the rewrite completes.
7. Toggle "Launch at login" off. Relaunch the Mac (or run `osascript -e 'tell application "Owlet" to quit'` and check `~/Library/LaunchAgents/` is clean). Re-toggle on, verify Owlet auto-launches at next login.

## 7. Definition of done (per CLAUDE.md)

- [ ] `Preferences`, `Chord`, `KeyCodeMap`, `OllamaModelLister`, `HotkeyRecorderField`, `SettingsView` exist.
- [ ] `ChordMatcher`, `HotkeyEventTap`, `OwletApp`/`AppDelegate`, `RewriterFlow`, `LoginItemManager`, `StatusBarController` updated as in Section 3.2.
- [ ] `tools/rewriter/src/main.rs` accepts `--model <name>`; default behaviour unchanged when flag is absent.
- [ ] `(cd tools/rewriter && cargo test)` passes.
- [ ] `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')` passes.
- [ ] `(cd tools/rewriter && cargo build --release && bash tests/smoke.sh)` passes (binary contract unchanged for stdin/stdout/exit codes).
- [ ] Manual smoke test (Section 6.3) walked; evidence pasted into `feature_list.json` `feat-003.evidence`.
- [ ] `./init.sh` passes from a clean checkout.
- [ ] `README.md` updated: version mention bumped to v0.3, smoke-test checklist extended, brief blurb on the Settings window.
- [ ] `progress.md` updated; `feature_list.json` `feat-003.status` → `done`.

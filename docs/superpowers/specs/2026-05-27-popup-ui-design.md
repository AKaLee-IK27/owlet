# Owlet — Rewriter Popup Design Spec

**Date:** 2026-05-27
**Status:** Draft v2, pending user re-approval
**Scope:** Add a SwiftUI popup to the existing rewrite tool, give the project an umbrella identity (**Owlet** — a collection of small useful local-LLM tools for macOS), and define a Grammarly-inspired visual UX for the popup. The first Owlet command is **Rewriter**; the architecture leaves clean room for **Translator** and **Grammar** in later passes without re-architecture.

The current silent `fn+Ctrl+R` flow is retired in favor of the popup.

## 1. Decisions locked in

| # | Decision | Rationale |
|---|---|---|
| 1 | Popup offers both **Replace** (in-place at the original selection) and **Copy** (to clipboard) buttons. | User chose the full-flexibility path: in-place when supported, copy fallback when the source app refuses programmatic input. |
| 2 | The popup replaces the silent flow. `fn+Ctrl+R` now opens the popup. No second hotkey for silent rewrites. | Simpler mental model. Every rewrite gets a review gate. |
| 3 | Rewrite logic stays in Python (`rewrite_prompt.py`) as a CLI; Swift app shells out via `Process`. | Reuses existing tested logic. Refactor: replace clipboard I/O with stdin/stdout. |
| 4 | Architecture is **three cooperating processes**: Hammerspoon (hotkey only), `Owlet.app` (UI + AX), `rewrite_prompt.py` (LLM). | Each has one clean owner. Hammerspoon's existing AX grant is unchanged. The Swift app needs a **separate** AX grant of its own — TCC does not share across apps. |
| 5 | Project umbrella name: **Owlet** (inspired by the Pokémon Rowlet — small, friendly, owl-coded, room for a leaf-accent mascot later). | Toolkit vision needs a brand. Owlet works as a single word, easy in EN and VI, has clean tool-name composition: "Owlet Rewriter", "Owlet Translator", "Owlet Grammar". Known brand-search collision with Owlet Baby Care (different domain) accepted for a personal project. |
| 6 | Monorepo layout under `~/repos/owlet/`. The Swift app is a single binary (`Owlet.app`) that hosts multiple commands; v1 ships only the Rewriter command but the dispatcher and URL-scheme namespace (`owlet://<verb>`) are in place. | Raycast/Spotlight pattern. Adding the next tool means new code, not a new `.app` bundle. |
| 7 | Diff display in the popup result state is **inline word-level diff** (Grammarly-signature): strikethrough red deletions + green-highlighted additions in a single text view. Auto-collapses to plain rewritten text when more than 70% of original words are changed (rewrites too transformative for diff to be readable). | The most-Grammarly-iconic relevant pattern. Works for typical short prompts where most words survive. Collapse threshold prevents noise on full-paragraph rewrites. |
| 8 | Visual treatment is Grammarly-flavored card UI: rounded corners, soft shadow, system material background (light/dark adaptive), gentle fade+slide entry animation, friendly copy tone ("Owlet is thinking…", "Looks like Ollama isn't running"). Text wordmark only for v1; logo/mascot illustration is out-of-scope. | The user explicitly asked for Grammarly inspiration. Visual tokens are centralized in a `Theme` module so a later logo/mascot drop is a one-file change. |

## 2. Architecture

```
┌─────────────┐   open owlet://rewrite      ┌────────────────────────────┐
│ Hammerspoon │──── via hs.execute ───────▶│         Owlet.app          │
│   (hotkey)  │                            │  (SwiftUI menu bar helper) │
└─────────────┘                            │   LSUIElement, self-signed │
                                           └─────────────┬──────────────┘
                                                         │
                                  ┌──────────────────────┼────────────────────┐
                                  │                      │                    │
                          ApplicationServices       Process / Pipe      AppKit (NSPanel)
                            (AX read/write)              │                    │
                                  │                      ▼                    ▼
                          [Source app text]    tools/rewriter/             Popup window
                                              rewrite_prompt.py
                                              (stdin → Ollama → stdout)
```

- **Hammerspoon (existing).** Repurposed: the `fn+Ctrl+R` eventtap now runs `hs.execute("open owlet://rewrite")`. Hammerspoon's role shrinks to "hotkey forwarder" — no more spawning Python directly. Hammerspoon's AX grant is unrelated to Owlet's needs; Owlet holds its own AX grant and posts its own keystrokes for the Cmd+V fallback (see section 8 Permissions).
- **`Owlet.app` (new).** A `LSUIElement` (no Dock icon) menu bar helper, self-signed via `codesign --sign -` for personal use. Stays running idle after first launch; subsequent hotkey presses are URL-routed to the running instance. Registers `owlet://` URL scheme.
- **`tools/rewriter/rewrite_prompt.py` (refactored).** Replace `pyperclip.paste()` / `pyperclip.copy()` with `sys.stdin.read()` / `print(...)`. Drop the `osascript` notification call. Keep the wrapping-quote and `<think>` cleanup in Python; Swift trusts the output as-is.

### URL-scheme namespace

- `owlet://rewrite` — invokes the Rewriter command (v1).
- `owlet://translate` — reserved; v1 dispatcher returns a "Not yet available" error state.
- `owlet://grammar` — same.

Future tools plug in by adding a new `Flow` class and registering a verb with `CommandDispatcher`. The URL handler is verb-agnostic.

## 3. Components inside `Owlet.app`

| Component | Responsibility | Touches |
|---|---|---|
| `OwletApp` (`@main`) | SwiftUI `App` shell, `AppDelegate` adapter, URL scheme handler registration, lifecycle. | NSApplication |
| `CommandDispatcher` | Receives `owlet://<verb>` URLs. Maps verb to a `Flow` (v1: `rewrite` → `RewriterFlow`; others → `UnavailableFlow`). | — |
| `HotkeyCoordinator` | Receives the dispatched flow, applies 200 ms debounce, kicks off `CaptureFlow`. | — |
| `RewriterFlow` (conforms to `CaptureFlow` protocol) | State machine for the Rewriter command: snapshot focus → capture selection → show popup → call rewriter → handle action. | AXBridge, OllamaClient, PopupWindowController, DiffEngine |
| `AXBridge` | Only place that calls `ApplicationServices`. Functions: `captureSelection()`, `replaceSelection(_:in:)`, `currentFocus()`, `isPasswordField(_:)`. | ApplicationServices.framework |
| `OllamaClient` | `rewrite(_: String) async throws -> String`. Spawns Python CLI via `Process`. On `Task.cancel()` or 30 s timeout, calls `process.terminate()` so the child is actually killed (Swift cancellation alone does not stop the child). | Foundation.Process |
| `DiffEngine` | `func diff(_ original: String, _ rewritten: String) -> [DiffSegment]`. Word-tokenized Myers-style diff via `CollectionDifference`. Caller decides whether to render based on `collapseRatio`. | Foundation |
| `PopupWindowController` | Owns the non-activating `NSPanel`. Positions near the focused element. Manages entry/exit animations. | AppKit |
| `PopupView` + sub-views (`LoadingView`, `ResultView`, `DiffView`, `ErrorView`, `EmptyView`) | Pure SwiftUI driven by `@Observable PopupState`. | SwiftUI |
| `Theme` | Centralized design tokens: colors (light/dark), typography, animation durations, corner radii, spacing. | SwiftUI |

### Data types

```swift
struct SelectionSnapshot {
    let text: String
    let sourceAppBundleID: String
    let focusedElementRef: AXUIElement
    let captureMethod: CaptureMethod  // .ax | .clipboardFallback
}

struct FocusSnapshot {
    let appBundleID: String
    let focusedElementRef: AXUIElement
}

struct DiffSegment: Hashable {
    let text: String
    let kind: Kind  // .unchanged | .added | .removed
}

enum PopupState {
    case loading(sourceText: String, isLong: Bool)
    case result(original: String, rewritten: String, segments: [DiffSegment]?, canReplace: Bool)
    case empty(text: String)                   // rewrite ≈ original
    case error(ErrorKind)
}
```

### Boundary rule

Only `AXBridge` calls AX APIs. Only `OllamaClient` spawns the Python process. Only `PopupWindowController` instantiates AppKit windows. `DiffEngine` is pure logic. `Theme` exposes only static tokens. Everything else is plain Swift, unit-testable.

## 4. Happy-path data flow

1. User selects text in any app.
2. User presses `fn+Ctrl+R`.
3. Hammerspoon: `hs.execute("open owlet://rewrite")`.
4. `OwletApp.application(_:open:)` receives the URL → `CommandDispatcher.dispatch(.rewrite)` → returns `RewriterFlow`.
5. `HotkeyCoordinator.run(RewriterFlow)`.
6. `AXBridge.captureSelection()` returns `SelectionSnapshot` (≤ 200 ms target).
7. `PopupWindowController.show(state: .loading(sourceText, isLong: text.count > 4000))`. Non-activating panel appears anchored to the focused element's screen rect, fades + slides in over 180 ms.
8. `OllamaClient.rewrite(snapshot.text)` runs as a `Task`. Spawns `tools/rewriter/.venv/bin/python3 rewrite_prompt.py`, writes stdin, reads stdout to EOF. 30 s timeout via `Task` cancellation + `process.terminate()`.
9. Stdout arrives. `RewriterFlow` decides:
   - If `rewritten.trimmed == original.trimmed` → state `.empty(original)`.
   - Else compute `DiffEngine.diff(...)`. If `removedRatio > 0.7` → state `.result(original, rewritten, segments: nil, canReplace: ...)` (renders plain rewritten text). Otherwise → state `.result(..., segments: diffSegments, ...)` (renders inline diff).
10. User chooses:
    - **Enter / Replace** → `AXBridge.replaceSelection(rewritten, in: snapshot.focusedElementRef)` with focus re-validation. AX write first; fall back to clipboard save + synthetic Cmd+V + clipboard restore (500 ms later) on failure.
    - **Cmd+C / Copy** → `NSPasteboard.general` write, popup closes.
    - **Esc / Cancel** → popup closes, no side effects.
11. Popup fades out over 120 ms. Owlet stays running idle in the menu bar.

## 5. Text-length policy

| Threshold | Value | Behavior |
|---|---|---|
| Input soft-warn | 4,000 chars | `LoadingView` shows "This is a lot of text. Owlet might take a bit longer." badge. Proceed. |
| Input hard-reject | 16,000 chars | Hard reject before LLM call. `ErrorView`. |
| Output soft-warn | 8,000 chars | Visual indicator in `ResultView`. Replace still available. |
| Output hard-reject | 32,000 chars | Replace disabled (Copy only). Warning shown. |
| Diff collapse | > 70 % of original words removed | `ResultView` renders plain rewritten text instead of inline diff, with subtitle "Too many changes to diff cleanly". |

Char-based (not token-based) to keep the UI layer free of a tokenizer dependency.

## 6. Visual UX (Grammarly-inspired)

Centralized in `Theme.swift` — changing any of these values is one edit, no consumer changes.

### Card

- **Geometry:** 480 pt wide, height adaptive between 240 pt (loading / empty) and 480 pt (scrollable beyond)
- **Chrome:** `NSVisualEffectView` background (system `.popover` material), 14 pt corner radius, system shadow
- **Padding:** 20 pt
- **Positioning:** anchored to the screen rect of the focused AX element; auto-flips above/below to stay on-screen; constrained to the screen containing the source app

### Animations

- **Entry:** opacity 0 → 1, y offset +8 → 0, 180 ms ease-out
- **Exit:** opacity 1 → 0, 120 ms ease-in
- **State transition** (loading → result, result → error, etc.): 200 ms cross-fade
- **Loading skeleton:** shimmer animation, 1.5 s loop, 4 placeholder lines

### Typography

- **Body:** SF Pro System 13 pt regular
- **Diff highlight body:** SF Pro System 13 pt regular (added/removed segments use the same size; only color and decoration change)
- **Section headers:** SF Pro System 11 pt semibold, +0.5 tracking, secondary color
- **Owlet wordmark:** SF Pro System 11 pt medium, tertiary color, card footer-left

### Colors

| Token | Light | Dark | Use |
|---|---|---|---|
| `bgPrimary` | system material `.popover` | system material `.popover` | card background |
| `textPrimary` | `.primary` | `.primary` | body text |
| `textSecondary` | `.secondary` | `.secondary` | metadata, wordmark |
| `accentAdded` | system green @ 0.18 alpha | system green @ 0.22 alpha | diff additions background |
| `accentAddedFg` | system green | system green | diff additions text |
| `accentRemoved` | system red @ 0.14 alpha | system red @ 0.18 alpha | diff deletions background |
| `accentRemovedFg` | system red | system red | diff deletions text (with strikethrough) |
| `actionPrimary` | system accent (default blue) | system accent | Replace button |

All colors source from the system palette so they automatically adapt to the user's accent color and Increase Contrast accessibility settings.

### Buttons

- **Replace** (primary): system filled button style, accent color, full-width footer
- **Copy** (secondary): bordered button style, alongside Replace
- **Cancel** (tertiary): plain button style, leading-aligned in footer
- Keyboard map: Enter → Replace · Cmd+C → Copy · Esc → Cancel · Cmd+R → Retry (in error state only)

### Friendly copy strings

| State | Text |
|---|---|
| Loading | "Owlet is thinking…" |
| Loading (long input) | "Owlet is thinking… this is a long one." |
| Empty (rewrite ≈ original) | "Looks good — no changes needed." |
| Error (Ollama down) | "Looks like Ollama isn't running. Start it and click Retry." |
| Error (timeout) | "That took longer than expected. Retry?" |
| Error (empty output) | "Owlet didn't come back with anything. Retry?" |
| Error (input too long) | "That selection is too long for Owlet to handle (X chars; max 16,000)." |
| Error (focus lost) | "The original text lost focus. You can still Copy the rewrite." |
| Error (AX denied) | "Owlet needs Accessibility permission. Open System Settings →" |

### Mascot / brand presence in v1

- Text wordmark "Owlet" in the footer-left of every popup state.
- No illustrated mascot in v1 (out-of-scope below).
- All brand surface is in `Theme.swift` so a later mascot drop is a one-file change.

## 7. Error and edge-case behavior

| Failure | Behavior |
|---|---|
| Empty / whitespace-only selection | `ErrorView("Select some text first")`. Auto-dismiss after 2 s. |
| Password field (`AXIsPasswordField` true) | Refused. `ErrorView("Won't read from password fields")`. |
| AX read returns nil | Try clipboard-roundtrip fallback (save clipboard, post Cmd+C, read, restore). If still nil → `ErrorView("Can't read selection in this app")`. |
| Input > 16,000 chars | Hard reject. Error message per section 6. |
| Input 4,000–16,000 chars | Soft warn badge in `LoadingView`. Proceed. |
| Ollama down (`ConnectionError`) | `ErrorView` per section 6 + Retry button. |
| Generation > 30 s | Cancel Process via `terminate()`. `ErrorView` per section 6. |
| Empty / whitespace stdout | `ErrorView` per section 6. |
| Rewrite identical to input | `EmptyView` per section 6 with Dismiss button only. |
| Output > 32,000 chars | Replace disabled, Copy enabled, warning shown. |
| Diff > 70 % removal | Render plain rewritten text with subtitle "Too many changes to diff cleanly". |
| Focus changed during generation | On Replace click: detect mismatch via `currentFocus()`. Replace disabled. `WarnView("The original text lost focus. You can still Copy.")`. |
| AX write fails | Automatic fallback: clipboard save → write rewrite → synthetic Cmd+V → restore clipboard after 500 ms delay. If Cmd+V also fails → leave rewrite on clipboard, `WarnView("Couldn't replace; rewrite is on your clipboard")`. |
| AX permission missing | On every app launch, call `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)`. If false, show a modal with a deep-link button to System Settings → Privacy & Security → Accessibility and quit when dismissed. The modal does not auto-dismiss when the user toggles the switch — they must relaunch. |
| Re-trigger while popup open | `Task.cancel()` on in-flight rewrite + `process.terminate()`. Re-run capture. 200 ms debounce. |
| Esc / outside-click during loading | Cancel Task, terminate Process. Close popup. No notification. |
| Python script missing / venv broken | `OllamaClient` surfaces stderr. `ErrorView("Backend unavailable: <stderr>")`. |
| Unknown verb in URL | `CommandDispatcher` routes to `UnavailableFlow` which shows `ErrorView("That tool isn't available yet.")`. |

## 8. Permissions surface

| Permission | Who holds it today | Who needs it after this change |
|---|---|---|
| Accessibility (read text fields, post events) | Hammerspoon | Hammerspoon **and** `Owlet.app` (new grant required) |
| Input Monitoring | None | None — global hotkey stays in Hammerspoon, not a CGEventTap in the Swift app |
| Automation (AppleScript) | Hammerspoon (`hs.allowAppleScript`) | Same |

The Swift app's AX grant lets it read any text field and post any keystroke system-wide. This is a meaningfully broader trust surface than the current Hammerspoon-only setup. Acceptable for personal use; documented here as a known risk.

## 9. Testing strategy

### Swift unit tests (XCTest)
- `cleanModelOutput` Swift port (defense in depth, even though Python does it at runtime)
- Length-policy boundary tests (3 999 / 4 000 / 4 001, 15 999 / 16 000 / 16 001)
- URL-scheme parser, including unknown verb routing
- `PopupState` transition tests
- `OllamaClient` Process invocation with a mock binary script (verifies `terminate()` is called on cancellation)
- `DiffEngine` tests:
  - Identical strings → all `.unchanged`
  - Single-word substitution → one `.removed`, one `.added`, rest `.unchanged`
  - Full rewrite → high `removedRatio` (validates collapse threshold)
  - Empty original → all `.added`
  - Empty rewrite → all `.removed`
- `Theme` tokens: snapshot test in light + dark mode

### Swift integration tests
- `RewriterFlow` with mocked `AXBridge`, `OllamaClient`, and `DiffEngine` (protocols, not concretes).
- Exercises every error path in section 7 deterministically.
- Covers the `.empty` state transition.

### Manual smoke tests (documented; cannot be unit-tested cleanly)

| Scenario | Expected |
|---|---|
| Select in TextEdit → hotkey → Replace | Text replaced in place, inline diff visible. |
| Select in Safari article body → hotkey → Replace | AX write fails; auto-fallback to Cmd+V works OR Copy fallback offered. |
| Select in password field → hotkey | Refused with explanatory error. |
| Click into another app between popup appearing and Replace | Replace disabled; Copy still works. |
| Kill `ollama` process → hotkey | "Looks like Ollama isn't running" error; Retry returns to loading after `ollama serve` is up. |
| Spam hotkey 5× rapidly | Only one popup; in-flight rewrites cancelled. |
| Select 17,000-char paragraph → hotkey | Hard reject without LLM call. |
| Select empty | "Select some text first" error. |
| Rewrite returns identical text | `EmptyView` shown, "Looks good" copy. |
| Rewrite changes > 70% of words | `ResultView` renders plain text + "Too many changes" subtitle (no diff). |
| Dark mode | Card chrome + diff colors visibly correct, contrast adequate. |
| Trigger `owlet://translate` from terminal | `UnavailableFlow` error shown. |

### Python
Existing approach preserved. Refactored `rewrite_prompt.py` is exercised via `echo "test" | python3 rewrite_prompt.py` and the 5 spec test cases from the original build (broken grammar, vague, already-good, mixed VI/EN, empty stdin).

## 10. File layout

```
~/repos/owlet/                              ← renamed from ~/repos/prompt-rewriter/
├── README.md                               ← rewritten as umbrella README
├── install.sh                              ← umbrella installer (see below)
├── .gitignore                              ← existing, extended for Xcode build artifacts
│
├── docs/superpowers/specs/
│   └── 2026-05-27-popup-ui-design.md       ← this file
│
├── tools/
│   └── rewriter/
│       ├── rewrite_prompt.py               ← refactored: stdin → stdout, no clipboard, no notify
│       ├── requirements.txt                ← unchanged
│       └── .venv/                          ← regenerated at new path
│
└── Owlet/                                  ← NEW: macOS Xcode project
    ├── Owlet.xcodeproj
    ├── Owlet/
    │   ├── OwletApp.swift                  ← @main, AppDelegate, URL scheme handler
    │   ├── CommandDispatcher.swift
    │   ├── HotkeyCoordinator.swift
    │   ├── RewriterFlow.swift              ← conforms to CaptureFlow protocol
    │   ├── CaptureFlow.swift               ← protocol + shared types
    │   ├── AXBridge.swift
    │   ├── OllamaClient.swift
    │   ├── DiffEngine.swift
    │   ├── PopupWindowController.swift
    │   ├── PopupState.swift
    │   ├── Theme.swift
    │   ├── Views/
    │   │   ├── PopupView.swift
    │   │   ├── LoadingView.swift
    │   │   ├── ResultView.swift
    │   │   ├── DiffView.swift
    │   │   ├── ErrorView.swift
    │   │   └── EmptyView.swift
    │   ├── Info.plist                       ← URL scheme `owlet`, LSUIElement YES, AX usage description
    │   └── Owlet.entitlements
    └── OwletTests/
        ├── CleanOutputTests.swift
        ├── LengthPolicyTests.swift
        ├── PopupStateTests.swift
        ├── URLSchemeTests.swift
        ├── DiffEngineTests.swift
        ├── ThemeSnapshotTests.swift
        └── RewriterFlowTests.swift          ← mocked AXBridge, OllamaClient, DiffEngine
```

### `install.sh` responsibilities (extended)

1. Verify `ollama` and pull `qwen3:8b` (unchanged).
2. Create venv at `tools/rewriter/.venv/` and install Python deps (path updated).
3. Add `OLLAMA_KEEP_ALIVE=24h` to `~/.zshrc` (unchanged).
4. Install Hammerspoon via brew if missing (unchanged).
5. Write / refresh the prompt-rewriter block in `~/.hammerspoon/init.lua` — block now runs `hs.execute("open owlet://rewrite")` instead of spawning Python.
6. **New:** verify `xcodebuild` is on PATH; if not, exit with a "install Xcode (full IDE, not just Command Line Tools) and re-run" message.
7. **New:** build `Owlet/Owlet.xcodeproj` via `xcodebuild -scheme Owlet -configuration Release`.
8. **New:** self-sign with `codesign --sign - --force --deep` and copy `Owlet.app` to `~/Applications/`.
9. **New:** launch `Owlet.app` for first-run TCC prompt; open System Settings → Accessibility on a fresh install.
10. Reload Hammerspoon via `osascript`.

All steps stay idempotent. The Hammerspoon block is path-derived per the existing `${HERE#"$HOME/"}` template.

## 11. Out of scope for v1

- Streaming token-by-token rendering. (Block until full response; revisit if perceived latency feels bad on cold start.)
- Selection-context-aware prompt templates (different prompts for code vs prose vs markdown).
- Rewrite history / undo log.
- Settings UI for model selection, temperature, prompt customisation. (Edit `rewrite_prompt.py` for now.)
- Multi-language prompt rewriting from the popup. (Existing Vietnamese-input behavior of the LLM still applies.)
- Stats / telemetry.
- Auto-start at login. The user runs the app manually (or it is launched by Hammerspoon on first hotkey press). Adding a Login Item is a one-line `SMAppService` call that can be revisited.
- Code signing for distribution beyond `codesign --sign -` self-signing.
- **Illustrated Owlet mascot / logo.** v1 ships with a text wordmark only. A later pass can add a SF Symbols or vector mark in `Theme.swift` without touching consumers.
- **Owlet Translator** (`owlet://translate`) and **Owlet Grammar** (`owlet://grammar`) commands. The dispatcher routes them to `UnavailableFlow` for now.
- Migrating the existing `~/bin/llm-{rewrite,grammar,translate}` CLI scripts under the Owlet umbrella. They keep working independently; merging them into `tools/` is a later decision.
- Markdown-aware diffing (don't strikethrough markdown syntax). v1 treats input as plain text.

## 12. Open risks (carried from BA analysis, updated)

- **Wrong-target replacement.** Focus shifts during the 1–2 s generation, Replace fires into the wrong field. Mitigated by focus snapshot + re-validation, but a race window remains under fast context switching.
- **Clipboard pollution.** Both the clipboard-roundtrip capture fallback and the synthetic Cmd+V replace fallback transiently mutate the pasteboard. A failure mid-flow can silently leave the user's prior clipboard wiped. Mitigation: try/finally with restore.
- **AX permission expansion.** A second AX-trusted app system-wide.
- **Hammerspoon coupling.** A syntax error in `init.lua` after a future edit silently breaks the popup with no UI signal. Mitigation: Hammerspoon's own Console shows errors; README will document checking it first when the hotkey is dead.
- **Diff readability for transformative rewrites.** The 70% collapse threshold is a guess; may need tuning after dogfooding. Mitigation: threshold is a single named constant in `DiffEngine`.

## 13. Next step after this spec is approved

Invoke the `superpowers:writing-plans` skill to produce a step-by-step implementation plan covering: folder rename, Python refactor, Xcode project scaffold, each component (in build order — `Theme` and `DiffEngine` first as pure-logic foundations, then `AXBridge` and `OllamaClient` as platform adapters, then `PopupWindowController` and views, then `RewriterFlow` to tie them together, then the install.sh extensions), and the manual smoke-test checklist.

No code is written until the plan is also approved.

# Prompt Rewriter — Popup UI Design Spec

**Date:** 2026-05-27
**Status:** Draft, pending user approval
**Scope:** Add a SwiftUI popup to the existing Prompt Rewriter so the user can preview the LLM rewrite and choose to Replace (in-place) or Copy before the source text is touched. The current silent `fn+Ctrl+R` flow is retired in favor of the popup.

## 1. Decisions locked in

| # | Decision | Rationale |
|---|---|---|
| 1 | Popup offers both **Replace** (in-place at the original selection) and **Copy** (to clipboard) buttons. | User chose the full-flexibility path: in-place when supported, copy fallback when the source app refuses programmatic input. |
| 2 | The popup replaces the silent flow. `fn+Ctrl+R` now opens the popup. No second hotkey for silent rewrites. | Simpler mental model. Every rewrite gets a review gate. |
| 3 | Rewrite logic stays in Python (`rewrite_prompt.py`) as a CLI; Swift app shells out via `Process`. | Reuses existing tested logic. Refactor: replace clipboard I/O with stdin/stdout. |
| 4 | Architecture is **three cooperating processes**: Hammerspoon (hotkey only), `PromptRewriter.app` (UI + AX), `rewrite_prompt.py` (LLM). | Each has one clean owner. Hammerspoon's existing AX grant is unchanged. The Swift app needs a **separate** AX grant of its own — TCC does not share across apps. |

## 2. Architecture

```
┌─────────────┐  open promptrewriter://    ┌────────────────────────────┐
│ Hammerspoon │──── via hs.execute ───────▶│      PromptRewriter.app    │
│   (hotkey)  │                            │  (SwiftUI menu bar helper) │
└─────────────┘                            │   LSUIElement, self-signed │
                                           └─────────────┬──────────────┘
                                                         │
                                  ┌──────────────────────┼────────────────────┐
                                  │                      │                    │
                          ApplicationServices       Process / Pipe      AppKit (NSPanel)
                            (AX read/write)              │                    │
                                  │                      ▼                    ▼
                          [Source app text]    rewrite_prompt.py        Popup window
                                              (stdin → Ollama → stdout)
```

- **Hammerspoon (existing).** The eventtap for `fn+Ctrl+R` is repurposed to launch the popup app via `hs.execute("open promptrewriter://capture")`. No more spawning Python directly; Hammerspoon's role shrinks to "hotkey forwarder".
- **`PromptRewriter.app` (new).** A `LSUIElement` (no Dock icon) menu bar helper, self-signed via `codesign --sign -` for personal use. Stays running idle after first launch; subsequent hotkey presses just reach the running instance via URL scheme.
- **`rewrite_prompt.py` (refactored).** Replace `pyperclip.paste()` / `pyperclip.copy()` with `sys.stdin.read()` / `print(...)`. Drop the `osascript` notification call. Drop the wrapping-quote and `<think>` cleanup ONLY if Swift takes them over — keep them in Python; Swift trusts the output as-is.

## 3. Components inside `PromptRewriter.app`

| Component | Responsibility | Touches |
|---|---|---|
| `AppDelegate` | URL scheme handler registration, app lifecycle, shared state. | NSApplication |
| `HotkeyCoordinator` | Receives URL events. 200 ms debounce. Initiates `CaptureFlow`. | — |
| `CaptureFlow` | State machine orchestrating: snapshot focus → capture selection → show popup → call rewriter → handle action. | AXBridge, OllamaClient, PopupWindowController |
| `AXBridge` | Only place that calls `ApplicationServices`. Functions: `captureSelection()`, `replaceSelection(_:in:)`, `currentFocus()`, `isPasswordField(_:)`. | ApplicationServices.framework |
| `OllamaClient` | `rewrite(_: String) async throws -> String`. Spawns Python CLI via `Process`. On `Task.cancel()` or 30 s timeout, calls `process.terminate()` so the child is actually killed (Swift cancellation alone does not stop the child). | Foundation.Process |
| `PopupWindowController` | Owns the non-activating `NSPanel`. Positions near the focused element. | AppKit |
| `PopupView` + `LoadingView`, `ResultView`, `ErrorView` | Pure SwiftUI driven by `@Observable PopupState`. | SwiftUI |

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

enum PopupState {
    case loading(sourceText: String, isLong: Bool)
    case result(original: String, rewritten: String, canReplace: Bool)
    case error(ErrorKind)
}
```

### Boundary rule

Only `AXBridge` calls AX APIs. Only `OllamaClient` spawns the Python process. Only `PopupWindowController` instantiates AppKit windows. Everything else is plain Swift, unit-testable.

## 4. Happy-path data flow

1. User selects text in any app.
2. User presses `fn+Ctrl+R`.
3. Hammerspoon: `hs.execute("open promptrewriter://capture")`.
4. Swift `AppDelegate.application(_:open:)` receives the URL → forwards to `HotkeyCoordinator.handle()`.
5. `AXBridge.captureSelection()` returns `SelectionSnapshot` (≤ 200 ms target).
6. `PopupWindowController.show(state: .loading(sourceText, isLong: text.count > 4000))`. Non-activating panel appears anchored to the focused element's screen rect.
7. `OllamaClient.rewrite(snapshot.text)` runs as a `Task`. Spawns `.venv/bin/python3 rewrite_prompt.py`, writes stdin, reads stdout to EOF. 30 s timeout via `Task` cancellation.
8. Stdout arrives. State → `.result(original, rewritten, canReplace: !isOutputTooLong)`.
9. User chooses:
   - **Enter / Replace** → `AXBridge.replaceSelection(rewritten, in: snapshot.focusedElementRef)` with focus re-validation. AX write first; fall back to synthetic Cmd+V + clipboard save/restore on failure.
   - **Cmd+C / Copy** → `NSPasteboard.general` write, popup closes.
   - **Esc / Cancel** → popup closes, no side effects.
10. Helper stays running, idle, in menu bar.

## 5. Text-length policy

| Threshold | Value | Behavior |
|---|---|---|
| Input soft-warn | 4,000 chars | LoadingView shows "Long input — may be slow" badge. Proceed. |
| Input hard-reject | 16,000 chars | Hard reject before LLM call. ErrorView. |
| Output soft-warn | 8,000 chars | Visual indicator in ResultView. Replace still available. |
| Output hard-reject | 32,000 chars | Replace disabled (Copy only). Warning shown. |

Char-based (not token-based) to keep the UI layer free of a tokenizer dependency.

## 6. Error and edge-case behavior

| Failure | Behavior |
|---|---|
| Empty / whitespace-only selection | `ErrorView("Select some text first")`. Auto-dismiss after 2 s. |
| Password field (`AXIsPasswordField` true) | Refuse outright. `ErrorView("Won't read from password fields")`. |
| AX read returns nil | Try clipboard-roundtrip fallback (save clipboard, post Cmd+C, read, restore). If still nil → `ErrorView("Can't read selection in this app")`. |
| Input > 16,000 chars | Hard reject. `ErrorView("Selection too long (X chars; max 16,000)")`. |
| Input 4,000–16,000 chars | Soft warn badge in LoadingView. Proceed. |
| Ollama down (`ConnectionError`) | `ErrorView("Ollama isn't running. Start it and click Retry.")` + Retry button. |
| Generation > 30 s | Cancel Process. `ErrorView("Timed out. Retry?")`. |
| Empty / whitespace stdout from Python | `ErrorView("Empty rewrite. Retry?")`. |
| Output > 32,000 chars | Replace disabled, Copy enabled, warning shown. |
| Focus changed during generation | On Replace click: detect mismatch via `currentFocus()`. Replace disabled. `WarnView("Original field lost focus; Copy only")`. |
| AX write fails | Automatic fallback: clipboard save → write rewrite → synthetic Cmd+V → restore clipboard after 500 ms delay. If Cmd+V also fails → leave rewrite on clipboard, `WarnView("Couldn't replace; rewrite is on your clipboard")`. |
| AX permission missing | On every app launch, call `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)`. If false, show a modal with a deep-link button to System Settings → Privacy & Security → Accessibility and quit when dismissed. The modal does not auto-dismiss when the user toggles the switch — they must relaunch. |
| Re-trigger while popup open | `Task.cancel()` on in-flight rewrite. Re-run capture. 200 ms debounce. |
| Esc / outside-click during loading | Cancel Task. Close popup. No notification. |
| Python script missing / venv broken | `OllamaClient` surfaces stderr. `ErrorView("Backend unavailable: <stderr>")`. |

## 7. Permissions surface

| Permission | Who holds it today | Who needs it after this change |
|---|---|---|
| Accessibility (read text fields, post events) | Hammerspoon | Hammerspoon **and** `PromptRewriter.app` (new grant required) |
| Input Monitoring | None | None — global hotkey stays in Hammerspoon, not a CGEventTap in the Swift app |
| Automation (AppleScript) | Hammerspoon (`hs.allowAppleScript`) | Same |

The Swift app's AX grant lets it read any text field and post any keystroke system-wide. This is a meaningfully broader trust surface than the current Hammerspoon-only setup. Acceptable for personal use; documented here as a known risk.

## 8. Testing strategy

### Swift unit tests (XCTest)
- `cleanModelOutput` Swift port (defense in depth, even though Python does it at runtime)
- Length-policy boundary tests (3 999 / 4 000 / 4 001, 15 999 / 16 000 / 16 001)
- URL-scheme parser
- `PopupState` transition tests
- `OllamaClient` Process invocation with a mock binary script

### Swift integration tests
- `CaptureFlow` with mocked `AXBridge` and `OllamaClient` (protocols, not concretes).
- Exercises every error path in section 6 deterministically.

### Manual smoke tests (documented; cannot be unit-tested cleanly)

| Scenario | Expected |
|---|---|
| Select in TextEdit → hotkey → Replace | Text replaced in place. |
| Select in Safari article body → hotkey → Replace | AX write fails; auto-fallback to Cmd+V works OR Copy fallback offered. |
| Select in password field → hotkey | Refused with explanatory error. |
| Click into another app between popup appearing and Replace | Replace disabled; Copy still works. |
| Kill `ollama` process → hotkey | "Ollama isn't running" error; Retry returns to loading after `ollama serve` is up. |
| Spam hotkey 5× rapidly | Only one popup; in-flight rewrites cancelled. |
| Select 17,000-char paragraph → hotkey | Hard reject without LLM call. |
| Select empty | "Select some text first" error. |

### Python
Existing approach preserved. Refactored `rewrite_prompt.py` is exercised via `echo "test" | python3 rewrite_prompt.py` and the 5 spec test cases from the original build (broken grammar, vague, already-good, mixed VI/EN, empty stdin).

## 9. File layout

```
~/repos/prompt-rewriter/
├── rewrite_prompt.py        # refactored: stdin → stdout, no clipboard, no notify
├── requirements.txt         # unchanged
├── install.sh               # extended: also build/signs the Swift app
├── .venv/                   # unchanged
├── README.md                # updated for popup workflow
├── docs/superpowers/specs/
│   └── 2026-05-27-popup-ui-design.md   ← this file
└── PromptRewriter/          # NEW
    ├── PromptRewriter.xcodeproj
    ├── PromptRewriter/
    │   ├── PromptRewriterApp.swift         # @main, AppDelegate
    │   ├── HotkeyCoordinator.swift
    │   ├── CaptureFlow.swift
    │   ├── AXBridge.swift
    │   ├── OllamaClient.swift
    │   ├── PopupWindowController.swift
    │   ├── PopupState.swift
    │   ├── Views/
    │   │   ├── PopupView.swift
    │   │   ├── LoadingView.swift
    │   │   ├── ResultView.swift
    │   │   └── ErrorView.swift
    │   ├── Info.plist                       # URL scheme, LSUIElement, AX usage description
    │   └── PromptRewriter.entitlements
    └── PromptRewriterTests/
        ├── CleanOutputTests.swift
        ├── LengthPolicyTests.swift
        ├── PopupStateTests.swift
        ├── URLSchemeTests.swift
        └── CaptureFlowTests.swift            # uses mock AXBridge & OllamaClient
```

## 10. Out of scope for v1

- Streaming token-by-token rendering. (Block until full response; revisit if perceived latency feels bad on cold start.)
- Selection-context-aware prompt templates (different prompts for code vs prose vs markdown).
- Rewrite history / undo log.
- Code signing for distribution beyond `codesign --sign -` self-signing.
- Settings UI for model selection, temperature, prompt customisation. (Edit `rewrite_prompt.py` for now.)
- Multi-language prompt rewriting from the popup. (Existing Vietnamese-input behavior of the LLM still applies.)
- Stats / telemetry.
- Auto-start at login. The user runs the app manually (or it is launched by Hammerspoon on first hotkey press). Adding a Login Item is a one-line `SMAppService` call that can be revisited if cold-start latency on first daily use becomes annoying.

## 11. Open risks (carried from BA analysis)

- **Wrong-target replacement.** Focus shifts during the 1–2 s generation, Replace fires into the wrong field. Mitigated by focus snapshot + re-validation, but a race window remains under fast context switching.
- **Clipboard pollution.** Both the clipboard-roundtrip capture fallback and the synthetic Cmd+V replace fallback transiently mutate the pasteboard. A failure mid-flow can silently leave the user's prior clipboard wiped. Mitigation: try/finally with restore.
- **AX permission expansion.** A second AX-trusted app system-wide.
- **Hammerspoon coupling.** A syntax error in `init.lua` after a future edit silently breaks the popup with no UI signal. Mitigation: Hammerspoon's own Console shows errors; README will document checking it first when the hotkey is dead.

## 12. Next step after this spec is approved

Invoke the `superpowers:writing-plans` skill to produce a step-by-step implementation plan. No code is written until the plan is also approved.

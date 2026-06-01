# Autocomplete Coverage + Controls (feat-015) — Design

**Date:** 2026-06-01
**Status:** Draft — awaiting approval before implementation.
**Feature ID:** feat-015 (Phase 2 autocomplete controls)
**Depends on:** feat-013 (autocomplete core, now closed).

> **Inheritance note.** feat-013 was closed on a *visual* TextEdit check;
> Tab-insert, password exclusion, Notes/WebKit positioning, and multi-monitor were
> deferred, **not verified**. The **word-by-word** slice below re-anchors the ghost
> on every Tab and therefore inherits feat-013's positioning quality on each accept.
> Its robustness is **bounded by that deferred work** — this spec does not re-open it.

## Goal

Five Phase-2 controls that make always-on autocomplete usable day-to-day, layered on
the feat-013 core without changing the core prediction loop:

1. **Word-by-word Tab** — Tab takes the next word of the suggestion; repeat to take
   more; keep typing to adjust. (Today Tab inserts the whole suggestion at once.)
2. **Per-app allow/deny list** — silence prediction in user-chosen apps.
3. **Clean non-AX degrade** — stop thrashing AX for fields that never return caret
   bounds, instead of re-querying every keystroke.
4. **Suggestion-length presets** — Short / Medium / Long, mapped to the predict
   call's `num_predict`.
5. **Menu-bar pause toggle** — one click silences all prediction.

Non-goal: typo correction, emoji, on-device vocab learning — those are feat-016.

## Verified architecture (read before designing)

- **`AXBridge.insertAtCaret` → `replaceSelection`** (`AXBridge.swift:105`,`324`):
  **AX write first** (`AXUIElementSetAttributeValue(kAXSelectedTextAttribute)` →
  `.okAX`); on failure, **clipboard + synthetic Cmd+V** (`postCmdV`, posts to
  `.cghidEventTap`) → `.okPaste`. The synthetic Cmd+V **is visible to our
  `.cgSessionEventTap`.** → *Implication for word-by-word below.*
- **`FocusSnapshot`** (`AXBridge.swift:20`) already carries `appBundleID` — per-app
  policy needs **no** new AX plumbing. `currentFocus()` derives it from
  `NSWorkspace.shared.frontmostApplication`.
- **`Predicting`** (`Predictor.swift:3`) has exactly **two** conformers:
  `OllamaPredictor` and the test `MockPredictor`. A signature change ripples to those
  two and nowhere else. `num_predict` is hardcoded at `12` (`Predictor.swift:34`).
- **Event-tap accept path** (`HotkeyEventTap.swift:163`): on Tab with a visible
  suggestion → `setAutocompleteSuggestionVisible(false)` **then** dispatches
  `onAutocompleteAccept`. Word-by-word must keep the suggestion visible across a
  partial accept (see below).
- **`AutocompleteController.accept()`** (`AutocompleteController.swift:81`) inserts
  `currentSuggestion` whole and `stop()`s.

## Slice designs

### Sequencing (intentional)

Slices **2–5 are positioning-independent** and ship first, each as its own commit
with its own verification. **Word-by-word (slice 1) ships last** so the four easy
wins aren't held hostage by the one slice that inherits feat-013's deferred
positioning. Implementation order: **4 (presets) → 5 (pause) → 2 (deny) → 3 (degrade) → 1 (word-by-word).**

### Slice 4 — Suggestion-length presets

- New `Preferences.SuggestionLength` enum: `.short`, `.medium`, `.long`, persisted
  via a new key + `Change.suggestionLength` case. **Default `.medium`** (matches
  today's `num_predict 12`).
- `Predicting.suggest` gains a parameter. Chosen shape:
  `suggest(prefix:model:maxTokens:)` — a plain `Int`, not an options struct (only one
  new knob; YAGNI on a struct). `OllamaPredictor` passes it to `Options.numPredict`;
  `MockPredictor` ignores it.
- **Token mapping** (decision, see below): `.short → 10`, `.medium → 18`,
  `.long → 32`. (`num_predict` is a token cap, not a word count; the `stop: ["\n"]`
  already truncates at the first line. These caps approximate 3–7 / 7–12 / 12–20
  words at ~0.6 words/token for English.)
- `AutocompleteController.beginPrediction` reads the preset and passes the mapped cap.
- Settings: a `Picker` in `SettingsView` bound to the preset.

### Slice 5 — Menu-bar pause toggle

- **Decision: session-only** (resets to *active* on relaunch). Rationale: a pause that
  silently persists across restarts becomes a "why are there no suggestions?" support
  trap — the exact case feat-017 exists to prevent. In-memory state on `AppDelegate`
  (or a small `@MainActor` holder), **not** a `Preferences` key.
- `StatusBarController.rebuildMenu` adds a checkable **"Pause Suggestions"** item
  (it already rebuilds on `refresh()`). Toggling flips the in-memory flag and calls a
  new `onTogglePause` closure wired in `OwletApp`.
- `AutocompleteController` gains a `pausedProvider: () -> Bool` (same pattern as
  `enabledProvider`); `textChanged()` short-circuits via `stop()` when paused.
- Toggling pause **on** calls `controller.stop()` to clear any visible ghost.

### Slice 2 — Per-app allow/deny list

- **Decision: default-allow + denylist** (block specific apps). Least surprising for
  an always-on feature; an allowlist would silently disable Owlet everywhere until
  configured.
- `Preferences.autocompleteDeniedApps: Set<String>` (bundle IDs) + `Change` case,
  persisted as `[String]`.
- Gate in `beginPrediction` **before** the network call:
  `guard !Preferences.shared.autocompleteDeniedApps.contains(focus.appBundleID)`.
- Settings UI: minimal first cut — show the **current focused app's** bundle ID with
  an "Exclude this app" button + a list of excluded apps with remove. (A full running-
  apps picker is more than this slice needs; note as possible follow-up.)

### Slice 3 — Clean non-AX degrade

- Symptom today: a field that never returns caret bounds (`caretScreenRect == nil`)
  causes `beginPrediction` to re-read AX on **every keystroke** and hide — wasteful,
  not broken.
- Fix: cache an **"unsupported"** marker keyed by the focused element; when set, skip
  the AX caret read + prediction entirely. **Reset on focus change** (compare against
  the last focused element via the existing `AXUIElementsEqual`/`CFEqual`).
- Pure, testable: add a small decision helper so the cache/reset logic is unit-tested
  without a live AX tree.

### Slice 1 — Word-by-word Tab accept (last)

- `cleanSuggestion` output is split into word tokens **preserving leading
  whitespace** (the existing comment at `AutocompleteController.swift:142` warns
  leading spaces are semantic). Tokenization: split so that re-joining the parts is
  identity (each part = optional leading spaces + one word).
- State: `private var remainingWords: [String]` + the already-inserted text. On Tab:
  insert the next token via `insertAtCaret`, append to inserted text, drop it from
  `remainingWords`. If `remainingWords` becomes empty → `stop()`. Otherwise **re-show**
  the remainder ghost at the **re-anchored** caret rect (fresh `readCaretContext`).
- **AX-write gating (load-bearing):** word-by-word only stays in partial-accept mode
  when the insert returns **`.okAX`** (no synthetic events, tap not re-entered). If the
  insert returns **`.okPaste`**, the synthetic Cmd+V re-enters our session tap and
  would dismiss the ghost / kick a new prediction — so on `.okPaste` we **insert the
  whole remaining suggestion and `stop()`** (degrade to today's whole-accept). This is
  explicit, not silent.
- Event tap: `onAutocompleteAccept` must **not** force-hide when words remain. Today
  `HotkeyEventTap` sets `autocompleteSuggestionVisible = false` before dispatching
  accept. Change: the controller calls back to `setAutocompleteSuggestionVisible(true)`
  after a partial accept (the controller already drives visibility via
  `onVisibilityChanged`). Verify the Tab→accept round-trip keeps Tab live for the next
  word.
- **Positioning caveat (state in code + evidence):** re-anchor uses the same
  `readCaretContext` path feat-013 left only visually verified; in WebKit/Notes the
  degenerate rect means the remainder ghost may not reposition. Acceptable for this
  slice; tracked as the feat-013 inheritance, not a new bug.

## Decisions surfaced (recommended values in **bold**)

| # | Decision | Options | Recommendation |
|---|----------|---------|----------------|
| D1 | Pause persistence | session-only / persist across restart | **session-only** |
| D2 | App policy default | default-allow+denylist / default-deny+allowlist | **default-allow + denylist** |
| D3 | Preset → `num_predict` | token caps per tier | **short 10 / medium 18 / long 32** |
| D4 | Length param shape | `Int maxTokens` / options struct | **`Int maxTokens`** (YAGNI) |

If the user disagrees with any, only the named slice changes — they're independent.

## Verification (per slice, per CLAUDE.md "evidence per layer")

- **Unit (headless, authoritative for logic):** `xcodebuild test … -scheme Owlet`.
  New tests: preset→token mapping; pause short-circuits `textChanged`; denylist gates
  `beginPrediction`; unsupported-field cache set/reset on focus change; word
  tokenizer round-trips (join == original) + partial-accept advances/stops + `.okPaste`
  degrades to whole-accept (via `MockAXBridging` returning `.okPaste`).
- **Manual (user-only, GUI):** Settings shows the preset picker + excluded-apps list;
  menu-bar "Pause Suggestions" silences ghosts and unchecks on relaunch; in TextEdit
  Tab takes one word at a time and continued typing adjusts.

## Out of scope

- feat-016 (typo correction, emoji, vocab learning).
- Re-opening feat-013 positioning (Notes/WebKit/multi-monitor) — inherited, not fixed.
- A full running-apps picker for the denylist (minimal focused-app exclusion only).
- Streaming/partial-token rendering of the suggestion.

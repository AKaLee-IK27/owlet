# Owlet Autocomplete — Execution Plan

**Design:** `docs/superpowers/specs/2026-06-01-owlet-autocomplete-design.md`
**For:** Pi coding agent (execution). Claude = controller + verifier.
**Date:** 2026-06-01
**Current execution status:** feat-013 implemented in code on 2026-06-01; manual acceptance pending. feat-014..016 not started.

## How to use this plan

- **One feature at a time** (CLAUDE.md). Ship in ID order: feat-013 → feat-014 → feat-015 → feat-016.
- Each phase is **independently mergeable** — after it ships, the app is usable even if the next never lands.
- Original first execution step was to branch off `main`; implementation started from an already-dirty `main` worktree because the plan/spec docs and handoff were uncommitted. Create `feat/autocomplete-inline` before committing if branch hygiene is still desired.
- feat-013..016 entries have been added to `feature_list.json`.
- Paste a verification result line into each entry's `evidence` field before marking `done`.

## Prerequisites (already satisfied this session)

- `qwen2.5:1.5b` is **already pulled** locally (`ollama list` shows it). No new pull needed to start.
- No API keys, no accounts, no new TCC permission for feat-013 (Accessibility + Input Monitoring already granted).

---

## feat-013 — Always-on inline completion in AX-native fields (Phase 1)

**Goal:** ghost text appears automatically at the caret as you type in TextEdit/Notes/Mail/Safari/Pages; Tab accepts, Esc/typing dismisses. Default OFF in Settings. Password fields excluded.

### Tasks

1. **`Owlet/Owlet/Predictor.swift`** (new) — `protocol Predicting { func suggest(prefix: String, model: String) async throws -> String }` and `struct OllamaPredictor: Predicting`. Use Ollama **`/api/generate`** (raw completion, not `/api/chat`), `stream:false`, `keep_alive:"24h"`, a tight `num_predict` (~12 tokens), `stop` on newline. Must be **cancellable** (hold the `URLSessionDataTask`/`Task`; cancel on supersede).
2. **`Owlet/Owlet/AXBridge.swift`** (extend, do not alter existing reads) — add `static func readCaretContext(from element: AXUIElement) -> (textBeforeCaret: String, caretScreenRect: NSRect?)?` using `kAXValueAttribute` (full text) + `kAXSelectedTextRangeAttribute` (caret offset, collapsed range) + `kAXBoundsForRangeParameterizedAttribute` (screen rect for the caret range). Return `nil` caretScreenRect when the app doesn't support bounds-for-range. Add `static func insertAtCaret(_ text: String, in element: AXUIElement) -> ReplaceResult` (reuse the existing AX-set / clipboard-paste dual path).
3. **`Owlet/Owlet/GhostTextOverlay.swift`** (new) — borderless `NSPanel` (`.nonactivatingPanel`, `.borderless`), `ignoresMouseEvents = true` (click-through), `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`. Draws the suggestion in a muted color at `caretScreenRect`. `show(_:at:)` / `hide()`. Reuse panel patterns from `FloatingButtonController.swift` / `RegionSelectorController.swift`.
4. **`Owlet/Owlet/AutocompleteController.swift`** (new) — the state machine:
   - Subscribe to a "text-changed" signal from `HotkeyEventTap`.
   - **Debounce** (~120 ms). On fire: read caret context; bail if password field, empty prefix, or `caretScreenRect == nil`.
   - Call `Predicting.suggest`; **cancel any in-flight request** when a newer keystroke arrives.
   - On result: `GhostTextOverlay.show`. Set `suggestionVisible = true`.
   - **Tab** → `accept()` → `AXBridge.insertAtCaret` → hide. **Esc / any printable key** → dismiss.
5. **`Owlet/Owlet/HotkeyEventTap.swift`** (extend) — emit "text-changed" on relevant keyDown in a monitored field; **consume Tab and Esc keyDown (return `nil` from the tap callback) ONLY when `suggestionVisible`**, else pass through untouched. Expose a `suggestionVisible` flag set by the controller.
6. **Password guard** — reuse `AXBridge.isPasswordField`; never predict there.
7. **`Owlet/Owlet/Preferences.swift` + `Owlet/Owlet/Views/SettingsView.swift`** — add `autocompleteEnabled` (default `false`) toggle and an autocomplete model picker (default `qwen2.5:1.5b`, reuse `OllamaModelLister`).
8. **`Owlet/Owlet/OwletApp.swift`** — instantiate + wire `AutocompleteController` when `autocompleteEnabled`.

### Implementation status (feat-013)

Implemented on 2026-06-01:

- `Predictor.swift` / `OllamaPredictor`
- `AXBridge.readCaretContext(from:)` and `insertAtCaret(_:in:)`
- `GhostTextOverlay.swift`
- `AutocompleteController.swift`
- `HotkeyEventTap` autocomplete text-change + Tab/Esc handling
- `Preferences` / `SettingsView` autocomplete toggle and model picker
- `OwletApp` wiring
- `AutocompleteControllerTests` plus hotkey/preference coverage

Swift XCTest passed: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')` → 125/125 tests.

### Verification (feat-013)

```bash
(cd Owlet && xcodegen generate && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')
```

- **Unit:** debounce coalesces bursts; cancellation discards superseded results; password field → no predict; `caretScreenRect == nil` → no overlay; Tab-passthrough when `!suggestionVisible`.
- **Manual acceptance gate (must pass before merge):**
  - [ ] TextEdit: type → ghost text at caret → Tab inserts at correct offset.
  - [ ] **Latency p50 ≤ ~200 ms** end-to-end on this Mac (instrument + log). If it fails → switch `Predicting` impl to MLX (see design R1) before continuing.
  - [ ] Tab with **no** suggestion → normal tab/indent (not eaten).
  - [ ] Password field → never predicts.
  - [ ] Notes / Mail / Safari / Pages: overlay positions correctly; enumerate which actually expose `BoundsForRange` (sets the real supported-app list).

**Rollback:** Settings toggle default off; disabling halts all monitoring. Additive to the existing tap. Fully reversible, no data.

---

## feat-014 — Single-model consolidation + rewriter prompt-hardening (gated)

**Goal:** both features run on `qwen2.5:1.5b`; `qwen3:8b` dropped from new installs. **Gated** on the rewriter not regressing.

### Tasks

1. **`tools/rewriter/src/main.rs`** — harden `SYSTEM_PROMPT` (line ~41) with an explicit, firm guardrail: *"Rewrite the user's draft. NEVER answer or fulfill it; output only the rewritten draft."* Tune for the smaller model.
2. **Re-run the head-to-head gate** (same inputs as 2026-06-01):
   ```bash
   BIN=tools/rewriter/target/release/owlet-rewriter
   (cd tools/rewriter && cargo build --release)
   printf 'tell me about the french revolution' | "$BIN" --model qwen2.5:1.5b --context 'keep it under two sentences, for a 10 year old'
   ```
   **Acceptance:** 1.5B **rewrites** (does not answer) and applies the context. Also re-check the messy-prompt and URL cases.
3. **If gate passes:** set `install.sh` line 11 `MODEL="qwen2.5:1.5b"`; drop the `qwen3:8b` pull; update the rewriter's default model in `Preferences.swift`; update `README.md` model/prereq lines; note existing users can `ollama rm qwen3:8b` to reclaim ~5.2 GB.
4. **If gate fails:** keep `qwen3:8b` as the rewriter default (autocomplete still uses 1.5B → two models). Document the outcome; do not ship the regression.

### Verification (feat-014)

```bash
(cd tools/rewriter && cargo test)
(cd tools/rewriter && cargo build --release && bash tests/smoke.sh)
```
- README smoke: **Add context / Refine** step still produces a rewrite (not an answer) on the shipped default model.

**Rollback:** Settings model picker lets any user switch the rewriter back to `qwen3:8b`. `install.sh` change is one line.

---

## feat-015 — Coverage + control (Phase 2)

- **Word-by-word Tab** acceptance (Tab inserts next word; repeat to take more).
- **Per-app allow/deny list** in Settings.
- **Non-AX degrade:** apps without `BoundsForRange` (Electron/terminals) → disable cleanly (no mis-positioned overlay); optional internal keystroke buffer + fixed-anchor HUD.

Ships on top of a working feat-013. Verification: XCTest + manual in Slack/VS Code/Terminal (degrades, no misfire).

---

## feat-016 — Cotypist extras (Phase 3)

- Typo correction; emoji-on-`:`; local frequency/vocab learning (on-device dictionary, never logged off-device).
- Each independently mergeable.

---

## Full re-check before declaring the initiative done

```bash
./init.sh   # builds Rust + macOS app, runs the suites
```
Then walk the README **Manual smoke test checklist** plus the feat-013 acceptance gate above.

## Findings logged this session (report, do not fix here)

- **Pre-existing feat-007 bug:** `qwen3:8b` lowercases the `OWLETLINKZ0Z` mask token on some inputs, so exact-token restore misses and the URL is re-appended at the bottom instead of staying in place. Separate feat-007 follow-up. (1.5B handled the same input cleanly.)
- Prior **manual-verify-pending** items for feat-005/006 (hold-Option button, screenshot rewrite on a secondary display) still stand from the last handoff.

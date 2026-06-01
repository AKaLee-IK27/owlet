# Session Handoff

## Current Objective

- **Goal:** Execute the **Owlet Autocomplete** initiative — Cotypist-style always-on inline completion.
- **Status:** **feat-013 implemented; manual run FAILED on caret positioning, under active debug.** The prediction loop and Tab/Esc/guard logic are unit-tested and prediction reaches Ollama, but at runtime the ghost text renders far from the caret even in TextEdit, so accept/dismiss are not meaningfully testable yet. A Quartz→Cocoa coordinate flip was added (`AXBridge.cocoaRect(fromAXRect:)`) and did **not** fix it on a single Retina display, so `caretCocoaRect` now carries temporary `caretgeom` diagnostic logging. feat-014..016 not started.
- **Branch / commit:** work is still uncommitted on `main` (including the temp diagnostic). If you want a feature branch, create it before committing: `git checkout -b feat/autocomplete-inline`.

## Read these first

1. **Design / spec:** `docs/superpowers/specs/2026-06-01-owlet-autocomplete-design.md`
2. **Execution plan:** `docs/superpowers/plans/2026-06-01-owlet-autocomplete.md`
3. Project rules: `CLAUDE.md` (one feature at a time; spec→plan→ship; evidence before done).

## What changed for feat-013

- Added `Owlet/Owlet/Predictor.swift`
  - `Predicting` protocol
  - `OllamaPredictor` using Ollama `/api/generate`, `stream:false`, `keep_alive:"24h"`, short `num_predict`, newline stop.
- Added `Owlet/Owlet/AutocompleteController.swift`
  - 120 ms debounce, cancellation of superseded predictions, password-field guard, missing-caret-rect guard, default-off preference gate.
  - `accept()` inserts the visible suggestion; `dismiss()`/typing hides it.
- Added `Owlet/Owlet/GhostTextOverlay.swift`
  - click-through `.nonactivatingPanel` overlay that draws muted ghost text at the caret.
- Extended `Owlet/Owlet/AXBridge.swift`
  - `readCaretContext(from:)` via `kAXValueAttribute`, `kAXSelectedTextRangeAttribute`, `kAXBoundsForRangeParameterizedAttribute`.
  - `caretCocoaRect` / `cocoaRect(fromAXRect:)`: flips the caret rect from Quartz (top-left origin) to Cocoa (bottom-left origin), with a char-before-caret bounds fallback. **Carries temporary `caretgeom` diagnostic logging for the open positioning bug; remove after fix.**
  - `insertAtCaret(_:in:)` reuses the existing AX-selected-text / paste fallback path.
  - `isPasswordField` made reusable.
- Added `Owlet/OwletTests/AXBridgeGeometryTests.swift` (3 pure-flip tests).
- Extended `Owlet/Owlet/HotkeyEventTap.swift`
  - emits text-change notifications for text-changing keys.
  - consumes Tab/Esc **only** while a suggestion is visible; otherwise passes through.
- Extended `Preferences` + `SettingsView`
  - `autocompleteEnabled` default false.
  - `autocompleteModel` default `qwen2.5:1.5b`.
- Wired `OwletApp.swift` to keep one `AutocompleteController` attached to the existing event tap.
- Added tests in `Owlet/OwletTests/AutocompleteControllerTests.swift` and expanded hotkey/preference tests.
- Updated `README.md`, `feature_list.json`, and `progress.md`.

## Verification run this session

```bash
(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')
# PASS — 125/125 tests passed on 2026-06-01
```

## Open bug: ghost text misplaced (blocks feat-013)

Manual run on 2026-06-01 (single built-in Retina display): autocomplete is enabled, Ollama is up, `qwen2.5:1.5b` returns completions, and a ghost **does** appear, but **far from the caret**, not next to it. The coordinate flip alone did not fix it, which rules out the simple top-left/bottom-left mirror as the whole story. The `caretgeom` diagnostic is in place to capture the real numbers.

**Resume here:**
1. Restart Owlet (new binary must be loaded), type in TextEdit, then read the log:
   `log show --last 2m --predicate 'subsystem == "co.greenpassport.owlet" AND category == "caretgeom"' --info`
2. Compare `zeroRaw` / `charRaw` (raw AX rect) against `cocoa` (converted) and the known caret position. Likely suspects: the zero-length `kAXBoundsForRange` returning element-origin or `.zero` (so it falls to char-before), an unexpected coordinate space from TextEdit, or an X-axis error rather than Y.
3. Fix the mapping, **remove the `caretgeom` diagnostic logging**, re-run the TextEdit check.

## Manual acceptance still required before merging feat-013

- [ ] **FAILING:** TextEdit, ghost text appears *at* the caret (currently lands away from it). Fix the open bug above first.
- [ ] **Tab** inserts the suggestion at the correct offset; **Tab with no suggestion** passes through.
- [ ] **Esc** or continued typing dismisses the suggestion.
- [ ] Password fields never predict.
- [ ] Measure p50 end-to-end latency; target ≤ ~200 ms.
- [ ] Notes / Mail / Safari / Pages: record which expose caret bounds and position correctly.

If latency misses the gate, do **not** expand scope; switch the `Predicting` implementation to the MLX fallback described in the design.

## Next implementation steps

1. Fix the ghost-position bug (read the `caretgeom` log), remove the diagnostic, finish feat-013 manual acceptance, then update `feature_list.json` evidence.
2. Then start **feat-014** only if feat-013 is acceptable: rewriter prompt-hardening + gated `qwen2.5:1.5b` consolidation.
3. Keep feat-015/016 deferred until feat-013 and feat-014 gates are resolved.

## Carried-over / independent follow-ups

- Pre-existing feat-007 bug: `qwen3:8b` can lowercase `OWLETLINKZ0Z`, causing URL restore to miss and re-append at the bottom.
- feat-005/006 manual verification on a multi-monitor setup remains pending.

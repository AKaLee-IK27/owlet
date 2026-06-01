# feat-015 Autocomplete Coverage + Controls — Execution Plan

**Spec:** `docs/superpowers/specs/2026-06-01-autocomplete-coverage-design.md`
**Decisions (approved 2026-06-01):** D1 session-only pause · D2 default-allow+denylist ·
D3 short10/med18/long32 · D4 `Int maxTokens`.

Each slice = one commit, its own tests, Swift suite green before the next. Order is
positioning-independent first, word-by-word last.

## Slice 4 — Length presets  *(start here)*
1. `Preferences`: add `SuggestionLength` enum (`short`/`medium`/`long`), `Change.suggestionLength`,
   `suggestionLength` accessor (default `.medium`), token mapping `maxTokens` (10/18/32).
2. `Predicting.suggest(prefix:model:)` → `suggest(prefix:model:maxTokens:)`; update
   `OllamaPredictor` (`numPredict = maxTokens`) and `MockPredictor`.
3. `AutocompleteController.beginPrediction` passes `Preferences.shared.suggestionLength.maxTokens`.
4. `SettingsView`: `Picker` bound to the preset.
5. Tests: enum→token mapping; controller passes the mapped value (assert via mock).

## Slice 5 — Pause toggle
1. In-memory pause holder (`@MainActor`), wired in `OwletApp`; **not** persisted.
2. `AutocompleteController` gains `pausedProvider`; `textChanged()` `stop()`s when paused;
   toggling on calls `stop()` to clear the ghost.
3. `StatusBarController`: checkable "Pause Suggestions" item + `onTogglePause` closure.
4. Tests: paused `textChanged` produces no prediction (mock predictor not called).

## Slice 2 — Per-app denylist
1. `Preferences.autocompleteDeniedApps: Set<String>` (persist as `[String]`) + `Change` case.
2. `beginPrediction` guards on `focus.appBundleID` before the network call.
3. `SettingsView`: focused-app bundle ID + "Exclude this app" + excluded list with remove.
4. Tests: denied bundle ID → no prediction; allowed → proceeds (mock).

## Slice 3 — Non-AX degrade
1. Cache "unsupported" element (caret rect nil) keyed by focused element; reset on focus change.
2. Pure decision helper for the cache/reset; skip AX read + prediction when cached.
3. Tests: repeated keystrokes on an unsupported field query AX once; focus change clears it.

## Slice 1 — Word-by-word Tab  *(last)*
1. Tokenizer: split suggestion into leading-space-preserving word parts; `join == original`.
2. Controller partial-accept state (`remainingWords`, inserted text); Tab inserts next token.
3. **AX-write gating:** `.okAX` → stay in partial-accept + re-anchor + keep Tab live
   (`setAutocompleteSuggestionVisible(true)`); `.okPaste`/`.failed` → insert remainder whole + `stop()`.
4. Verify `HotkeyEventTap` keeps Tab routed to accept across partial accepts.
5. Tests: tokenizer round-trip; partial-accept advances then stops; `.okPaste` degrades to whole-accept.

## Definition of done (feat-015)
- All slices implemented; Swift suite green after each.
- `feature_list.json` evidence + `progress.md` updated; spec/plan committed.
- Manual GUI checklist (user-only) noted, not faked: preset picker, pause+relaunch,
  app exclusion, word-by-word in TextEdit.

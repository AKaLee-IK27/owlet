# Session Progress Log

## Current State

**Last Updated:** 2026-06-01
**Active Feature:** feat-015 — code complete (all 5 slices), Swift 145/145; manual GUI smoke pending.

## 2026-06-01 (eve) — word-aware suggestion modes ATTEMPTED then REVERTED (35ac18d)

Tried splitting suggestions into continuation (trailing space) vs word-completion
(mid-word) via `detectMode` + a per-mode Ollama `stop` set. **Reverted** `b4919df`
after the installed build regressed.

**Why it failed (root cause):** `detectMode` classed the *dominant* pause position —
caret right after a just-finished word with **no trailing space** — as word-completion.
Word mode (`stop:[" ","\n"]`) makes qwen2.5:1.5b emit a new word with **no leading
space**, so the ghost glues onto the current word (`…the`→`cinema` = "thecinema"), or
emits a leading space the stop cuts to empty → no ghost. Verified by replaying the exact
request over many prefixes. The model is instruct-tuned and cannot distinguish a finished
word (`the`) from a half-typed one (`th`), so the position split can't work.

**"No ghost" — actual root cause (RESOLVED, separate from the word-mode change):**
the stored `autocompleteModel` UserDefault was **`qwen3:8b`** (a thinking model). Under the
autocomplete request shape (`num_predict:18`, `stop:["\n"]`) qwen3:8b returns an EMPTY
`response`, so `OllamaPredictor.suggest` throws `.emptyResponse` and the controller hides
the ghost on every keystroke — independent of caret position, which is why the revert and a
fresh build didn't help. Verified by replaying the exact request (qwen3:8b → `''`;
qwen2.5:1.5b → real completion) and `defaults read co.greenpassport.owlet autocompleteModel`.
feat-014 reset the *code* default to qwen2.5:1.5b but the user's *persisted* pick stayed
qwen3:8b. **Fix:** set Autocomplete model → qwen2.5:1.5b in Settings (or
`defaults write co.greenpassport.owlet autocompleteModel -string qwen2.5:1.5b`).

**Unswept sibling risk (silent failure):** an empty Ollama response (e.g. a thinking model,
or a wrong/missing model) silently hides the ghost with zero user feedback, and the picker
will happily select a thinking model. Hardening (filter/validate the autocomplete model, or
surface "model returned nothing") belongs with feat-018/019 — NOT fixed here.

Reliable word-completion remains blocked on a better signal (dictionary gate, or a
base/FIM model — feat-020).

## feat-015 2026-06-01 (pm) — autocomplete coverage + controls (code complete)

Spec/plan: `2026-06-01-autocomplete-coverage-{design,}.md`. Approved decisions
D1 session-only pause · D2 default-allow+denylist · D3 num_predict 10/18/32 · D4 Int maxTokens.
Five slices, one commit + tests each, positioning-independent first, word-by-word last:

- **Slice 4 (presets):** `Preferences.SuggestionLength` → `num_predict`; threaded through
  `Predicting.suggest` via injected `maxTokensProvider`; Settings Picker.
- **Slice 5 (pause):** session-only in-memory pause (`AppDelegate.autocompletePaused`,
  not persisted), checkable menu-bar "Pause Suggestions"; `pausedProvider` short-circuits.
- **Slice 2 (denylist):** `Preferences.autocompleteDeniedApps`; `beginPrediction` gates on
  `focus.appBundleID`; Settings lists running user apps as exclusion toggles.
- **Slice 3 (non-AX degrade):** cache element with text-but-no-caret-bounds; skip re-read
  until focus change (`CFEqual`).
- **Slice 1 (word-by-word):** `splitIntoWordTokens` (lossless); Tab inserts next word +
  re-anchors; AX-write gated (`.okAX` partial / `.okPaste` whole-then-stop).

Swift suite **145/145** (+13 tests). Rust untouched. **Manual GUI smoke pending (user-only):**
Settings picker + app toggles render; pause silences + resets on relaunch; Tab word-by-word
in TextEdit; word-by-word re-anchor inherits feat-013's deferred caret positioning; the
event-tap Tab-routing across partial accepts is runtime-only.

> feat-013 closed on the strength of a visual TextEdit check (positioning + chip).
> Tab-insert, password exclusion, Notes/WebKit, and multi-monitor were deferred,
> NOT verified — that coverage now lives under feat-015.

## feat-013 2026-06-01 (pm) — readable ghost chip + diagnostics removed

User installed the diagnostic build, judged the caret positioning **acceptable**
("seems ok") and asked for a readable background. Added a backdrop chip to
`GhostTextOverlay`: the suggestion now sits inside a rounded (`cornerRadius 6`),
blurred `NSVisualEffectView` (`.hudWindow` material) with 7×3 padding and a soft
panel shadow, so it reads over any document instead of as faint grey text. Text
stays `secondaryLabelColor` so it still looks like a suggestion, not committed text.

User verified the chip visually ("that looks good") → **removed all temp
`caretgeom` diagnostics** (the per-keystroke `rawZero`/`chose`/overlay-origin
os_log lines in `AXBridge.caretCocoaRect` and `GhostTextOverlay.show`).
`caretCocoaRect` rewritten to a clean `validate()` helper — behavior identical
(validate-near-anchor, else first-computed-rect fallback, else nil). Swift suite
**132/132 pass**; app build clean.

**Still NOT verified (feat-013 stays out of "done"):** Tab accepts at correct
offset, Tab passthrough w/o suggestion, Esc/typing dismiss, password-field
exclusion, Notes/WebKit positioning, multi-monitor. The `isWebEditor` Notes
discriminator remains a dead end (stash@{0}); revisit only if web-editor support
is pursued.

## feat-013 2026-06-01 — autocomplete positioning PARKED (two open bugs)

Attempted a native-only ship (suppress WebKit, keep TextEdit). Manual smoke on the
**external monitor** surfaced two bugs, both unresolved when parked:

1. **Ghost one line too high — affects ALL apps, including native.** TextEdit logs
   `web=false` and the ghost still renders ~one line *above* the caret; Notes too. This
   is a constant ~one-line vertical offset, distinct from the earlier wrong-screen bug.
   Sample (external): `chose=zero cocoa={{1400,2227},{0,17}}`. `GhostTextOverlay.show`
   centers on `caretScreenRect.midY`, which *should* land on the caret line — so the
   offset is either in the flip (`cocoaRect(fromAXRect:)` y ≈ one lineHeight too high)
   or the overlay's vertical placement. **Not yet determined:** constant-vs-growing with
   vertical position, or whether it also repros on the built-in display. This blocks
   even the native-only ship.
2. **`isWebEditor` (AXWebArea ancestor scan) does NOT detect Notes** — Notes logs
   `web=false`, so the AXWebArea discriminator is wrong for Notes' AX tree. Native-only
   suppression via AXWebArea is a dead end; fall back to a bundle-id denylist or
   re-investigate Notes' role hierarchy.

**Tree state:** experimental `isWebEditor` gate + `rawZero`/`web=` diagnostics stashed
(`git stash` msg `feat-013 wip: isWebEditor gate + raw caret diagnostics`). Committed
tree still carries the original `caretgeom` diagnostic. **Resume order:** fix bug (1)
first (blocks all apps), then revisit the web discriminator for bug (2).

## feat-014 2026-06-01 — single-model consolidation + rewriter prompt-hardening (code done, quality-pending)

**Shipped (code):** consolidated rewriter + autocomplete onto one model (`qwen2.5:1.5b`),
gated on prompt-hardening that proves the rewriter **rewrites the draft, never answers it**.
**NOT yet verified:** subjective rewrite *quality* at 1.5b vs the old qwen3:8b in the
running GUI — the 8B→1.5B swap changes the README's "stable core," so it needs a human
to bless the quality (or keep 8B for the rewriter). Status = `implemented-quality-pending`,
parallel to feat-013. The smoke gate proves the *contract*, not taste.

- **Prompt hardening** (`SYSTEM_PROMPT`): new `# Critical: rewrite, never answer`
  section + a clause on the `[CONTEXT]` section that the context never turns the job
  into answering (the exact feat-008 risk: explanatory context nudging toward an answer).
- **Gate** (`tests/smoke.sh`, `OWLET_SMOKE_MODEL`-parameterized, bash-3.2-safe): three
  behavioral assertions — (T4) rewrite-not-answer no-context (`whats the capital of france`
  must NOT yield `Paris`); (T5) never-echo-context (marker absent); **(T6) rewrite-not-answer
  UNDER explanatory `--context 'explain for a five year old'`** — T6 is the one that actually
  probes feat-008's risk (T4/T5 alone don't). Clean on `qwen2.5:1.5b`: T4→`What is the
  capital city of France?`, T6→`Explain to a five-year-old what the capital of France is.`,
  marker never echoed. Also clean on qwen3:8b. Gate passed, so `DEFAULT_MODEL`
  flipped qwen3:8b→qwen2.5:1.5b; bare-default smoke re-ran clean.
- **Swept** every qwen3:8b reference: `install.sh` (one ~1 GB shared download),
  `Preferences.swift` rewriter default + its test, README (×3), AGENTS.md (×3, incl.
  flipping the "feat-014 not done" note), CLAUDE.md / init.sh / tools/rewriter/AGENTS.md
  smoke prereqs.
- **Verification:** Rust **50/50** (`cargo test`, +1 `system_prompt_forbids_answering`);
  Swift **132/132** (`xcodebuild test`) after the Preferences default change; smoke gate
  green on the candidate model and the new bare default.
- **Out of scope / noted:** `OllamaModelLister`'s empty-list display fallback still
  returns `["qwen3:8b"]` (a degraded picker fallback, not the rewriter default — feat-018).
  NOT verified: subjective end-to-end rewrite quality at 1.5b in the running GUI (needs
  install + a manual rewrite) — the gate proves the hardening contract, not taste.

## Landing pass 2026-06-01 (feat-013) — code-side green, awaiting visual smoke

**Goal:** get feat-013 to "landed." Did every code-side check that can run headless;
the visual smoke + true end-to-end latency remain user-only (GUI + TCC grant).

**Verified this session:**
- Swift suite **132/132 pass** (`xcodebuild test -scheme Owlet -destination platform=macOS`).
- **Model latency** (curl to Ollama `/api/generate`, Predictor's exact request shape —
  `qwen2.5:1.5b`, num_predict 12, temp 0.2, stop `\n`, keep_alive 24h, 6 prefixes):
  warm **p50=148ms, p90=163ms, max=164ms**; cold first-load 301ms (one-time). R1's
  fragile assumption (tiny model ~150ms over Ollama) holds **on the model term**.
  Caveat: this is model latency *alone* — real end-to-end adds the 120ms debounce +
  AX read + overlay render, measurable only in the running app.

**Doc drift resolved:** the "Separate remaining issue (mode 1, NOT fixed)" note below
is **stale** — `AXBridge.caretCocoaRect` now carries the WebKit/Notes **AXTextMarker
fallback** (`axTextMarkerCaretRect`) *and* an `AXFrame` `rectIsNearAnchor` validator.
The branch exists in code but has **not been visually verified in a real WebKit app**;
resolve by *seeing the ghost land*, not by assuming. Temp `caretgeom` diagnostic is
**intentionally still in** per the original plan until the smoke confirms positioning.

**Remaining gate (user-only):** `./install.sh` → re-grant Accessibility + Input
Monitoring → enable Autocomplete → (1) **TextEdit single-display:** ghost at caret,
Tab inserts at correct offset, Tab w/o suggestion passes through, Esc/typing dismisses,
password field never predicts; (2) **Notes multi-monitor:** ghost at caret. If wrong,
capture `log show --predicate 'subsystem == "co.greenpassport.owlet" AND category == "caretgeom"' --info`.
**On pass:** remove the `caretgeom` diagnostic and flip feat-013 → done in one commit.

## Ghost-text coordinate fix 2026-06-01 (feat-013)

**Symptom (user):** ghost text never appeared at the caret / didn't follow typing.

**Root cause:** `AXBridge.readCaretContext` returned the raw `kAXBoundsForRange` rect in **Quartz screen space** (top-left origin, y down); `GhostTextOverlay` then used it as **Cocoa** coords (bottom-left origin, y up) with no y-flip. The overlay landed at the vertically mirrored position and the existing `visibleFrame` clamp pinned it there. Confirmed against `FuJacob/cotabby` (`AXHelper.cocoaRect(fromAccessibilityRect:)`), which does the flip Owlet was missing. A second latent bug: `GhostTextOverlay`'s `NSScreen.first(where: frame.intersects(rect))` was comparing a Quartz rect against Cocoa frames, wrong screen on multi-monitor.

**Fix (2 changes, both in `AXBridge.readCaretContext`):** (1) flip the caret rect to Cocoa coords at the boundary so `CaretContext.caretScreenRect` is already Cocoa, meaning `GhostTextOverlay` needs no change and the screen-pick is now correct. Flip against the **union of all screen frames' maxY** (multi-monitor safe), exposed as the pure helper `AXBridge.cocoaRect(fromAXRect:screenUnionMaxY:)`. (2) char-before-caret `BoundsForRange` fallback (trailing edge) for fields that return an empty rect for the zero-length caret query. Out of scope (spec R2 / feat-015/016): cotabby's textmarker, child-run, AXFrame branches and non-AX/Electron fields.

**Verification:** `xcodebuild test … -only-testing AXBridgeGeometryTests -only-testing AutocompleteControllerTests` → **9/9 pass** (3 new flip tests: top→high Cocoa y, bottom→low, multi-monitor union anchor).

**Manual result 2026-06-01: STILL BROKEN.** On a single built-in Retina display the ghost appears but **far from the caret**. Confirmed not a model/enable/Ollama problem (autocomplete enabled, `qwen2.5:1.5b` returns completions, running build has the flip). So the flip alone is not the full story on one display. Suspects: zero-length `kAXBoundsForRange` returning element-origin/`.zero` (falling to char-before), an unexpected coordinate space from TextEdit, or an X-axis (not Y) error. Added **temporary `caretgeom` diagnostic logging** in `AXBridge.caretCocoaRect` (raw zero/char rects, union maxY, main frame, converted Cocoa rect). NEXT: type in TextEdit, read `log show --predicate 'subsystem == "co.greenpassport.owlet" AND category == "caretgeom"' --info`, fix the mapping, then remove the diagnostic. Tracked in `session-handoff.md` → "Open bug".

## Autocomplete implementation 2026-06-01 (feat-013)

**Shipped in code:** default-off inline autocomplete for AX-native text fields. Added `Predicting` / `OllamaPredictor` (`/api/generate`, `qwen2.5:1.5b`, short raw completions), `AutocompleteController` (120 ms debounce, cancellation, password/bounds guards, Tab accept, Esc/typing dismiss), `GhostTextOverlay` (click-through non-activating ghost text panel), AX caret-context reads (`kAXValueAttribute`, `kAXSelectedTextRangeAttribute`, `kAXBoundsForRangeParameterizedAttribute`) plus `insertAtCaret`, Settings toggle + autocomplete model picker, and `HotkeyEventTap` text-change / Tab / Esc routing.

**Verification:** Swift XCTest passed on 2026-06-01: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')` → 125/125 tests pass. New coverage: debounce coalescing, superseded prediction cancellation, password-field and missing-caret-rect guards, accept insertion, default-off behavior, and Tab passthrough when no suggestion is visible.

**Still pending — MANUAL:** enable Autocomplete in Settings, ensure `ollama pull qwen2.5:1.5b`, then verify TextEdit ghost text at caret → Tab inserts at the correct offset; Tab without a visible suggestion passes through; Esc/typing dismisses; password fields never predict; p50 latency ≤ ~200 ms; Notes/Mail/Safari/Pages caret bounds support/positioning list. If latency fails, switch the `Predicting` implementation to the MLX fallback from the design before expanding scope.

## Multi-monitor fix 2026-05-29: per-screen overlay windows (feat-006)

**Symptom:** on a two-screen setup the dim rendered on the wrong screen / offset / wrong size.

**Root cause (class of bug, not a single line):** the overlay was ONE borderless window spanning the union of all screens. A window carries a single screen's properties (backing scale + coordinate origin), so the portion over the other display is positioned/rasterized wrong. Researched best practice (capcap reference impl, Apple docs) is **one overlay window per `NSScreen`**.

**Fix:** rewrote `RegionSelectorController` to create one `RegionSelectorPanel` per `NSScreen` (`contentRect: screen.frame`, `[.borderless, .nonactivatingPanel]`, `.screenSaver`, `[.canJoinAllSpaces, .fullScreenAuxiliary]`, `acceptsMouseMovedEvents`). Each `RegionSelectorView` is screen-local (no union math) — dropped `unionOrigin`/`globalRect`/`viewRect`/`screenFrame` helpers. `acceptsFirstMouse(for:)=true` lets a drag start on a non-key screen. Only the cursor's screen dims (`isActiveScreen`, toggled by tracking-area enter/exit; stays dimmed during a drag). Esc moved from in-view `keyDown` (only one window is key, so it'd miss other screens) to **local + global `NSEvent` keyDown monitors**, stored and removed in `dismiss()`. Right-click + click-without-drag still cancel in-view. **`selectRegion()`'s return contract is unchanged** (global AppKit rect), so `ScreenshotCapturer` + its 4 tests are untouched. Build clean; 105/105 tests pass.

**FOLLOW-UP (logged, deferred):** `CGDisplayCreateImage` is *obsoleted in the macOS 15 SDK* (compiles/runs today only because we build against an older SDK). Migrate `ScreenshotCapturer` to `SCScreenshotManager.captureImage(contentFilter:configuration:)` (macOS 14+, async): build `SCContentFilter(display:excludingWindows:[])`, set `config.sourceRect` (points, top-left within display) and `config.width/height = points × filter.pointPixelScale` for full Retina res. Same Screen Recording permission. Separate scoped change — do NOT fold into the overlay fix.

**MANUAL VERIFY PENDING (must exercise the SECOND screen):** (a) drag-select on the secondary/non-key screen (exercises `acceptsFirstMouse`), (b) cursor A→B moves the dim AND A actually un-dims, (c) captured PNG from the secondary is the right region at full res (esp. if displays have different scale factors), (d) regression: single-screen drag / Esc / click-close / re-double-tap-toggle still work.

## Rework 2026-05-29: region selector overhaul (feat-006)

**Symptoms reported:** couldn't drag to select; no Esc to cancel; dimmed all screens; re-triggering stacked overlays; clicking (no drag) left it open.

**Root causes:** (1) the SwiftUI `DragGesture` had no `.onEnded` and `onAnchorSet` was a no-op, so a completed drag never resolved the continuation — nothing happened. (2) Esc used `addGlobalMonitorForEvents`, which by design never sees the app's own key events. (3) Overlay built one dimmed panel per screen. (4) No guard against re-entrant `selectRegion()`. (5) `ScreenshotCapturer` captured only `CGMainDisplayID` and ignored `backingScaleFactor` (wrong region on Retina / secondary displays).

**Fix:** Replaced the SwiftUI overlay with an AppKit `RegionSelectorView` (NSView) on a single borderless `RegionSelectorPanel` (NSPanel subclass with `canBecomeKey=true`) spanning the **union of all screens** — one always-key window avoids first-mouse / per-screen key juggling. Handles `mouseDown/Dragged/Up`, `rightMouseDown`, `keyDown` (Esc, keyCode 53) directly; `acceptsFirstMouse(for:)=true`; `.activeAlways` tracking for `mouseMoved`. Behaviors: only the cursor's screen is dimmed and the dim follows the cursor; drag <5pt (a click) cancels; Esc/right-click cancel; re-entrant `selectRegion()` toggles the overlay closed. `ScreenshotCapturer` now finds the screen containing the selection, captures that display, and converts global→display-local→pixels via a pure, unit-tested `pixelCropRect` (Retina-aware). Removed the dead `Views/RegionSelectorOverlayView.swift` and the global Esc monitor.

**Verification:** Swift build clean; 105/105 tests pass (4 new `ScreenshotCapturerTests` for the coordinate conversion incl. Retina + secondary-screen origin).

**Still pending — MANUAL (unit tests can't cover the event/coordinate path):** run the app and confirm (a) drag selects on the active screen, (b) moving the cursor across screens moves the dim, (c) Esc closes, (d) click-without-drag closes, (e) re-double-tap-Shift toggles closed, (f) **open the captured PNG and confirm it's the right region at full resolution** (the Retina/wrong-display trap a green test won't catch). Needs Screen Recording permission.

## Bugfix 2026-05-29: double-tap Shift & Option-hold dead in-app

## Bugfix 2026-05-29: double-tap Shift & Option-hold dead in-app

**Symptom:** double-click-Shift (feat-006 screenshot flow) and hold-Option (feat-005 floating button) never triggered, despite passing unit tests.

**Root cause:** On macOS, bare modifier keys (Shift, Option) emit `CGEventType.flagsChanged` — never `keyDown`/`keyUp`. `HotkeyEventTap` (1) omitted `.flagsChanged` from its event-tap mask, so those events never reached the callback, and (2) routed all modifier detection through the `if type == .keyDown` branch, which a bare modifier never enters. Regular chords (e.g. Option+Space) worked because they include a non-modifier key that does emit `keyDown`. Existing tests passed because they call `OptionHoldDetector.handleKeyDown` directly, never crossing the event-tap boundary where the bug lived.

**Fix:** Added `.flagsChanged` to the mask and a `flagsChanged` branch that detects modifier transitions (absent→present / present→absent) via a new testable `HotkeyEventTap.decideModifierAction(flags:now:)`. Double-tap Shift = two clean Shift down-transitions within 0.4s; Option-hold starts on Option-only down, cancels on Option release or any real keyDown. Added `HotkeyEventTapTests` (7 cases). 101/101 tests pass; Swift build clean.

**Still pending:** manual in-app verification (needs Input Monitoring grant + real keystrokes) — double-tap Shift → region selector; hold Option ~300ms → owl button.

## Status

### What's Done

- [x] Rust port of owlet-rewriter merged (afc5605) — 47/47 tests pass
- [x] App icon wired into AppIcon.appiconset (10 sizes, Contents.json, project.yml setting)
- [x] Build verified — AppIcon.icns present in built bundle
- [x] **feat-003: Configurable hotkey (v0.3 milestone)** — 14 tasks, ~13 commits on feat/rewriter-ux-v0.3. Ships: Chord type, KeyCodeMap, Preferences/UserDefaults, HotkeyRecorderField, SettingsView (hotkey recorder + Ollama model picker + launch-at-login toggle), AppDelegate rebind-on-change wiring, owlet-rewriter `--model` flag, menubar "Settings…" item. init.sh PASS 2026-05-28; Rust 29/29; Swift build clean.
- [x] **feat-004: README v0.3 refresh** — version bumped, Settings section added, Customisation section updated, smoke checklist extended with Settings window steps.

### What's In Progress

None.

### What's Next

1. User manual smoke walkthrough of Settings window (see README checklist — Settings window v0.3 section)
2. Consider feat-002 (status-bar owl glyph) — small, self-contained, visible win
3. Tag v0.3 once manual smoke passes

## Blockers / Risks

- None blocking. Ad-hoc re-sign after build will invalidate TCC grants on existing installs; user re-grants Accessibility + Input Monitoring on next launch.

## Decisions Made

- **Use PNG source, not SVG, for app icon**: user's SVG had a black background path. The PNG (transparent) was cleaner to crop and scale.
- **78% safe-area fill on 1024 canvas**: matches Apple HIG guidance for macOS app icons.

## Files Modified This Session

- `Owlet/project.yml` — added `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`
- `Owlet/Owlet/Assets.xcassets/Contents.json` (new)
- `Owlet/Owlet/Assets.xcassets/AppIcon.appiconset/Contents.json` (new)
- `Owlet/Owlet/Assets.xcassets/AppIcon.appiconset/icon_*.png` (10 new)
- `docs/assets/owlet-logo.svg` — refined ear tufts (sharp triangles → rounded peaks) and wing feather curves (straight Q → flowing C)
- `Owlet/Owlet/Assets.xcassets/AppIcon.appiconset/icon_*.png` — regenerated 10 sizes from refined SVG via padded wrapper (282×282 viewBox, ~78% fill) → `qlmanage -t -s 1024` master → `sips -Z` downsample
- `docs/assets/owlet-glyph.svg` (new) — monochrome owl glyph for menu bar (filled silhouette + evenodd eye holes)
- `Owlet/Owlet/Assets.xcassets/OwletGlyph.imageset/` (new) — 22/44/66px PNGs + Contents.json with template rendering intent
- `Owlet/Owlet/StatusBarController.swift` — swapped SF Symbol `text.bubble` → `NSImage(named: "OwletGlyph")`; later flipped `isTemplate` to false and pinned size to 22pt after switching glyph asset to colored owl
- AppIcon + OwletGlyph PNGs subsequently regenerated from `~/Downloads/owlet logo.png` (bbox crop → 78% safe-area square → 1024 master → Pillow `LANCZOS` downsample to all 13 sizes)
- `Makefile` (new) — `make build`, `run`, `clean`, `install`, `verify`, `help` wrapping the verification commands from CLAUDE.md
- `CLAUDE.md`, `feature_list.json`, `init.sh`, `progress.md`, `session-handoff.md` (harness scaffold)

## Evidence of Completion

- [x] Build: `xcodebuild ... build` — BUILD SUCCEEDED
- [x] Icon present: `/tmp/owlet-build/Build/Products/Debug/Owlet.app/Contents/Resources/AppIcon.icns` (80,786 bytes)
- [x] Info.plist: `CFBundleIconName: AppIcon` and `CFBundleIconFile: AppIcon` verified
- [x] SVG refinement rendered via `qlmanage -t -s {32,128,512}` → softened ear tufts and wing feather curves visible; silhouette readable at 32px
- [x] AppIcons regenerated from refined SVG; xcodebuild Debug → BUILD SUCCEEDED; `assetutil --info` confirms all 10 sizes (16/32/32/64/128/256/256/512/512/1024) in Assets.car

## Notes for Next Session

- The harness was bootstrapped this session via `/harness-creator`. If the structure feels heavy, prune — keep `feature_list.json` honest about what's actually in flight.
- `.remember/` still holds session memory across runs; the harness's `progress.md` is for end-of-session checkpointing, not the running buffer.

## 2026-06-01 — feat-013 ghost-text positioning hunt (root cause + fix)

**Symptom:** inline autocomplete suggestion not rendered next to the caret in Apple Notes (multi-monitor setup).

**Root cause (verified via os_log caretgeom diagnostic):** `AXBridge.cocoaRect(fromAXRect:)` flipped Quartz→Cocoa using the all-screens **union** maxY instead of the **primary** display's maxY. With an external monitor mounted *above* the laptop (primary `{0,0,1800,1169}` maxY=1169; external `{-552,1169,2560,1440}` maxY=2609; union=2609), every caret rect was flipped 1440px too high → overlay landed off the caret onto the wrong screen. Proof: identical raw AX bounds `(1288.65,269,0,16)` produced Cocoa y=884 (correct, on primary) when the external display was momentarily asleep (union==1169), and y=2324 (wrong) when union==2609.

**Fix:** `AXBridge.swift` — flip now anchors on `primaryScreenMaxY()` (screen with `frame.origin == .zero`). Renamed pure-function param `screenUnionMaxY` → `primaryScreenMaxY`. Regression test `AXBridgeGeometryTests.test_flipAnchorsOnPrimaryNotUnion_externalMonitorAbove` reproduces the captured scenario. `xcodebuild test -only-testing:OwletTests/AXBridgeGeometryTests` → 3/3 pass.

**Verification still pending:** real-app smoke in Notes on the multi-monitor rig (requires rebuild+install → re-grant Accessibility/Input Monitoring). Temp `caretgeom` diagnostic left in `AXBridge.caretCocoaRect` until verified, then remove.

**Separate remaining issue (mode 1, NOT fixed):** in WebKit editors Notes/etc., `kAXBoundsForRange` sometimes returns a degenerate `(0,y,0,0)` rect (469/711 caretgeom samples → `chose=none`), so no suggestion shows at all. cotabby's `AXTextGeometryResolver` handles this with extra fallback branches (AXTextMarker caret rect, child AXStaticText proportional estimate, AXFrame estimate) + a `rectIsNearAnchor` validator. Porting those is a larger, separate change — needs user go-ahead.

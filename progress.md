# Session Progress Log

## Current State

**Last Updated:** 2026-05-29
**Active Feature:** Bugfix/rework — region selector (screenshot capture) overhaul

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

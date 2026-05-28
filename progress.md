# Session Progress Log

## Current State

**Last Updated:** 2026-05-28
**Active Feature:** None — v0.3 milestone complete

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

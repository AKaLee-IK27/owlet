# OWLET KNOWLEDGE BASE

**Last updated:** 2026-05-29 (v0.4.0-preview)
**Branch:** main

## OVERVIEW

SwiftUI macOS menu-bar app + Rust CLI rewriter. Three input gestures feed one rewrite pipeline:

1. **Configurable chord** (default `Option+Space`) → capture selected text → local Ollama text model → inline diff popup → replace/copy.
2. **Hold Option** (~300 ms) → floating owl button → same text rewrite (feat-005).
3. **Double-tap Shift** → screen-region selector → screenshot → local Ollama **vision** model (`llava:7b`) → rewrite popup (feat-006, preview).

## STRUCTURE

```
owlet/
├── Owlet/Owlet/           # SwiftUI app sources (~26 top-level .swift files)
│   ├── Views/             # 12 SwiftUI view files
│   └── *.swift            # Flat module — models, controllers, services
├── Owlet/OwletTests/      # 17 test files, 1:1 with sources + fixtures
├── Owlet/project.yml      # xcodegen project definition
├── tools/rewriter/        # Rust CLI (single main.rs, 419 lines)
│   ├── src/main.rs        # stdin → Ollama → stdout pipeline
│   └── tests/smoke.sh     # Integration smoke test
├── docs/superpowers/      # specs/ and plans/ for design work
├── .remember/             # Append-only session memory (read-mostly)
├── CLAUDE.md              # Agent workflow rules (read before coding)
├── feature_list.json      # Feature tracker with status + evidence
├── progress.md            # Session progress log
├── install.sh             # Idempotent installer
└── init.sh                # Full verification suite (slow)
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| App entry point + wiring | `Owlet/Owlet/OwletApp.swift` | `@main`, AppDelegate, binds all three gestures |
| Hotkey capture | `Owlet/Owlet/HotkeyEventTap.swift` | CGEventTap. Handles the chord, Option-hold, and double-tap-Shift. Modifier transitions detected via `.flagsChanged` (bare modifiers don't emit keyDown) |
| Option-hold detector | `Owlet/Owlet/OptionHoldDetector.swift` | ~300 ms Option-only hold → fires floating button |
| Floating button | `Owlet/Owlet/FloatingButtonController.swift` + `Views/FloatingButtonView.swift` | Circular owl button near cursor (feat-005) |
| Region selector | `Owlet/Owlet/RegionSelectorController.swift` | One borderless overlay window **per `NSScreen`** (multi-monitor). Returns a global AppKit rect |
| Screenshot capture | `Owlet/Owlet/ScreenshotCapturer.swift` | Global rect → display-local → Retina pixels (`pixelCropRect`). Uses `CGDisplayCreateImage` (deprecated — see FOLLOW-UPS) |
| Vision integration | `Owlet/Owlet/VisionClient.swift` | Sends PNG to Ollama vision model (`llava:7b`); reads `Preferences.visionModel` lazily |
| Text capture/write | `Owlet/Owlet/AXBridge.swift` | AXUIElement, largest file. 3 fallback paths incl. synthetic Cmd+C |
| Ollama integration | `Owlet/Owlet/OllamaClient.swift` | Spawns Rust binary, streams stdout |
| Rewrite state machine | `Owlet/Owlet/RewriterFlow.swift` | @MainActor. `start()` (text) and `startFromScreenshot()` (vision) |
| Popup state enum | `Owlet/Owlet/PopupState.swift` | `.loading \| .loadingScreenshot \| .result \| .empty \| .error(ErrorKind)` — single source of truth. "No text in image" is `.error(.noTextInImage)`, an `ErrorKind` case, not a top-level state |
| Diff rendering | `Owlet/Owlet/DiffEngine.swift` | Word-level diff algorithm |
| Prompt cleaning | `Owlet/Owlet/CleanOutput.swift` | LLM output sanitization |
| Preferences | `Owlet/Owlet/Preferences.swift` | UserDefaults, `.hotkey \| .launchAtLogin \| .model \| .visionModel` changes |
| Design tokens | `Owlet/Owlet/OwletDesignSystem.swift` + `docs/design-system.md` | Branded Tier-1 token set; doc explains the 3 UI tiers |
| Settings UI | `Owlet/Owlet/Views/SettingsView.swift` | Hand-rolled NSWindow (not SwiftUI Settings scene) |
| Popup UI | `Owlet/Owlet/Views/ImprovePromptFloater.swift` | Largest view, renders per PopupState (Tier 1, branded) |
| Rust prompt | `tools/rewriter/src/main.rs` | SYSTEM_PROMPT constant, Ollama API call, `--model` flag |
| Test fixtures | `Owlet/OwletTests/Fixtures/` | Sample inputs for unit tests |

## CONVENTIONS

- **Flat module** — `Owlet/Owlet/` has no subdirectories beyond `Views/`. All models, services, controllers live at top level.
- **xcodegen** — project.yml generates the Xcode project. Don't edit `.xcodeproj` directly.
- **One feature at a time** — pick from `feature_list.json`, don't pile on changes.
- **Spec → plan → ship** — non-trivial work lives in `docs/superpowers/specs/` and `docs/superpowers/plans/`.
- **Evidence before "done"** — run verification command, paste result into `feature_list.json`.

## ANTI-PATTERNS (THIS PROJECT)

- **Don't reach `AppDelegate` via `NSApp.delegate as?`** — SwiftUI's `NSApplicationDelegateAdaptor` wraps it, cast returns nil. Use closure injection.
- **Don't use SwiftUI `Settings` scene** — LSUIElement/.accessory app won't front it. Hand-rolled `NSWindow + NSHostingController` via `AppDelegate.showSettings()`.
- **Don't casually rebuild+reinstall** — ad-hoc re-sign invalidates Accessibility/Input Monitoring TCC grants.
- **Don't add ErrorKind ad-hoc strings** — add cases to `ErrorKind` enum in `PopupState.swift`.
- **Don't refactor adjacent code while fixing bugs** — fix minimally.

## UNIQUE STYLES

- **PopupState** — single enum drives all UI: `.loading(sourceText, isLong, captureMethod)`, `.loadingScreenshot`, `.result(original, rewritten, segments?, canReplace, captureMethod)`, `.empty(text)`, `.error(ErrorKind)`. Image/vision failures surface as `.error(.noTextInImage)`.
- **Preferences.changedNotification** — posts with specific `Change` cases; `AppDelegate` handles `.hotkey` (rebind event tap), `.launchAtLogin` (apply Login Item), `.model` (read lazily).
- **Activation policy flip** — Settings window flips `NSApplication.activationPolicy` to `.regular` while open, reverts on close.
- **`.nonactivatingPanel`** — popup never becomes key; uses `NSEvent.addGlobalMonitorForEvents` for click-outside dismissal.

## COMMANDS

```bash
# Full verification (slow — builds both Rust + Swift)
./init.sh

# Rust only (fast)
(cd tools/rewriter && cargo test)

# Rust + Ollama smoke (needs ollama serve + qwen3:8b)
(cd tools/rewriter && cargo build --release && bash tests/smoke.sh)

# Swift build only
(cd Owlet && xcodegen generate && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build)

# Swift tests
(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')

# Full install (signs, copies to ~/Applications)
./install.sh
```

## NOTES

- TCC grants (Accessibility + Input Monitoring; **Screen Recording** for the screenshot flow) are tied to binary signature. Every `./install.sh` re-signs → user must re-toggle permissions.
- `Owlet/project.yml` → run `xcodegen generate` before building in Xcode.
- Rust binary directory from `UserDefaults.standard.string(forKey: "rewriterDirectory")`; falls back to dev path.
- First rewrite takes ~5s (model cold-start). `OLLAMA_KEEP_ALIVE=24h` keeps it warm.
- `install.sh` pulls only the text model (`qwen3:8b`). The vision model (`llava:7b`) for feat-006 must be pulled manually.

## CURRENT STATE / FOLLOW-UPS (as of 2026-05-29)

- **feat-001..006 all `done` in `feature_list.json`** (v0.4.0-preview), with the caveats below.
- **feat-005 (hold-Option button) & feat-006 (screenshot rewrite) — MANUAL VERIFY PENDING.** Implemented and unit-tested (105+ tests pass) but the real event path and, for feat-006, the captured-PNG-on-a-secondary-display path have **not** been confirmed by a human. Don't describe them as verified-working.
- **Deprecated capture API.** `ScreenshotCapturer` uses `CGDisplayCreateImage`, obsoleted in the macOS 15 SDK (works today only against an older SDK). Tracked migration: `SCScreenshotManager` (ScreenCaptureKit). Keep it a separate, scoped change.
- **Working tree has uncommitted feat-006 rework** (per `git status`): `HotkeyEventTap`, `RegionSelectorController`, `ScreenshotCapturer`, `StatusBarController` modified; `Views/RegionSelectorOverlayView.swift` deleted; new `HotkeyEventTapTests` / `ScreenshotCapturerTests`.
- **Mode chips in the popup are visual-only** — no `--mode` flag in the rewriter yet.

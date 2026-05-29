# OWLET APP MODULE

**Domain:** SwiftUI macOS app sources — models, services, controllers, views.

## OVERVIEW

Flat module: all app logic lives here. No subdirectories beyond `Views/`. ~26 top-level Swift files + 12 views.

## STRUCTURE

```
Owlet/Owlet/
├── OwletApp.swift           # @main entry, AppDelegate, wires all 3 input gestures
├── RewriterFlow.swift       # @MainActor state machine: start() (text) + startFromScreenshot() (vision)
├── PopupState.swift         # Single enum: .loading|.loadingScreenshot|.result|.empty|.error(ErrorKind). noTextInImage is an ErrorKind case
├── PopupWindowController.swift  # NSWindow management, .nonactivatingPanel, click-outside dismiss
├── HotkeyEventTap.swift     # CGEventTap: chord + Option-hold + double-tap-Shift (.flagsChanged aware)
├── OptionHoldDetector.swift # ~300ms Option-only hold → floating button (feat-005)
├── FloatingButtonController.swift  # Circular owl button near cursor (feat-005)
├── RegionSelectorController.swift  # One overlay window PER NSScreen; returns global rect (feat-006)
├── ScreenshotCapturer.swift # Global rect → display-local → Retina pixels; CGDisplayCreateImage (deprecated)
├── VisionClient.swift       # PNG → Ollama vision model (llava:7b); reads Preferences.visionModel (feat-006)
├── AXBridge.swift           # AXUIElement text read/write (largest file, 3 fallback paths)
├── OllamaClient.swift       # Spawns Rust binary, streams stdout
├── Preferences.swift        # UserDefaults + changedNotification (.hotkey|.model|.launchAtLogin|.visionModel)
├── DiffEngine.swift         # Word-level diff algorithm
├── CleanOutput.swift        # LLM output sanitization
├── StatusBarController.swift # Menu bar icon (OwletGlyph) + menu + version label
├── PermissionChecker.swift  # TCC grant checks
├── PermissionModalWindowController.swift  # First-run permission UI
├── LoginItemManager.swift   # SMAppService auto-launch
├── Chord.swift / ChordMatcher.swift  # Hotkey chord representation
├── KeyCodeMap.swift         # CGKeyCode → NSEvent modifier flags
├── ClipboardGuard.swift     # Password field detection
├── OwletDesignSystem.swift  # Tier-1 branded tokens (see docs/design-system.md)
├── Theme.swift              # LEGACY Tier-3 tokens — superseded by OwletDesignSystem; don't extend
├── OllamaModelLister.swift  # Dynamic model discovery (Settings pickers)
└── Views/                   # SwiftUI views (12 files)
```

## WHERE TO LOOK

| Task | File | Notes |
|------|------|-------|
| Add new popup state | `PopupState.swift` | Add case to enum, update `ImprovePromptFloater` rendering |
| Change hotkey behavior | `HotkeyEventTap.swift` + `Chord.swift` | CGEventTap + chord parsing. Bare modifiers (Shift/Option) arrive via `.flagsChanged`, not keyDown — see `decideModifierAction` |
| Change Option-hold / floating button | `OptionHoldDetector.swift` + `FloatingButtonController.swift` | feat-005 |
| Change region select / screenshot | `RegionSelectorController.swift` + `ScreenshotCapturer.swift` | feat-006. One overlay window per `NSScreen`; coordinate conversion in `pixelCropRect` |
| Change vision rewrite | `VisionClient.swift` + `RewriterFlow.startFromScreenshot()` | feat-006 |
| Change text capture | `AXBridge.swift` | Accessibility API, 3 fallback paths |
| Change Ollama calls | `OllamaClient.swift` | Process spawn, stdin/stdout streaming |
| Add new preference | `Preferences.swift` | UserDefaults key + Change case |
| New UI component | `Views/` | Follow existing view patterns + `docs/design-system.md` tiers; no StateObject unless needed |

## CONVENTIONS

- **@MainActor** on all UI-facing code (RewriterFlow, PopupWindowController).
- **Closure injection** for AppDelegate access — never `NSApp.delegate as?`.
- **PopupState drives UI** — ImprovePromptFloater switches on enum, not separate windows.
- **Preferences post notifications** — use `Preferences.changedNotification` with `Change` enum.
- **ErrorKind enum** — all errors are cases, never raw strings.

## ANTI-PATTERNS

- **No `NSApp.delegate as? AppDelegate`** — returns nil due to SwiftUI wrapper.
- **No SwiftUI Settings scene** — LSUIElement app can't front it.
- **No ad-hoc ErrorKind strings** — always enum cases.
- **No refactoring while bugfixing** — fix minimally, touch only broken code.

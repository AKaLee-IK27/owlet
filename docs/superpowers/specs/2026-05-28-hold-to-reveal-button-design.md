# Hold-to-Reveal Floating Button Design

**Date:** 2026-05-28
**Status:** Draft
**Feature ID:** feat-005

## Overview

Add a small floating button that appears when the user holds the Option key for 300ms. Clicking the button opens the existing rewrite popup. This provides an alternative trigger to the Option+Space chord, similar to Apple Intelligence's text rewriting button in macOS.

The existing Option+Space chord remains fully functional. This is an additional trigger, not a replacement.

## Interaction Flow

1. User holds **Option** key alone (no other key pressed).
2. After **300ms hold threshold**, a small circular button (32×32pt) appears near the text cursor.
3. The button shows the **Owlet owl icon** in template rendering mode (monochrome, adapts to system theme).
4. **Click the button** → opens the existing full rewrite popup anchored to the button's position.
5. **Release Option without clicking** → button fades out, nothing else happens.
6. **Press another key while holding** (e.g., Option+Space) → button cancels, existing chord fires normally.
7. **Click outside button** → button dismisses.

## Architecture

### New Files

| File | Purpose |
|------|---------|
| `Owlet/Owlet/OptionHoldDetector.swift` | Pure hold-detection logic: tracks Option keyDown timestamp, fires on threshold, cancels on keyUp or secondary key press |
| `Owlet/Owlet/FloatingButtonController.swift` | Manages the tiny NSPanel hosting the 32×32 button. Non-activating, floating, positioned near cursor |
| `Owlet/Owlet/Views/FloatingButtonView.swift` | SwiftUI view for the circular button with owl icon |

### Modified Files

| File | Change |
|------|--------|
| `Owlet/Owlet/HotkeyEventTap.swift` | Add `keyUp` to event mask; wire `OptionHoldDetector` into the callback; pass-through events that don't match |
| `Owlet/Owlet/OwletApp.swift` | Instantiate `OptionHoldDetector` and `FloatingButtonController` in `startNormalLaunch()` |
| `feature_list.json` | Add feat-005 entry |

### Unchanged Files (Reuse Existing Pipeline)

- `RewriterFlow.swift` — no changes, called on button click
- `PopupState.swift` — no changes
- `PopupWindowController.swift` — no changes
- `AXBridge.swift` — no changes
- `OllamaClient.swift` — no changes

## OptionHoldDetector

Pure state machine. No AppKit dependencies.

```swift
final class OptionHoldDetector {
    let holdThreshold: TimeInterval = 0.3
    private var optionKeyDownTime: Date?
    private var timer: Timer?
    let onHoldTriggered: @Sendable () -> Void

    init(onHoldTriggered: @escaping @Sendable () -> Void)

    /// Call on keyDown. If Option-only (no other modifiers active beyond Option),
    /// start the hold timer. If another key is pressed, cancel.
    func handleKeyDown(flags: ModifierFlags)

    /// Call on keyUp. If Option released before threshold, cancel.
    func handleKeyUp(flags: ModifierFlags)

    /// Cancel any pending hold detection.
    func cancel()
}
```

### State Transitions

```
Idle → keyDown(Option-only) → Waiting (timer starts)
Waiting → 300ms elapsed → Triggered (onHoldTriggered fires)
Waiting → keyUp(Option) → Idle (timer cancelled)
Waiting → any other keyDown → Idle (timer cancelled, chord evaluates)
Triggered → click → (handled by FloatingButtonController)
Triggered → keyUp(Option) → Idle (button dismissed)
```

## FloatingButtonController

Manages the button panel. Mirrors `PopupWindowController` patterns.

```swift
@MainActor
final class FloatingButtonController {
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?

    func show(at: NSPoint)
    func hide()
    func dismissAndTriggerRewrite()
}
```

### Panel Configuration

- Style mask: `.nonactivatingPanel, .fullSizeContentView`
- Level: `.floating` (same as popup)
- Size: 32×32pt
- Shape: circular via SwiftUI `.clipShape(Circle())`
- Background: clear, with subtle shadow
- Collection behavior: `.canJoinAllSpaces, .stationary`
- Fade in: 0.15s, fade out: 0.1s

### Positioning

Defaults to `NSEvent.mouseLocation`. If AX rect is available for the focused element, anchor below it (same logic as `RewriterFlow.anchorRect`).

### Click Behavior

On button click → dismiss button → instantiate `RewriterFlow` → call `await flow.start()`. This reuses the entire existing capture → rewrite → diff → result pipeline.

## Event Flow in HotkeyEventTap

The CGEventTap callback is extended:

```
Callback receives event:
  1. keyDown:
     a. If Option-only (no cmd, ctrl, shift, fn) → OptionHoldDetector.handleKeyDown()
     b. If matches existing chord → OptionHoldDetector.cancel(), fire rewrite
     c. Otherwise → pass event through
  2. keyUp:
     a. If Option → OptionHoldDetector.handleKeyUp()
     b. Otherwise → pass event through
```

Events are **not consumed** (returned as `Unmanaged.passUnretained(event)`) unless they match the existing chord. The Option keyDown that starts the hold timer is passed through to the system so the user can still type Option+letter normally. This means:
- Normal Option+letter typing works (300ms threshold prevents false triggers)
- Option+Space still fires the existing rewrite
- The button only appears if Option is held in isolation for 300ms

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Option held < 300ms then released | Nothing happens, event passes through |
| Option held, user types Option+letter | Button cancels before showing, letter types normally |
| Option held, user clicks button | Full rewrite popup opens |
| Option held, user switches apps | Button dismisses (app switch observer) |
| Option held in password field | Button doesn't show (ClipboardGuard check before showing) |
| Rapid Option press/release | No button, event passes through |
| Input Monitoring permission revoked | Detector fails silently, existing tap shows modal |
| Option held while typing fast | 300ms threshold is longer than typical key repeat interval (~0.05s), so normal typing won't trigger |

## Testing Strategy

### Unit Tests

- `OptionHoldDetectorTests.swift` — test all state transitions:
  - Timer starts on Option-only keyDown
  - Timer fires after 300ms
  - Timer cancels on Option keyUp before threshold
  - Timer cancels on any other keyDown
  - Multiple rapid presses don't accumulate timers

### Manual Smoke Tests

- [ ] Hold Option in TextEdit for 300ms → owl button appears
- [ ] Click button → rewrite popup opens with selected text
- [ ] Release Option before 300ms → nothing happens
- [ ] Hold Option, then press Space → existing rewrite fires (button doesn't appear)
- [ ] Hold Option, type a letter → letter types normally, no button
- [ ] Click outside button → button dismisses
- [ ] Hold Option in password field → no button
- [ ] Hold Option, switch apps → button dismisses

## Preferences (Future)

The hold threshold (300ms) and enable/disable toggle are not exposed in Settings for v0.4. They can be added later if users request customization.

## Dependencies

- feat-001 (App icon) — the button uses the owl icon
- feat-003 (Configurable hotkey) — the existing chord must remain functional

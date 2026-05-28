# Screenshot-Based Rewrite via Double-Click Option Design

**Date:** 2026-05-28
**Status:** Draft
**Feature ID:** feat-006

## Overview

Add a screenshot-based rewrite flow triggered by double-clicking the Option key. The user selects a screen region, the image is captured and sent to a vision model (e.g., `qwen2.5-vl:7b`), and the extracted + rewritten text appears in the existing popup. This provides an alternative to the text-selection-based rewrite, useful when AX text capture fails (Electron apps, terminals, images with text) or when the user wants to capture a specific visual region.

The existing Option+Space text-based rewrite remains fully functional. This is an additional trigger.

## Interaction Flow

1. User double-clicks Option key (two presses within 400ms).
2. Screen dims with semi-transparent overlay on all displays.
3. User drags to select a rectangular region (crosshair cursor).
4. On mouse release, the region is captured as a PNG image.
5. Overlay dismisses, existing popup shows `.loadingScreenshot` state ("Analyzing screenshot…").
6. Image is sent to a vision model with a system prompt to extract text and rewrite it.
7. The rewritten text appears in the existing popup with Copy/Cancel (no Replace since we can't do AX replace without original text position).
8. **Esc** at any point during selection cancels the capture.

## Architecture

### New Files

| File | Purpose |
|------|---------|
| `Owlet/Owlet/RegionSelectorController.swift` | Full-screen overlay windows for drag-to-select region capture. Returns `CGRect` on release or `nil` on cancel. |
| `Owlet/Owlet/ScreenshotCapturer.swift` | Captures a screen region using `CGDisplayCreateImage` + crop, returns PNG `Data`. |
| `Owlet/Owlet/VisionClient.swift` | Swift-native Ollama client for vision models. Sends base64-encoded images via `/api/chat`. |

### Modified Files

| File | Change |
|------|--------|
| `Owlet/Owlet/HotkeyEventTap.swift` | Add double-click Option detection (tracks Option keyDown timestamps, fires on two presses within 400ms). |
| `Owlet/Owlet/PopupState.swift` | Add `.loadingScreenshot` case for the "Analyzing screenshot…" state. |
| `Owlet/Owlet/RewriterFlow.swift` | Add `startFromScreenshot()` entry point chaining: region select → capture → vision model → result. |
| `Owlet/Owlet/OwletApp.swift` | Wire the double-click detector to the screenshot flow. |
| `Owlet/Owlet/Preferences.swift` | Add `visionModel` property (defaults to `qwen2.5-vl:7b`). |
| `feature_list.json` | Add feat-006 entry. |

### Unchanged Files

- `OllamaClient.swift` — text-only pipeline, kept separate
- `PopupWindowController.swift` — no changes
- `AXBridge.swift` — no changes
- `DiffEngine.swift` — no changes (screenshot flow doesn't use diff)
- `CleanOutput.swift` — reused for vision output cleaning

## RegionSelectorController

```swift
@MainActor
final class RegionSelectorController {
    /// Shows the region selection overlay across all screens and returns
    /// the selected rect in screen coordinates, or nil if cancelled.
    func selectRegion() async -> CGRect?
}
```

Implementation creates one borderless `NSPanel` per `NSScreen`, fills with 40% black overlay. Each panel hosts a SwiftUI view that tracks mouse events:

- `leftMouseDown` → starts selection, records anchor point
- `mouseDragged` → updates selection rectangle, redraws overlay with clear cutout
- `leftMouseUp` → returns the selected rect
- `keyDown` (Esc) → returns nil, dismisses all panels

The selection rectangle is drawn with a white 2px border and semi-transparent fill outside the selection area.

## ScreenshotCapturer

```swift
final class ScreenshotCapturer: @unchecked Sendable {
    /// Capture the given screen rect as PNG data.
    func capture(region: CGRect) async -> Data?
}
```

Uses `CGDisplayCreateImage(CGMainDisplayID())` to capture the full primary display, then `CGImage.cropping(to:)` for the region. Converts to PNG via `NSBitmapImageRep`. Returns raw PNG bytes.

For multi-display setups, iterates `CGDisplayGetDisplaysWithRect` to find which display contains the region.

## VisionClient

```swift
final class VisionClient: @unchecked Sendable {
    enum Failure: Error {
        case timeout
        case emptyOutput
        case backendError(String)
        case launchFailed(String)
        case modelNotFound(String)
    }

    init(model: String, timeoutSeconds: TimeInterval = 60)
    func rewrite(imageData: Data) async throws -> String
}
```

Sends a POST to `http://localhost:11434/api/chat`:

```json
{
  "model": "qwen2.5-vl:7b",
  "messages": [
    {
      "role": "system",
      "content": "You are a text extraction and rewriting assistant. Look at the screenshot the user provides. Extract ALL visible text from the image. Then rewrite that text to be clearer and better structured, following prompt engineering best practices. Preserve the original language. Output ONLY the rewritten text — no explanation, no preamble."
    },
    {
      "role": "user",
      "content": "Extract and rewrite the text in this image.",
      "images": ["<base64 PNG data>"]
    }
  ],
  "stream": false,
  "options": { "temperature": 0.2 }
}
```

Timeout is 60s (vision models are slower than text-only). Returns the cleaned rewritten text.

## Double-Click Detection in HotkeyEventTap

Extends the existing callback to track Option keyDown timestamps:

```
State: lastOptionKeyDownTime: Date?

Option keyDown:
  If lastOptionKeyDownTime exists and now - lastOptionKeyDownTime < 400ms:
    → Fire double-click handler (screenshot flow)
    → lastOptionKeyDownTime = nil
  Else:
    → lastOptionKeyDownTime = now
    → Start hold timer (existing hold-to-reveal flow)

Option keyUp:
  → lastOptionKeyDownTime = nil (reset if released before second press)
  → Cancel hold timer if pending
```

The double-click handler cancels the hold detector and fires the screenshot flow.

## RewriterFlow.startFromScreenshot()

```swift
@MainActor
func startFromScreenshot() async {
    // 1. Region selection
    guard let region = await regionSelector.selectRegion() else { return }

    // 2. Capture
    guard let imageData = await capturer.capture(region: region) else {
        setState(.error(.selectionUnreadable))
        return
    }

    // 3. Loading state
    setState(.loadingScreenshot)

    // 4. Vision model
    do {
        let rewritten = try await visionClient.rewrite(imageData: imageData)
        let cleaned = CleanOutput.clean(rewritten)
        if cleaned.isEmpty {
            setState(.error(.emptyOutput))
            return
        }
        // No diff, no replace (no original text position known)
        setState(.result(
            original: "",
            rewritten: cleaned,
            segments: nil,
            canReplace: false
        ))
    } catch VisionClient.Failure.modelNotFound(let model) {
        setState(.error(.backendUnavailable(message: "Vision model '\(model)' not found. Run `ollama pull \(model)`")))
    } catch VisionClient.Failure.timeout {
        setState(.error(.timeout))
    } catch VisionClient.Failure.backendError(let msg) {
        setState(.error(.backendUnavailable(message: msg)))
    } catch {
        setState(.error(.backendUnavailable(message: "\(error)")))
    }
}
```

## PopupState Extension

Add to `PopupState` enum:

```swift
case loadingScreenshot  // "Analyzing screenshot…"
```

In `ImprovePromptFloater`, render `.loadingScreenshot` with a spinner and the message "Analyzing screenshot…" instead of the standard loading message.

## TCC Permissions

| Permission | Required For | Existing? |
|---|---|---|
| Accessibility | AX text read/write | Yes |
| Input Monitoring | Global keyboard events | Yes |
| **Screen Recording** | **`CGDisplayCreateImage`** | **No — new** |

On first double-click Option, if Screen Recording is not granted, show a permission modal. The modal explains that Screen Recording is needed to capture screen regions for the screenshot rewrite feature.

## Preferences

Add to `Preferences.swift`:

```swift
var visionModel: String {
    get { UserDefaults.standard.string(forKey: "visionModel") ?? "qwen2.5-vl:7b" }
    set { UserDefaults.standard.set(newValue, forKey: "visionModel") }
}
```

Add `.visionModel` case to `Preferences.Change` enum. Wire to Settings view in a future iteration (for now, defaults to `qwen2.5-vl:7b`).

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Double-click Option, no Screen Recording | Permission modal shown, flow cancels |
| Double-click Option, press Esc during selection | Selection cancels, nothing happens |
| Vision model not pulled | Error: "Vision model not found. Run `ollama pull qwen2.5-vl:7b`" |
| Vision model times out (60s) | Error: "Rewrite timed out" |
| Image contains no text | Error: "No text found in the selected region" |
| Double-click while text is selected | Screenshot flow takes priority (double-click is explicit intent) |
| Region selection across multiple displays | Only captures from the primary display (limitation noted) |
| Right-click during selection | Cancels selection |

## Testing Strategy

### Unit Tests
- `RegionSelectorControllerTests.swift` — test rect calculation from mouse events (mock)
- `VisionClientTests.swift` — test payload construction, base64 encoding, error mapping
- `Double-click detection` — add tests to `HotkeyEventTap` for timing logic

### Manual Smoke Tests
- [ ] Double-click Option in TextEdit → region selector appears
- [ ] Drag to select region → screenshot captured, popup shows loading
- [ ] Press Esc during selection → selector dismisses, nothing happens
- [ ] Without Screen Recording permission → permission modal shown
- [ ] Without vision model pulled → error message with `ollama pull` instruction
- [ ] Region with no text → appropriate error shown
- [ ] Option+Space still works for text-based rewrite

## Dependencies

- feat-001 (App icon)
- feat-003 (Configurable hotkey)
- feat-005 (Hold-to-reveal button — shares HotkeyEventTap modifications)

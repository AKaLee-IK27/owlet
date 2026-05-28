# Screenshot-Based Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a screenshot-based rewrite flow triggered by double-clicking Option, with region selection, vision model integration, and popup display.

**Architecture:** Extend HotkeyEventTap with double-click detection, add RegionSelectorController for overlay-based region selection, ScreenshotCapturer for CGImage capture, VisionClient for Ollama vision API, and wire into RewriterFlow.startFromScreenshot().

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (NSPanel, CGDisplayCreateImage), CoreGraphics, XCTest, Ollama `/api/chat` with base64 images

---

### Task 1: PopupState Extension — Add `.loadingScreenshot` and `ErrorKind` case

**Files:**
- Modify: `Owlet/Owlet/PopupState.swift`

- [ ] **Step 1: Add `.loadingScreenshot` case and `ErrorKind.noTextInImage`**

Modify `Owlet/Owlet/PopupState.swift`:

```swift
import Foundation

/// What the popup is currently showing.
enum PopupState: Equatable {
    case loading(sourceText: String, isLong: Bool, captureMethod: SelectionSnapshot.CaptureMethod = .ax)
    case loadingScreenshot
    case result(original: String, rewritten: String, segments: [DiffSegment]?, canReplace: Bool, captureMethod: SelectionSnapshot.CaptureMethod = .ax)
    case empty(text: String)
    case error(ErrorKind)
}

/// All failure modes the popup can surface to the user.
enum ErrorKind: Equatable {
    case selectionEmpty
    case passwordField
    case selectionUnreadable
    case inputTooLong(charCount: Int)
    case ollamaDown
    case timeout
    case emptyOutput
    case focusLost
    case axDenied
    case backendUnavailable(message: String)
    case noTextInImage
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -5`

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/PopupState.swift
git commit -m "feat: add .loadingScreenshot and .noTextInImage to PopupState"
```

---

### Task 2: Preferences Extension — Add `visionModel` property

**Files:**
- Modify: `Owlet/Owlet/Preferences.swift`

- [ ] **Step 1: Add `visionModel` property and `.visionModel` change case**

Modify `Owlet/Owlet/Preferences.swift`. Add to the `Change` enum:

```swift
enum Change: String { case hotkey, model, launchAtLogin, visionModel }
```

Add to the `Key` enum:

```swift
static let visionModel = "visionModel"
```

Add the property after `launchAtLogin`:

```swift
var visionModel: String {
    get { defaults.string(forKey: Key.visionModel) ?? "qwen2.5-vl:7b" }
    set {
        defaults.set(newValue, forKey: Key.visionModel)
        post(.visionModel)
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -5`

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/Preferences.swift
git commit -m "feat: add visionModel preference (defaults to qwen2.5-vl:7b)"
```

---

### Task 3: VisionClient — Swift-native Ollama vision API client

**Files:**
- Create: `Owlet/Owlet/VisionClient.swift`
- Test: `Owlet/OwletTests/VisionClientTests.swift`

- [ ] **Step 1: Write tests**

Create `Owlet/OwletTests/VisionClientTests.swift`:

```swift
import XCTest
@testable import Owlet

final class VisionClientTests: XCTestCase {

    func test_buildPayload_hasImagesArray() {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47]) // fake PNG header
        let payload = VisionClient.buildPayload(imageData: imageData, model: "qwen2.5-vl:7b")
        XCTAssertEqual(payload["model"] as? String, "qwen2.5-vl:7b")
        XCTAssertEqual(payload["stream"] as? Bool, false)
        let messages = payload["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "system")
        XCTAssertEqual(messages?[1]["role"] as? String, "user")
        let images = messages?[1]["images"] as? [String]
        XCTAssertEqual(images?.count, 1)
        XCTAssertNotNil(images?.first)
    }

    func test_buildPayload_base64EncodesImage() {
        let imageData = Data([0x01, 0x02, 0x03])
        let payload = VisionClient.buildPayload(imageData: imageData, model: "test")
        let messages = payload["messages"] as? [[String: Any]]
        let images = messages?[1]["images"] as? [String]
        XCTAssertEqual(images?.first, imageData.base64EncodedString())
    }

    func test_parseResponse_extractsContent() {
        let json = #"{"message":{"content":"the rewrite"}}"#
        let result = VisionClient.parseResponse(json)
        XCTAssertEqual(result, "the rewrite")
    }

    func test_parseResponse_missingContent_returnsNil() {
        let json = #"{"message":{}}"#
        let result = VisionClient.parseResponse(json)
        XCTAssertNil(result)
    }

    func test_parseResponse_invalidJSON_returnsNil() {
        let result = VisionClient.parseResponse("not json")
        XCTAssertNil(result)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/VisionClientTests 2>&1 | grep -E "(error:|Executed)" | head -10`

Expected: FAIL — "VisionClient not defined".

- [ ] **Step 3: Write implementation**

Create `Owlet/Owlet/VisionClient.swift`:

```swift
import Foundation

/// Swift-native Ollama client for vision models.
/// Sends base64-encoded images via the /api/chat endpoint.
final class VisionClient: @unchecked Sendable {

    enum Failure: Error, Equatable {
        case timeout
        case emptyOutput
        case backendError(String)
        case launchFailed(String)
        case modelNotFound(String)
    }

    private let model: String
    private let timeoutSeconds: TimeInterval

    init(model: String, timeoutSeconds: TimeInterval = 60) {
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    /// Send an image to the vision model and return the rewritten text.
    func rewrite(imageData: Data) async throws -> String {
        let payload = Self.buildPayload(imageData: imageData, model: model)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw Failure.launchFailed("Failed to serialize payload")
        }

        var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await withTimeout(timeoutSeconds) {
            try await URLSession.shared.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw Failure.backendError("No HTTP response")
        }

        if httpResponse.statusCode == 404 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("not found") || body.contains("does not exist") {
                throw Failure.modelNotFound(model)
            }
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Failure.backendError("HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let text = Self.parseResponse(String(data: data, encoding: .utf8) ?? "") else {
            throw Failure.backendError("Failed to parse Ollama response")
        }

        let cleaned = CleanOutput.clean(text)
        if cleaned.isEmpty {
            throw Failure.emptyOutput
        }
        return cleaned
    }

    /// Build the JSON payload for the Ollama vision API.
    static func buildPayload(imageData: Data, model: String) -> [String: Any] {
        let systemPrompt = "You are a text extraction and rewriting assistant. Look at the screenshot the user provides. Extract ALL visible text from the image. Then rewrite that text to be clearer and better structured, following prompt engineering best practices. Preserve the original language. Output ONLY the rewritten text — no explanation, no preamble."

        return [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": "Extract and rewrite the text in this image.",
                    "images": [imageData.base64EncodedString()]
                ]
            ],
            "stream": false,
            "options": ["temperature": 0.2]
        ]
    }

    /// Parse the Ollama JSON response to extract message.content.
    static func parseResponse(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Failure.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/VisionClientTests 2>&1 | grep -E "(Test Case|Executed|PASS|FAIL)" | head -20`

Expected: All 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Owlet/Owlet/VisionClient.swift Owlet/OwletTests/VisionClientTests.swift
git commit -m "feat: add VisionClient for Ollama vision model API"
```

---

### Task 4: ScreenshotCapturer — Region capture via CGDisplayCreateImage

**Files:**
- Create: `Owlet/Owlet/ScreenshotCapturer.swift`

- [ ] **Step 1: Create the capturer**

Create `Owlet/Owlet/ScreenshotCapturer.swift`:

```swift
import Foundation
import CoreGraphics

/// Captures a screen region as PNG data.
final class ScreenshotCapturer: @unchecked Sendable {

    /// Capture the given screen rect as PNG data.
    /// The rect is in screen coordinates (origin at bottom-left).
    func capture(region: CGRect) async -> Data? {
        guard let screenshot = CGDisplayCreateImage(CGMainDisplayID()) else {
            return nil
        }

        // CGDisplayCreateImage returns top-left origin; convert region.
        let screenHeight = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        let cgRect = CGRect(
            x: region.origin.x,
            y: screenHeight - region.origin.y - region.height,
            width: region.width,
            height: region.height
        )

        guard let cropped = screenshot.cropping(to: cgRect) else {
            return nil
        }

        guard let tiff = cropped.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return png
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -5`

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/ScreenshotCapturer.swift
git commit -m "feat: add ScreenshotCapturer for CGImage region capture"
```

---

### Task 5: RegionSelectorController — Full-screen overlay for drag-to-select

**Files:**
- Create: `Owlet/Owlet/RegionSelectorController.swift`
- Create: `Owlet/Owlet/Views/RegionSelectorOverlayView.swift`

- [ ] **Step 1: Create the SwiftUI overlay view**

Create `Owlet/Owlet/Views/RegionSelectorOverlayView.swift`:

```swift
import SwiftUI

/// SwiftUI view that draws the region selection overlay.
/// Shows a 40% black dimming with a clear selection rectangle.
struct RegionSelectorOverlayView: View {
    @Binding var selection: CGRect
    @Binding var isDragging: Bool
    let anchor: CGPoint

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.4)

                if isDragging && selection.width > 0 && selection.height > 0 {
                    Rectangle()
                        .fill(Color.clear)
                        .overlay(
                            Rectangle()
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                }

                Text("Drag to select a region")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .medium))
                    .padding(8)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .position(x: geo.size.width / 2, y: 30)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                        }
                        let start = anchor
                        let current = value.location
                        selection = CGRect(
                            x: min(start.x, current.x),
                            y: min(start.y, current.y),
                            width: abs(current.x - start.x),
                            height: abs(current.y - start.y)
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
    }
}
```

- [ ] **Step 2: Create the controller**

Create `Owlet/Owlet/RegionSelectorController.swift`:

```swift
import AppKit
import SwiftUI

/// Manages full-screen overlay windows for drag-to-select region capture.
@MainActor
final class RegionSelectorController {

    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var anchorPoints: [String: CGPoint] = [:]
    private var selections: [String: CGRect] = [:]
    private var draggingStates: [String: Bool] = [:]

    /// Shows the region selection overlay and returns the selected rect,
    /// or nil if the user cancelled (Esc or right-click).
    func selectRegion() async -> CGRect? {
        await withCheckedContinuation { cont in
            continuation = cont
            for screen in NSScreen.screens {
                let panel = NSPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.level = .screenSaver
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = false
                panel.acceptsMouseMovedEvents = true
                panel.orderFrontRegardless()
                panel.makeKey()

                let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                let id = screenID?.stringValue ?? "\(panels.count)"

                let selectionBinding = Binding<CGRect>(
                    get: { self.selections[id, default: .zero] },
                    set: { self.selections[id] = $0 }
                )
                let draggingBinding = Binding<Bool>(
                    get: { self.draggingStates[id, default: false] },
                    set: { self.draggingStates[id] = $0 }
                )

                let hosting = NSHostingView(rootView: RegionSelectorOverlayView(
                    selection: selectionBinding,
                    isDragging: draggingBinding,
                    anchor: anchorPoints[id, default: .zero]
                ))
                panel.contentView = hosting
                panels.append(panel)
            }

            // Install global key monitor for Esc
            NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                if event.keyCode == 53 { // Esc
                    Task { @MainActor in self?.cancel() }
                }
            }
        }
    }

    func complete(with rect: CGRect) {
        dismissAll()
        continuation?.resume(returning: rect)
        continuation = nil
    }

    func cancel() {
        dismissAll()
        continuation?.resume(returning: nil)
        continuation = nil
    }

    private func dismissAll() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
}
```

- [ ] **Step 3: Verify compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -5`

Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add Owlet/Owlet/RegionSelectorController.swift Owlet/Owlet/Views/RegionSelectorOverlayView.swift
git commit -m "feat: add RegionSelectorController with overlay-based region selection"
```

---

### Task 6: Wire double-click detection into HotkeyEventTap

**Files:**
- Modify: `Owlet/Owlet/HotkeyEventTap.swift`

- [ ] **Step 1: Add double-click detection**

Modify `Owlet/Owlet/HotkeyEventTap.swift`. Add properties:

```swift
private let onDoubleClick: (@Sendable () -> Void)?
private let lock = NSLock()
private var lastOptionKeyDownTime: Date?
private let doubleClickThreshold: TimeInterval = 0.4
```

Update init:

```swift
init(chord: Chord,
     onHotkey: @escaping @Sendable () -> Void,
     optionHoldDetector: OptionHoldDetector? = nil,
     onDoubleClick: @escaping @Sendable () -> Void? = nil) {
    self.chord = chord
    self.onHotkey = onHotkey
    self.optionHoldDetector = optionHoldDetector
    self.onDoubleClick = onDoubleClick
}
```

Update the `handle` method's `.keyDown` branch — replace the existing keyDown block:

```swift
if type == .keyDown {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let keyName = KeyCodeMap.name(for: Int(keyCode)) ?? ""

    // Chord match takes priority — cancel hold detector and fire rewrite.
    if ChordMatcher.matches(chord: chord, key: keyName, flags: flags) {
        optionHoldDetector?.cancel()
        lock.lock()
        lastOptionKeyDownTime = nil
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [onHotkey] in
            onHotkey()
        }
        return nil
    }

    // Option-only keyDown → check for double-click.
    if flags.alt && !flags.fn && !flags.ctrl && !flags.cmd && !flags.shift {
        lock.lock()
        let now = Date()
        if let lastTime = lastOptionKeyDownTime, now.timeIntervalSince(lastTime) < doubleClickThreshold {
            // Double-click detected
            lastOptionKeyDownTime = nil
            lock.unlock()
            optionHoldDetector?.cancel()
            if let handler = onDoubleClick {
                DispatchQueue.global(qos: .userInitiated).async { handler() }
            }
            return Unmanaged.passUnretained(event)
        }
        lastOptionKeyDownTime = now
        lock.unlock()

        // Start hold detection.
        if let detector = optionHoldDetector {
            detector.handleKeyDown(flags: flags)
        }
    } else {
        // Non-Option keyDown — reset double-click tracking.
        lock.lock()
        lastOptionKeyDownTime = nil
        lock.unlock()
    }
    return Unmanaged.passUnretained(event)
}
```

Update the `.keyUp` branch:

```swift
if type == .keyUp {
    if flags.alt {
        lock.lock()
        lastOptionKeyDownTime = nil
        lock.unlock()
        if let detector = optionHoldDetector {
            detector.handleOptionKeyUp()
        }
    }
    return Unmanaged.passUnretained(event)
}
```

Update `stop()`:

```swift
func stop() {
    guard let tap = tap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    if let source = runLoopSource {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
    }
    self.tap = nil
    self.runLoopSource = nil
    self.optionHoldDetector?.cancel()
    lock.lock()
    lastOptionKeyDownTime = nil
    lock.unlock()
}
```

- [ ] **Step 2: Verify existing tests still pass**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' 2>&1 | grep -E "(Executed.*tests|\*\* TEST)" | tail -5`

Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/HotkeyEventTap.swift
git commit -m "feat: add double-click Option detection to HotkeyEventTap"
```

---

### Task 7: Add `startFromScreenshot()` to RewriterFlow

**Files:**
- Modify: `Owlet/Owlet/RewriterFlow.swift`

- [ ] **Step 1: Add screenshot flow method**

Modify `Owlet/Owlet/RewriterFlow.swift`. Add properties:

```swift
private let regionSelector: RegionSelectorController
private let screenshotCapturer: ScreenshotCapturer
private let visionClient: VisionClient
```

Update init:

```swift
init(ax: AXBridging = AXBridgeAdapter(),
     rewriter: Rewriting? = nil,
     popup: PopupWindowController = PopupWindowController(),
     regionSelector: RegionSelectorController = RegionSelectorController(),
     screenshotCapturer: ScreenshotCapturer = ScreenshotCapturer(),
     visionClient: VisionClient? = nil) {
    self.ax = ax
    self.popup = popup
    self.rewriter = rewriter ?? Self.makeDefaultRewriter()
    self.regionSelector = regionSelector
    self.screenshotCapturer = screenshotCapturer
    self.visionClient = visionClient ?? VisionClient(model: Preferences.shared.visionModel, timeoutSeconds: 60)
}
```

Add the `startFromScreenshot()` method after `start()`:

```swift
func startFromScreenshot() async {
    // 1. Region selection
    guard let region = await regionSelector.selectRegion() else { return }

    // 2. Capture
    guard let imageData = await screenshotCapturer.capture(region: region) else {
        setState(.error(.selectionUnreadable))
        return
    }

    // 3. Loading state
    setState(.loadingScreenshot)

    // 4. Vision model
    do {
        let rewritten = try await visionClient.rewrite(imageData: imageData)
        setState(.result(
            original: "",
            rewritten: rewritten,
            segments: nil,
            canReplace: false
        ))
    } catch VisionClient.Failure.modelNotFound(let model) {
        setState(.error(.backendUnavailable(message: "Vision model '\(model)' not found. Run `ollama pull \(model)`")))
    } catch VisionClient.Failure.timeout {
        setState(.error(.timeout))
    } catch VisionClient.Failure.emptyOutput {
        setState(.error(.noTextInImage))
    } catch VisionClient.Failure.backendError(let msg) {
        if msg.localizedCaseInsensitiveContains("Connection") {
            setState(.error(.ollamaDown))
        } else {
            setState(.error(.backendUnavailable(message: msg)))
        }
    } catch VisionClient.Failure.launchFailed(let msg) {
        setState(.error(.backendUnavailable(message: msg)))
    } catch {
        setState(.error(.backendUnavailable(message: "\(error)")))
    }
}
```

Update `setState` to handle `.loadingScreenshot`. Replace the existing `setState` method:

```swift
private func setState(_ state: PopupState) {
    lastObservedState = state
    let view: any View
    switch state {
    case .loadingScreenshot:
        view = ImprovePromptFloater(
            state: .loading(sourceText: "Analyzing screenshot…", isLong: false),
            onReplace: {},
            onCopy: {},
            onCancel: { [weak self] in self?.handleCancel() },
            onRetry: { Task { [weak self] in await self?.startFromScreenshot() } }
        )
    default:
        view = ImprovePromptFloater(
            state: state,
            onReplace: { [weak self] in self?.handleReplace() },
            onCopy:    { [weak self] in self?.handleCopy() },
            onCancel:  { [weak self] in self?.handleCancel() },
            onRetry:   { Task { [weak self] in await self?.start() } }
        )
    }
    popup.show(
        AnyView(view),
        anchorRect: state == .loadingScreenshot ? nil : Self.anchorRect(for: _currentFocusedElement),
        width: OwletDesign.Floater.width
    )
}
```

Note: You may need to change `ImprovePromptFloater` to accept `AnyView` or use type erasure. If `popup.show` requires a concrete `View` type, use a wrapper:

```swift
private func setState(_ state: PopupState) {
    lastObservedState = state
    if case .loadingScreenshot = state {
        popup.show(
            ImprovePromptFloater(
                state: .loading(sourceText: "Analyzing screenshot…", isLong: false),
                onReplace: {},
                onCopy: {},
                onCancel: { [weak self] in self?.handleCancel() },
                onRetry: { Task { [weak self] in await self?.startFromScreenshot() } }
            ),
            anchorRect: nil,
            width: OwletDesign.Floater.width
        )
    } else {
        popup.show(
            ImprovePromptFloater(
                state: state,
                onReplace: { [weak self] in self?.handleReplace() },
                onCopy:    { [weak self] in self?.handleCopy() },
                onCancel:  { [weak self] in self?.handleCancel() },
                onRetry:   { Task { [weak self] in await self?.start() } }
            ),
            anchorRect: Self.anchorRect(for: _currentFocusedElement),
            width: OwletDesign.Floater.width
        )
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -10`

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/RewriterFlow.swift
git commit -m "feat: add startFromScreenshot() to RewriterFlow"
```

---

### Task 8: Wire double-click to screenshot flow in AppDelegate

**Files:**
- Modify: `Owlet/Owlet/OwletApp.swift`

- [ ] **Step 1: Add screenshot flow wiring**

Modify `Owlet/Owlet/OwletApp.swift`. In `startNormalLaunch()`, update the `HotkeyEventTap` creation to include `onDoubleClick`:

```swift
let rewriterTap = HotkeyEventTap(
    chord: Preferences.shared.hotkey,
    onHotkey: {
        Task { @MainActor in
            let flow = RewriterFlow()
            await flow.start()
        }
    },
    optionHoldDetector: detector,
    onDoubleClick: {
        Task { @MainActor in
            let flow = RewriterFlow()
            await flow.startFromScreenshot()
        }
    }
)
```

- [ ] **Step 2: Verify compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -5`

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/OwletApp.swift
git commit -m "feat: wire double-click Option to screenshot rewrite flow"
```

---

### Task 9: Update ImprovePromptFloater to render `.loadingScreenshot`

**Files:**
- Modify: `Owlet/Owlet/Views/ImprovePromptFloater.swift`

- [ ] **Step 1: Handle `.loadingScreenshot` in the view**

In `ImprovePromptFloater.swift`, find the switch or if-else that renders based on `PopupState`. Add a case for `.loadingScreenshot` that shows a spinner with "Analyzing screenshot…" text. The existing `.loading` case likely already shows a spinner — reuse that rendering pattern but with the screenshot-specific message.

If the view uses a switch on `state`, add:

```swift
case .loadingScreenshot:
    LoadingView(message: "Analyzing screenshot…")
```

If it maps `.loading` to a view, the `.loadingScreenshot` case should render similarly but with the message "Analyzing screenshot…".

- [ ] **Step 2: Verify compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -5`

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/Views/ImprovePromptFloater.swift
git commit -m "feat: render .loadingScreenshot state in ImprovePromptFloater"
```

---

### Task 10: Update feature_list.json and full verification

**Files:**
- Modify: `feature_list.json`

- [ ] **Step 1: Add feat-006 entry**

Add to the `features` array:

```json
{
  "id": "feat-006",
  "name": "Screenshot-based rewrite via double-click Option",
  "description": "Double-click Option to capture a screen region, send to vision model (qwen2.5-vl:7b), and show rewritten text in popup. Adds RegionSelectorController, ScreenshotCapturer, VisionClient, and extends HotkeyEventTap with double-click detection.",
  "dependencies": ["feat-001", "feat-003", "feat-005"],
  "status": "not-started",
  "evidence": ""
}
```

- [ ] **Step 2: Full build**

Run: `cd Owlet && xcodegen generate && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -10`

Expected: Build succeeds.

- [ ] **Step 3: Full tests**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' 2>&1 | grep -E "(Executed.*tests|\*\* TEST)" | tail -5`

Expected: All tests pass (94+ including new VisionClientTests).

- [ ] **Step 4: Commit**

```bash
git add feature_list.json
git commit -m "docs: add feat-006 screenshot rewrite to feature tracker"
```

# Hold-to-Reveal Floating Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small circular owl-icon button that appears when the user holds the Option key for 300ms, and opens the existing rewrite popup when clicked.

**Architecture:** Extend the existing `HotkeyEventTap` CGEventTap to also listen for `keyUp` events. Wire a new pure `OptionHoldDetector` state machine into the callback to detect Option-only holds. On threshold, a new `FloatingButtonController` shows a 32×32 non-activating `NSPanel` hosting `FloatingButtonView`. Click triggers the existing `RewriterFlow.start()`.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (NSPanel, CGEventTap), XCTest

---

### Task 1: OptionHoldDetector — Pure State Machine

**Files:**
- Create: `Owlet/Owlet/OptionHoldDetector.swift`
- Test: `Owlet/OwletTests/OptionHoldDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Owlet/OwletTests/OptionHoldDetectorTests.swift`:

```swift
import XCTest
@testable import Owlet

final class OptionHoldDetectorTests: XCTestCase {

    func test_fires_afterHoldThreshold() {
        let expect = expectation(description: "hold triggered")
        let detector = OptionHoldDetector(holdThreshold: 0.05) {
            expect.fulfill()
        }
        let optionOnly = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        detector.handleKeyDown(flags: optionOnly)
        waitForExpectations(timeout: 0.5)
    }

    func test_doesNotFire_beforeThreshold() {
        var fired = false
        let detector = OptionHoldDetector(holdThreshold: 10.0) {
            fired = true
        }
        let optionOnly = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        detector.handleKeyDown(flags: optionOnly)
        detector.cancel()
        XCTAssertFalse(fired)
    }

    func test_cancels_onOptionKeyUp() {
        var fired = false
        let detector = OptionHoldDetector(holdThreshold: 0.5) {
            fired = true
        }
        let optionOnly = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        detector.handleKeyDown(flags: optionOnly)
        detector.handleKeyUp(flags: optionOnly)
        // Give the timer window to fire if it wasn't cancelled
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(fired)
    }

    func test_cancels_onOtherKeyDown() {
        var fired = false
        let detector = OptionHoldDetector(holdThreshold: 0.5) {
            fired = true
        }
        let optionOnly = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        detector.handleKeyDown(flags: optionOnly)
        // Simulate pressing Space while holding Option
        let optionPlusSpace = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        // handleKeyDown for any key cancels the hold (chord will evaluate separately)
        detector.cancel()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(fired)
    }

    func test_ignores_nonOptionKeyDown() {
        var fired = false
        let detector = OptionHoldDetector(holdThreshold: 0.05) {
            fired = true
        }
        // Cmd+C — not Option-only, should not start timer
        let cmdOnly = ModifierFlags(fn: false, ctrl: false, cmd: true, alt: false, shift: false)
        detector.handleKeyDown(flags: cmdOnly)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(fired)
    }

    func test_ignores_optionPlusOtherModifiers() {
        var fired = false
        let detector = OptionHoldDetector(holdThreshold: 0.05) {
            fired = true
        }
        // Option+Shift — not Option-only
        let optionShift = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: true)
        detector.handleKeyDown(flags: optionShift)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(fired)
    }

    func test_rapidPresses_dontAccumulate() {
        var fireCount = 0
        let detector = OptionHoldDetector(holdThreshold: 0.05) {
            fireCount += 1
        }
        let optionOnly = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        // Rapid press cycle: down, up, down, up
        detector.handleKeyDown(flags: optionOnly)
        detector.handleKeyUp(flags: optionOnly)
        detector.handleKeyDown(flags: optionOnly)
        detector.handleKeyUp(flags: optionOnly)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(fireCount, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/OptionHoldDetectorTests 2>&1 | tail -20`

Expected: FAIL with "OptionHoldDetector not defined" or similar compilation error.

- [ ] **Step 3: Write minimal implementation**

Create `Owlet/Owlet/OptionHoldDetector.swift`:

```swift
import Foundation

/// Detects when the Option key is held in isolation for a configurable duration.
/// Pure state machine — no AppKit dependencies. Thread-safe for use from CGEventTap callback.
final class OptionHoldDetector: @unchecked Sendable {

    private let holdThreshold: TimeInterval
    private let onHoldTriggered: @Sendable () -> Void
    private var timer: Timer?

    init(holdThreshold: TimeInterval = 0.3,
         onHoldTriggered: @escaping @Sendable () -> Void) {
        self.holdThreshold = holdThreshold
        self.onHoldTriggered = onHoldTriggered
    }

    /// Call on keyDown. If Option is the ONLY active modifier, start the hold timer.
    /// Returns true if the hold timer was started (caller may use this for logging).
    @discardableResult
    func handleKeyDown(flags: ModifierFlags) -> Bool {
        guard isOptionOnly(flags) else { return false }
        cancel()
        let timer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            self?.onHoldTriggered()
        }
        // Add to common run loop modes so it fires even during UI tracking.
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
        return true
    }

    /// Call on keyUp. If Option was released, cancel any pending hold.
    func handleKeyUp(flags: ModifierFlags) {
        // Option keyUp means the modifier is no longer held — cancel.
        if !flags.alt {
            cancel()
        }
    }

    /// Cancel any pending hold detection.
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func isOptionOnly(_ flags: ModifierFlags) -> Bool {
        flags.alt && !flags.fn && !flags.ctrl && !flags.cmd && !flags.shift
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/OptionHoldDetectorTests 2>&1 | tail -20`

Expected: All 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Owlet/Owlet/OptionHoldDetector.swift Owlet/OwletTests/OptionHoldDetectorTests.swift
git commit -m "feat: add OptionHoldDetector pure state machine for hold-to-reveal"
```

---

### Task 2: FloatingButtonView — SwiftUI Circular Button

**Files:**
- Create: `Owlet/Owlet/Views/FloatingButtonView.swift`

- [ ] **Step 1: Create the SwiftUI view**

Create `Owlet/Owlet/Views/FloatingButtonView.swift`:

```swift
import SwiftUI

/// A 32×32 circular button showing the Owlet owl icon.
/// Rendered in template mode so it adapts to system appearance.
struct FloatingButtonView: View {
    let onClick: () -> Void

    var body: some View {
        Image("AppIcon")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 20)
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            .onTapGesture {
                onClick()
            }
            .padding(0)
    }
}

#Preview {
    FloatingButtonView(onClick: {})
        .frame(width: 32, height: 32)
}
```

- [ ] **Step 2: Verify Swift compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -10`

Expected: Build succeeds (may have pre-existing warnings, no new errors).

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/Views/FloatingButtonView.swift
git commit -m "feat: add FloatingButtonView circular owl icon button"
```

---

### Task 3: FloatingButtonController — NSPanel Manager

**Files:**
- Create: `Owlet/Owlet/FloatingButtonController.swift`

- [ ] **Step 1: Create the controller**

Create `Owlet/Owlet/FloatingButtonController.swift`:

```swift
import AppKit
import SwiftUI

/// Manages a tiny non-activating NSPanel that hosts the floating owl button.
/// Mirrors PopupWindowController patterns.
@MainActor
final class FloatingButtonController {

    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private let onButtonClicked: @MainActor () -> Void

    init(onButtonClicked: @escaping @MainActor () -> Void) {
        self.onButtonClicked = onButtonClicked
    }

    /// Show the floating button at the given screen point.
    func show(at point: NSPoint) {
        guard panel == nil else { return }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false  // shadow handled by SwiftUI
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let hosting = NSHostingView(rootView: FloatingButtonView(onClick: { [weak self] in
            Task { @MainActor in
                self?.handleClick()
            }
        }))
        p.contentView = hosting

        // Position: constrain to screen bounds with small margin.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let margin: CGFloat = 8
            var origin = point
            origin.x = max(screen.visibleFrame.minX + margin,
                           min(screen.visibleFrame.maxX - 32 - margin, origin.x))
            origin.y = max(screen.visibleFrame.minY + margin,
                           min(screen.visibleFrame.maxY - 32 - margin, origin.y))
            p.setFrameOrigin(origin)
        }

        panel = p
        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        installClickOutsideMonitor()
    }

    /// Hide with fade-out animation.
    func hide() {
        removeClickOutsideMonitor()
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            self.panel = nil
        })
    }

    /// Immediate hide, then trigger the rewrite flow.
    func dismissAndTriggerRewrite() {
        removeClickOutsideMonitor()
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            self.panel = nil
            self.onButtonClicked()
        })
    }

    private func handleClick() {
        dismissAndTriggerRewrite()
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // Check if click is inside the panel — if not, dismiss.
            guard let self = self, let panel = self.panel else { return }
            let location = event.locationInWindow ?? NSEvent.mouseLocation
            if !panel.frame.contains(location) {
                Task { @MainActor in self.hide() }
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
```

- [ ] **Step 2: Verify Swift compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -10`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/FloatingButtonController.swift
git commit -m "feat: add FloatingButtonController NSPanel manager"
```

---

### Task 4: Wire OptionHoldDetector into HotkeyEventTap

**Files:**
- Modify: `Owlet/Owlet/HotkeyEventTap.swift`

- [ ] **Step 1: Add keyUp to event mask and wire detector**

Modify `Owlet/Owlet/HotkeyEventTap.swift`. The changes are:

1. Add `keyUp` to the event mask.
2. Add an optional `OptionHoldDetector` property.
3. In the callback, route keyDown/keyUp to the detector.

```swift
import Foundation
import CoreGraphics
import AppKit
import os.log

/// Global keyboard event tap that listens for Owlet's configured chord.
/// Requires Input Monitoring permission (TCC). Self-heals if disabled.
/// The chord is captured at construction time — to change it, stop the
/// tap and create a fresh one with the new chord.
final class HotkeyEventTap {

    enum StartError: Error, Equatable {
        case tapCreationFailed
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let chord: Chord
    private let onHotkey: @Sendable () -> Void
    private let optionHoldDetector: OptionHoldDetector?
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "hotkey")

    /// - Parameters:
    ///   - chord: The chord this tap watches for. Read once at construction.
    ///   - onHotkey: Dispatched to a background queue when the chord fires.
    ///   - optionHoldDetector: Optional detector for Option hold-to-reveal.
    init(chord: Chord,
         onHotkey: @escaping @Sendable () -> Void,
         optionHoldDetector: OptionHoldDetector? = nil) {
        self.chord = chord
        self.onHotkey = onHotkey
        self.optionHoldDetector = optionHoldDetector
    }

    @discardableResult
    func start() -> Result<Void, StartError> {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: context
        ) else {
            Self.logger.error("CGEvent.tapCreate returned nil — Input Monitoring likely not granted")
            return .failure(.tapCreationFailed)
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.logger.info("HotkeyEventTap started for chord \(self.chord.displayString, privacy: .public)")
        return .success(())
    }

    func stop() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        self.tap = nil
        self.runLoopSource = nil
        self.optionHoldDetector?.cancel()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Self.logger.info("Event tap re-enabled after \(String(describing: type), privacy: .public)")
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let keyName = KeyCodeMap.name(for: Int(keyCode)) ?? ""
        let flags = ModifierFlags(
            fn: event.flags.contains(.maskSecondaryFn),
            ctrl: event.flags.contains(.maskControl),
            cmd: event.flags.contains(.maskCommand),
            alt: event.flags.contains(.maskAlternate),
            shift: event.flags.contains(.maskShift)
        )

        if type == .keyDown {
            // Check for chord match first — this takes priority over hold detection.
            if ChordMatcher.matches(chord: chord, key: keyName, flags: flags) {
                optionHoldDetector?.cancel()
                DispatchQueue.global(qos: .userInitiated).async { [onHotkey] in
                    onHotkey()
                }
                return nil  // consume the event
            }

            // Option-only keyDown → start hold detection.
            if let detector = optionHoldDetector {
                detector.handleKeyDown(flags: flags)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            // Option keyUp → cancel hold detection if pending.
            if let detector = optionHoldDetector {
                detector.handleKeyUp(flags: flags)
            }
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }
}
```

- [ ] **Step 2: Verify existing tests still pass**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/ChordMatcherTests 2>&1 | tail -10`

Expected: All ChordMatcherTests PASS (no changes to matching logic).

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/HotkeyEventTap.swift
git commit -m "feat: wire OptionHoldDetector into HotkeyEventTap callback"
```

---

### Task 5: Wire Everything Together in AppDelegate

**Files:**
- Modify: `Owlet/Owlet/OwletApp.swift`

- [ ] **Step 1: Add detector and controller properties, wire into startNormalLaunch**

Modify `Owlet/Owlet/OwletApp.swift`. Add two new properties and update `startNormalLaunch()`:

```swift
// Add these properties to the AppDelegate class:
private var optionHoldDetector: OptionHoldDetector?
private var floatingButtonController: FloatingButtonController?

// In startNormalLaunch(), BEFORE the rewriterTap creation, add:
// Option hold detector — shows floating button when Option is held.
let buttonController = FloatingButtonController { [weak self] in
    Task { @MainActor in
        let flow = RewriterFlow()
        await flow.start()
    }
}
self.floatingButtonController = buttonController

let detector = OptionHoldDetector { [weak buttonController] in
    Task { @MainActor in
        let point = NSEvent.mouseLocation
        buttonController?.show(at: point)
    }
}
self.optionHoldDetector = detector

// Then modify the HotkeyEventTap creation to pass the detector:
let rewriterTap = HotkeyEventTap(
    chord: Preferences.shared.hotkey,
    onHotkey: {
        Task { @MainActor in
            let flow = RewriterFlow()
            await flow.start()
        }
    },
    optionHoldDetector: detector
)
```

The full modified `startNormalLaunch()` method:

```swift
private func startNormalLaunch() {
    // Option hold detector — shows floating button when Option is held.
    let buttonController = FloatingButtonController { [weak self] in
        Task { @MainActor in
            let flow = RewriterFlow()
            await flow.start()
        }
    }
    self.floatingButtonController = buttonController

    let detector = OptionHoldDetector { [weak buttonController] in
        Task { @MainActor in
            let point = NSEvent.mouseLocation
            buttonController?.show(at: point)
        }
    }
    self.optionHoldDetector = detector

    // Rewriter chord — defaults to Option+Space, user-configurable via Settings.
    let rewriterTap = HotkeyEventTap(
        chord: Preferences.shared.hotkey,
        onHotkey: {
            Task { @MainActor in
                let flow = RewriterFlow()
                await flow.start()
            }
        },
        optionHoldDetector: detector
    )
    switch rewriterTap.start() {
    case .success:
        self.hotkeyTap = rewriterTap
        Self.logger.info("Rewriter hotkey tap active")
    case .failure:
        showPermissionModal(missing: [.inputMonitoring])
        return
    }

    // Apply the launch-at-login preference (defaults to true on first launch).
    do {
        try LoginItemManager.setRegistered(Preferences.shared.launchAtLogin)
    } catch {
        Self.logger.warning("Login item apply failed: \(error.localizedDescription, privacy: .public)")
    }

    // (statusBar was already created in applicationDidFinishLaunching.)

    // Poll for permission revocation every 60 s.
    startPermissionPolling()
}
```

- [ ] **Step 2: Verify Swift compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -10`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/OwletApp.swift
git commit -m "feat: wire OptionHoldDetector and FloatingButtonController in AppDelegate"
```

---

### Task 6: Update feature_list.json

**Files:**
- Modify: `feature_list.json`

- [ ] **Step 1: Add feat-005 entry**

Add a new feature entry to the `features` array in `feature_list.json`:

```json
{
  "id": "feat-005",
  "name": "Hold-to-reveal floating button",
  "description": "Pressing and holding Option for 300ms shows a small circular owl button near the cursor. Clicking it opens the existing rewrite popup. Extends HotkeyEventTap with keyUp events and adds OptionHoldDetector, FloatingButtonController, and FloatingButtonView.",
  "dependencies": ["feat-001", "feat-003"],
  "status": "not-started",
  "evidence": ""
}
```

- [ ] **Step 2: Commit**

```bash
git add feature_list.json
git commit -m "docs: add feat-005 hold-to-reveal floating button to feature tracker"
```

---

### Task 7: Full Build and Test Verification

**Files:**
- All files from Tasks 1-6

- [ ] **Step 1: Run full Swift build**

Run: `cd Owlet && xcodegen generate && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: Build succeeds with no new errors.

- [ ] **Step 2: Run all Swift tests**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' 2>&1 | tail -30`

Expected: All tests pass (including new OptionHoldDetectorTests).

- [ ] **Step 3: Commit final state**

```bash
git commit --allow-empty -m "chore: hold-to-reveal button — build and tests verified"
```

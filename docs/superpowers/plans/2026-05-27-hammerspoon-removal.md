# Hammerspoon Removal Implementation Plan (v0.2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Owlet a self-contained macOS app — drop the Hammerspoon dependency entirely. Owlet owns the global `fn+Ctrl+R` hotkey via its own `CGEventTap`, Cmd+C capture in Swift, registers as a login item, and ships a combined first-launch permission flow.

**Architecture:** Single process. Swift `HotkeyEventTap` listens for the chord, dispatches capture (Cmd+C) and popup work to background queues. `PermissionChecker` runs on launch; if Accessibility or Input Monitoring is missing, a single modal explains both with deep-link buttons and the app quits. After permissions are granted, `LoginItemManager.SMAppService.mainApp` registers for auto-start at login.

**Tech Stack:** Swift 6.3 / SwiftUI / AppKit / CoreGraphics (`CGEventTap`) / IOKit.hid (`IOHIDCheckAccess`) / ServiceManagement (`SMAppService`) / ApplicationServices (AX). XCTest. xcodegen. macOS 14+.

**Reference spec:** `docs/superpowers/specs/2026-05-27-hammerspoon-removal-design.md`

**Total tasks:** 13 across 7 phases. Each phase produces a coherent checkpoint.

---

## Phase 1 — Information architecture cleanup (remove URL scheme + dead code)

### Task 1: Delete URL-scheme components and their tests

**Files:**
- Delete: `Owlet/Owlet/URLSchemeParser.swift`
- Delete: `Owlet/Owlet/CommandDispatcher.swift`
- Delete: `Owlet/Owlet/UnavailableFlow.swift`
- Delete: `Owlet/Owlet/CaptureFlow.swift` (protocol becomes unused after UnavailableFlow goes; if any other file imports it, keep it — verify)
- Delete: `Owlet/Owlet/HotkeyCoordinator.swift`
- Delete: `Owlet/OwletTests/URLSchemeTests.swift`
- Delete: `Owlet/OwletTests/CommandDispatcherTests.swift`
- Delete: `Owlet/OwletTests/HotkeyCoordinatorTests.swift`

- [ ] **Step 1: Verify which symbols are still referenced**

Run:
```bash
cd ~/repos/owlet/Owlet
grep -rln "CommandDispatcher\|UnavailableFlow\|URLSchemeParser\|HotkeyCoordinator\|OwletVerb\|CaptureFlow" Owlet/ OwletTests/
```

Expected: matches in `OwletApp.swift` (uses CommandDispatcher + URLSchemeParser + HotkeyCoordinator), `RewriterFlow.swift` (conforms to `CaptureFlow` protocol).

Document the matches; you'll handle them in Step 2.

- [ ] **Step 2: Strip references from `OwletApp.swift` and `RewriterFlow.swift`**

In `Owlet/Owlet/OwletApp.swift`, remove the entire `handleGetURL`, `invokeCurrentVerb`, `setEventHandler` registration, and `HotkeyCoordinator` instantiation. Replace `AppDelegate` body with a placeholder that does only the AX trust check (Task 8 rewires it fully):

```swift
import SwiftUI
import AppKit

@main
struct OwletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Placeholder — Task 8 wires the full launch tree.
        if !AXBridge.isTrusted(promptIfNeeded: true) {
            NSApp.terminate(nil)
        }
    }
}
```

In `Owlet/Owlet/RewriterFlow.swift`, remove the `: CaptureFlow` protocol conformance and the `tag` property. The class doesn't need a protocol since v0.2 only has one flow:

```swift
// Find:
final class RewriterFlow: CaptureFlow {
    let tag = "rewriter"
// Replace with:
final class RewriterFlow {
```

- [ ] **Step 3: Delete the files**

```bash
cd ~/repos/owlet
rm Owlet/Owlet/URLSchemeParser.swift
rm Owlet/Owlet/CommandDispatcher.swift
rm Owlet/Owlet/UnavailableFlow.swift
rm Owlet/Owlet/CaptureFlow.swift
rm Owlet/Owlet/HotkeyCoordinator.swift
rm Owlet/OwletTests/URLSchemeTests.swift
rm Owlet/OwletTests/CommandDispatcherTests.swift
rm Owlet/OwletTests/HotkeyCoordinatorTests.swift
```

- [ ] **Step 4: Regenerate Xcode project + verify build**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: build succeeds, fewer tests (~10 removed). TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
cd ~/repos/owlet
git add -A
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "refactor(owlet): remove URL-scheme components for v0.2 migration

URLSchemeParser, CommandDispatcher, UnavailableFlow, CaptureFlow protocol,
and HotkeyCoordinator are dead code once Owlet owns the hotkey directly.
Their tests removed. AppDelegate temporarily simplified — Task 8 rewires
the full launch tree. RewriterFlow no longer conforms to CaptureFlow."
```

---

## Phase 2 — Pure-logic Swift modules (TDD)

### Task 2: `ChordMatcher` pure function with tests

**Files:**
- Create: `Owlet/Owlet/ChordMatcher.swift`
- Test: `Owlet/OwletTests/ChordMatcherTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Owlet/OwletTests/ChordMatcherTests.swift`:

```swift
import XCTest
@testable import Owlet

final class ChordMatcherTests: XCTestCase {

    func test_exactChord_matches() {
        let flags = ModifierFlags(fn: true, ctrl: true, cmd: false, alt: false, shift: false)
        XCTAssertTrue(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_missingFn_doesNotMatch() {
        let flags = ModifierFlags(fn: false, ctrl: true, cmd: false, alt: false, shift: false)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_missingCtrl_doesNotMatch() {
        let flags = ModifierFlags(fn: true, ctrl: false, cmd: false, alt: false, shift: false)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_extraCmd_doesNotMatch() {
        let flags = ModifierFlags(fn: true, ctrl: true, cmd: true, alt: false, shift: false)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_extraShift_doesNotMatch() {
        let flags = ModifierFlags(fn: true, ctrl: true, cmd: false, alt: false, shift: true)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_extraAlt_doesNotMatch() {
        let flags = ModifierFlags(fn: true, ctrl: true, cmd: false, alt: true, shift: false)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "r", flags: flags))
    }

    func test_wrongKey_doesNotMatch() {
        let flags = ModifierFlags(fn: true, ctrl: true, cmd: false, alt: false, shift: false)
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "t", flags: flags))
        XCTAssertFalse(ChordMatcher.isOwletRewrite(key: "", flags: flags))
    }
}
```

- [ ] **Step 2: Run, verify they fail**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: compile error — `ChordMatcher` and `ModifierFlags` undefined.

- [ ] **Step 3: Implement**

Create `Owlet/Owlet/ChordMatcher.swift`:

```swift
import Foundation

/// Modifier state at the moment a key was pressed. Captured from CGEvent flags
/// (or hs.eventtap flags during testing) and passed into the pure chord matcher.
struct ModifierFlags: Equatable {
    let fn: Bool
    let ctrl: Bool
    let cmd: Bool
    let alt: Bool
    let shift: Bool
}

/// Pure function: does this key + flag combination match Owlet's hotkey?
/// Kept pure so it's table-testable without any CGEvent or AppKit dependency.
/// v0.2 hardcodes the chord; v0.3 may make it configurable.
enum ChordMatcher {

    /// Match exactly fn+ctrl+r — no other modifier may be present.
    static func isOwletRewrite(key: String, flags: ModifierFlags) -> Bool {
        return key == "r"
            && flags.fn && flags.ctrl
            && !flags.cmd && !flags.alt && !flags.shift
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: 7 new `ChordMatcherTests` pass.

- [ ] **Step 5: Commit**

```bash
cd ~/repos/owlet
git add Owlet/Owlet/ChordMatcher.swift Owlet/OwletTests/ChordMatcherTests.swift
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "feat(owlet): add ChordMatcher pure function

isOwletRewrite(key:flags:) returns true only for exact fn+ctrl+r match
(no other modifiers allowed). Pure function = trivially table-testable.
Used by HotkeyEventTap in the next task."
```

---

### Task 3: `PermissionChecker` with mocked probe

**Files:**
- Create: `Owlet/Owlet/PermissionChecker.swift`
- Test: `Owlet/OwletTests/PermissionCheckerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Owlet/OwletTests/PermissionCheckerTests.swift`:

```swift
import XCTest
@testable import Owlet

final class PermissionCheckerTests: XCTestCase {

    private struct MockProbe: PermissionProbe {
        let ax: Bool
        let im: Bool
        func isAccessibilityGranted() -> Bool { ax }
        func isInputMonitoringGranted() -> Bool { im }
    }

    func test_bothGranted_returnsAllGranted() {
        let result = PermissionChecker.check(probe: MockProbe(ax: true, im: true))
        XCTAssertEqual(result, .allGranted)
    }

    func test_noneGranted_returnsBothMissing() {
        let result = PermissionChecker.check(probe: MockProbe(ax: false, im: false))
        XCTAssertEqual(result, .missing([.accessibility, .inputMonitoring]))
    }

    func test_onlyAXMissing() {
        let result = PermissionChecker.check(probe: MockProbe(ax: false, im: true))
        XCTAssertEqual(result, .missing([.accessibility]))
    }

    func test_onlyIMMissing() {
        let result = PermissionChecker.check(probe: MockProbe(ax: true, im: false))
        XCTAssertEqual(result, .missing([.inputMonitoring]))
    }
}
```

- [ ] **Step 2: Run, verify they fail (types undefined)**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' test 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

Create `Owlet/Owlet/PermissionChecker.swift`:

```swift
import Foundation
import ApplicationServices
import IOKit.hid

enum Permission: String, Hashable, CaseIterable {
    case accessibility
    case inputMonitoring
}

enum PermissionStatus: Equatable {
    case allGranted
    case missing(Set<Permission>)
}

/// Test seam: production uses `SystemProbe`, tests inject a mock.
protocol PermissionProbe {
    func isAccessibilityGranted() -> Bool
    func isInputMonitoringGranted() -> Bool
}

struct SystemProbe: PermissionProbe {
    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }
    func isInputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
}

enum PermissionChecker {
    static func check(probe: PermissionProbe = SystemProbe()) -> PermissionStatus {
        var missing = Set<Permission>()
        if !probe.isAccessibilityGranted() { missing.insert(.accessibility) }
        if !probe.isInputMonitoringGranted() { missing.insert(.inputMonitoring) }
        return missing.isEmpty ? .allGranted : .missing(missing)
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: 4 new `PermissionCheckerTests` pass.

- [ ] **Step 5: Commit**

```bash
cd ~/repos/owlet
git add Owlet/Owlet/PermissionChecker.swift Owlet/OwletTests/PermissionCheckerTests.swift
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "feat(owlet): add PermissionChecker for AX + Input Monitoring

PermissionProbe protocol seam allows mocking AXIsProcessTrusted and
IOHIDCheckAccess for tests. 4 unit tests cover all 4 grant combinations.
SystemProbe is the production implementation."
```

---

### Task 4: `LoginItemManager` with status-based decision tests

**Files:**
- Create: `Owlet/Owlet/LoginItemManager.swift`
- Test: `Owlet/OwletTests/LoginItemManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Owlet/OwletTests/LoginItemManagerTests.swift`:

```swift
import XCTest
import ServiceManagement
@testable import Owlet

final class LoginItemManagerTests: XCTestCase {

    func test_shouldRegister_whenStatusEnabled_returnsFalse() {
        XCTAssertFalse(LoginItemManager.shouldRegister(status: .enabled))
    }

    func test_shouldRegister_whenStatusNotRegistered_returnsTrue() {
        XCTAssertTrue(LoginItemManager.shouldRegister(status: .notRegistered))
    }

    func test_shouldRegister_whenStatusRequiresApproval_returnsTrue() {
        XCTAssertTrue(LoginItemManager.shouldRegister(status: .requiresApproval))
    }

    func test_shouldRegister_whenStatusNotFound_returnsTrue() {
        XCTAssertTrue(LoginItemManager.shouldRegister(status: .notFound))
    }
}
```

- [ ] **Step 2: Run, verify they fail**

- [ ] **Step 3: Implement**

Create `Owlet/Owlet/LoginItemManager.swift`:

```swift
import Foundation
import ServiceManagement
import os.log

enum LoginItemManager {
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "loginitem")

    /// Pure decision: should we attempt to register based on current status?
    /// Only skip if already enabled — every other status is worth trying.
    static func shouldRegister(status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled: return false
        case .notRegistered, .requiresApproval, .notFound: return true
        @unknown default: return true  // optimistic; try registering on future cases
        }
    }

    /// Register Owlet as a login item if it's not already enabled.
    /// No-op (with logging) if registration fails. Doesn't throw — login item
    /// failure is non-fatal; the app still works for the current session.
    static func registerIfNeeded() {
        let service = SMAppService.mainApp
        guard shouldRegister(status: service.status) else {
            logger.info("Login item already enabled, skipping register")
            return
        }
        do {
            try service.register()
            logger.info("Registered Owlet as a login item")
        } catch {
            logger.error("Failed to register login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Exposed for a future settings UI. Not called in v0.2.
    static func unregister() {
        let service = SMAppService.mainApp
        do {
            try service.unregister()
        } catch {
            logger.error("Failed to unregister login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit**

```bash
cd ~/repos/owlet
git add Owlet/Owlet/LoginItemManager.swift Owlet/OwletTests/LoginItemManagerTests.swift
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "feat(owlet): add LoginItemManager via SMAppService

shouldRegister(status:) pure decision table-tested for all 4
SMAppService.Status cases. registerIfNeeded() is called once on launch
when permissions are granted (in Task 8 — OwletApp rewire)."
```

---

## Phase 3 — Platform integration

### Task 5: `HotkeyEventTap` (CGEventTap wiring)

**Files:**
- Create: `Owlet/Owlet/HotkeyEventTap.swift`

No unit tests for the event tap itself — CGEventTap requires the OS keyboard subsystem and granted Input Monitoring permission. The chord-matching logic is already tested via `ChordMatcher`. Manual smoke verifies tap creation.

- [ ] **Step 1: Implement**

Create `Owlet/Owlet/HotkeyEventTap.swift`:

```swift
import Foundation
import CoreGraphics
import AppKit
import os.log

/// Global keyboard event tap that listens for Owlet's hotkey chord.
/// Requires Input Monitoring permission (TCC). Self-heals if disabled.
/// Callback dispatches the user's work to a background queue so the tap
/// itself doesn't block (macOS kills taps that take too long).
final class HotkeyEventTap {

    enum StartError: Error, Equatable {
        case tapCreationFailed
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onHotkey: @Sendable () -> Void
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "hotkey")

    init(onHotkey: @escaping @Sendable () -> Void) {
        self.onHotkey = onHotkey
    }

    /// Start the event tap. Returns success/failure — caller surfaces
    /// `.tapCreationFailed` to the user via the permission modal flow.
    @discardableResult
    func start() -> Result<Void, StartError> {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
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
        Self.logger.info("HotkeyEventTap started")
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
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Self-heal: re-enable the tap if macOS disabled it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Self.logger.info("Event tap re-enabled after \(String(describing: type), privacy: .public)")
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let keyName = keyCodeToString(Int(keyCode))
        let flags = ModifierFlags(
            fn: event.flags.contains(.maskSecondaryFn),
            ctrl: event.flags.contains(.maskControl),
            cmd: event.flags.contains(.maskCommand),
            alt: event.flags.contains(.maskAlternate),
            shift: event.flags.contains(.maskShift)
        )

        guard ChordMatcher.isOwletRewrite(key: keyName, flags: flags) else {
            return Unmanaged.passUnretained(event)  // pass through
        }

        // Consume the event AND dispatch the work async so the tap doesn't block.
        DispatchQueue.global(qos: .userInitiated).async { [onHotkey] in
            onHotkey()
        }
        return nil
    }

    /// Maps CGKeyCode to a single-character string. v0.2 only needs 'r'; other
    /// keys return "" which never matches the chord. If the chord becomes
    /// configurable in v0.3 this needs UCKeyTranslate for full layout support.
    private func keyCodeToString(_ keyCode: Int) -> String {
        switch keyCode {
        case 15: return "r"          // US/most layouts
        default: return ""
        }
    }
}
```

- [ ] **Step 2: Regenerate + build**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd ~/repos/owlet
git add Owlet/Owlet/HotkeyEventTap.swift
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "feat(owlet): add HotkeyEventTap via CGEventTap

Listens for fn+Ctrl+R system-wide via cgSessionEventTap. Self-heals on
tapDisabledByTimeout and tapDisabledByUserInput. Callback dispatches
the hotkey handler async (background qos: .userInitiated) so the tap
itself never blocks. ChordMatcher (already tested) does the match.
Returns .failure(.tapCreationFailed) if Input Monitoring isn't granted."
```

---

### Task 6: `AXBridge.swiftCmdCCapture()` (Swift port of Hammerspoon's capture)

**Files:**
- Modify: `Owlet/Owlet/AXBridge.swift`

- [ ] **Step 1: Add the new function**

Append to `Owlet/Owlet/AXBridge.swift` (after the existing `clipboardRoundtripCopy`-was-deleted gap):

```swift
extension AXBridge {

    /// Capture the source app's current selection by synthesizing Cmd+C.
    /// Mirrors the Hammerspoon Lua capture: wait for the user to release
    /// fn+ctrl (otherwise the chord taints our Cmd+C with extra modifiers
    /// and the source app's Copy handler doesn't fire), post Cmd+C with
    /// explicit cmd-only flags, then poll the pasteboard for a changeCount
    /// increment up to 1 s. Returns nil if no new text appeared.
    /// Caller is responsible for restoring the original clipboard.
    static func swiftCmdCCapture() -> (text: String, savedClipboard: String?)? {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let beforeCount = pb.changeCount

        // Wait for fn+ctrl release (up to 300 ms). Check current global
        // modifier state via NSEvent's class API.
        let releaseDeadline = Date().addingTimeInterval(0.3)
        while Date() < releaseDeadline {
            let m = NSEvent.modifierFlags
            let fnHeld = m.contains(.function)
            let ctrlHeld = m.contains(.control)
            if !fnHeld && !ctrlHeld { break }
            usleep(10_000)
        }

        // Post Cmd+C with EXPLICIT cmd-only flags (no leftover hardware state).
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // Poll for clipboard change (up to 1 s).
        let deadline = Date().addingTimeInterval(1.0)
        while pb.changeCount == beforeCount && Date() < deadline {
            usleep(20_000)
        }

        let captured = pb.string(forType: .string)
        if pb.changeCount == beforeCount { return nil }              // no Cmd+C response
        guard let text = captured, !text.isEmpty else { return nil } // changed but empty
        if text == saved { return nil }                              // changed but identical

        return (text: text, savedClipboard: saved)
    }
}
```

- [ ] **Step 2: Wire `capture()` to call `swiftCmdCCapture()` when AX read fails**

Find the existing `capture()` function in `AXBridge.swift`. It currently reads from `NSPasteboard.general.string(forType: .string)` directly as a fallback (from the earlier capture-via-hammerspoon refactor). Replace that fallback block with a call to `swiftCmdCCapture()`:

```swift
static func capture() -> CaptureOutcome {
    let focus = currentFocus()

    if let focus = focus, isPasswordField(focus.focusedElement) {
        return .passwordField
    }

    // Fast path: AX read (cooperative apps).
    if let focus = focus,
       let text = readSelectedText(from: focus.focusedElement),
       !text.isEmpty {
        return .captured(SelectionSnapshot(
            text: text,
            sourceAppBundleID: focus.appBundleID,
            focusedElement: focus.focusedElement,
            captureMethod: .ax
        ))
    }

    // Fallback: synthesize Cmd+C in Swift (handles Electron, Chrome, Terminal).
    if let result = swiftCmdCCapture() {
        // Schedule the saved-clipboard restore after a delay so the popup
        // has time to read and the user has time to act on it.
        if let saved = result.savedClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(saved, forType: .string)
            }
        }
        return .captured(SelectionSnapshot(
            text: result.text,
            sourceAppBundleID: focus?.appBundleID ?? "",
            focusedElement: focus?.focusedElement,
            captureMethod: .clipboardFallback
        ))
    }

    return focus == nil ? .noFocus : .empty
}
```

- [ ] **Step 3: Run existing tests, confirm still pass**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: existing tests still pass (RewriterFlowTests' MockAX returns a captured outcome; the new `swiftCmdCCapture` is only exercised by the real `AXBridge` in manual smoke).

- [ ] **Step 4: Commit**

```bash
cd ~/repos/owlet
git add Owlet/Owlet/AXBridge.swift
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "feat(owlet): add Swift Cmd+C capture (port of Hammerspoon Lua)

swiftCmdCCapture() waits for fn+ctrl release (300ms cap), posts Cmd+C
with explicit cmd-only flags, polls pasteboard changeCount up to 1s,
returns (text, savedClipboard) tuple. Capture flow in capture() uses
this when AX read fails — handles Electron/Chrome/Terminal apps that
don't expose AXSelectedText. Saved-clipboard restore schedules 5s later
so the user has time to act on the popup."
```

---

## Phase 4 — UI

### Task 7: `PermissionModal` SwiftUI view

**Files:**
- Create: `Owlet/Owlet/Views/PermissionModal.swift`
- Create: `Owlet/Owlet/PermissionModalWindowController.swift`

- [ ] **Step 1: Create the SwiftUI view**

Create `Owlet/Owlet/Views/PermissionModal.swift`:

```swift
import SwiftUI
import AppKit

struct PermissionModal: View {
    let missing: Set<Permission>
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Owlet needs two macOS permissions")
                .font(.system(size: 17, weight: .semibold))

            Text("Grant these in System Settings, then quit and relaunch Owlet from /Applications.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                if missing.contains(.accessibility) {
                    permissionRow(
                        title: "Accessibility",
                        explanation: "To read the text you've selected and replace it with the rewrite.",
                        buttonTitle: "Open Accessibility…",
                        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    )
                }
                if missing.contains(.inputMonitoring) {
                    permissionRow(
                        title: "Input Monitoring",
                        explanation: "To detect your fn+Ctrl+R hotkey system-wide.",
                        buttonTitle: "Open Input Monitoring…",
                        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
                    )
                }
            }

            HStack {
                Spacer()
                Button("Quit", action: onQuit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func permissionRow(title: String, explanation: String, buttonTitle: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary)
            Button(buttonTitle) {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
        }
    }
}
```

- [ ] **Step 2: Create the window controller**

Create `Owlet/Owlet/PermissionModalWindowController.swift`:

```swift
import AppKit
import SwiftUI

/// Hosts PermissionModal in a regular (activating) window so the user can
/// click the deep-link buttons. Owlet stays alive until the user clicks Quit.
final class PermissionModalWindowController {

    private var window: NSWindow?

    func show(missing: Set<Permission>, onQuit: @escaping () -> Void) {
        let modal = PermissionModal(missing: missing, onQuit: onQuit)
        let hosting = NSHostingController(rootView: modal)
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable]
        w.title = "Owlet — Permissions Required"
        w.level = .floating
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)  // show in Dock so window can be focused
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    func hide() {
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
```

- [ ] **Step 3: Build verify**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd ~/repos/owlet
git add Owlet/Owlet/Views/PermissionModal.swift Owlet/Owlet/PermissionModalWindowController.swift
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "feat(owlet): add PermissionModal and window controller

SwiftUI view shows a row per missing permission with a deep-link
button (x-apple.systempreferences:... URLs). Window controller
flips Owlet to .regular activation policy while the modal is up
so the user can focus and click; returns to .accessory after."
```

---

## Phase 5 — Wiring

### Task 8: Rewire `OwletApp.swift` launch tree

**Files:**
- Modify: `Owlet/Owlet/OwletApp.swift`

- [ ] **Step 1: Replace `OwletApp.swift` with the full launch tree**

Replace the file content with:

```swift
import SwiftUI
import AppKit
import os.log

@main
struct OwletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "app")

    private var permissionModal: PermissionModalWindowController?
    private var hotkeyTap: HotkeyEventTap?
    private var permissionPollTimer: Timer?
    private var lastKnownPermissionStatus: PermissionStatus = .allGranted

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = PermissionChecker.check()
        lastKnownPermissionStatus = status

        switch status {
        case .allGranted:
            startNormalLaunch()
        case .missing(let missing):
            showPermissionModal(missing: missing)
        }
    }

    private func startNormalLaunch() {
        // Wire the event tap.
        let tap = HotkeyEventTap { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                let flow = RewriterFlow()
                await flow.start()
            }
        }
        switch tap.start() {
        case .success:
            self.hotkeyTap = tap
            Self.logger.info("Hotkey tap active")
        case .failure:
            // Should be rare since PermissionChecker said all granted; defensive
            showPermissionModal(missing: [.inputMonitoring])
            return
        }

        // Register login item (no-op if already registered).
        LoginItemManager.registerIfNeeded()

        // Poll for permission revocation every 60 s.
        startPermissionPolling()
    }

    private func showPermissionModal(missing: Set<Permission>) {
        let controller = PermissionModalWindowController()
        controller.show(missing: missing) {
            NSApp.terminate(nil)
        }
        self.permissionModal = controller
    }

    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let current = PermissionChecker.check()
            if current != self.lastKnownPermissionStatus {
                self.lastKnownPermissionStatus = current
                if case .missing(let missing) = current {
                    self.notifyPermissionRevoked(missing: missing)
                }
            }
        }
    }

    private func notifyPermissionRevoked(missing: Set<Permission>) {
        let names = missing.map { $0.rawValue }.sorted().joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Owlet stopped working"
        alert.informativeText = "A required permission was revoked: \(names). Re-grant in System Settings, then relaunch Owlet."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit Owlet")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if missing.contains(.accessibility) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            if missing.contains(.inputMonitoring) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            }
        }
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 2: Run all tests**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: all tests still pass (RewriterFlow's tests use injected mocks; AppDelegate isn't exercised in tests).

- [ ] **Step 3: Commit**

```bash
cd ~/repos/owlet
git add Owlet/Owlet/OwletApp.swift
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "feat(owlet): rewire launch tree, drop URL handler

OwletApp.applicationDidFinishLaunching now:
1. Checks permissions via PermissionChecker
2. If missing: shows PermissionModal, quits on Quit click
3. If granted: starts HotkeyEventTap, registers login item via SMAppService,
   starts a 60s permission-revocation poll Timer
4. If permissions revoked post-launch: shows alert + quits

URL handler (NSAppleEventManager.setEventHandler) removed entirely."
```

---

## Phase 6 — Build + Install

### Task 9: `project.yml` updates (Info.plist + entitlements)

**Files:**
- Modify: `Owlet/project.yml`

- [ ] **Step 1: Edit project.yml**

In `Owlet/project.yml`, remove the `CFBundleURLTypes` entry (lines that look like):

```yaml
        CFBundleURLTypes:
          - CFBundleURLName: co.greenpassport.owlet
            CFBundleURLSchemes:
              - owlet
```

And add `NSInputMonitoringUsageDescription` to the info.properties block:

```yaml
        NSInputMonitoringUsageDescription: "Owlet needs Input Monitoring to detect your fn+Ctrl+R hotkey system-wide."
```

The full `info.properties` block should look like:

```yaml
    info:
      path: Owlet/Info.plist
      properties:
        CFBundleName: Owlet
        CFBundleDisplayName: Owlet
        CFBundleShortVersionString: "0.2.0"
        CFBundleVersion: "2"
        LSUIElement: YES
        NSAccessibilityUsageDescription: "Owlet needs Accessibility to read the text you select and to replace it with the rewritten version when you click Replace."
        NSInputMonitoringUsageDescription: "Owlet needs Input Monitoring to detect your fn+Ctrl+R hotkey system-wide."
```

- [ ] **Step 2: Regenerate and verify**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug build 2>&1 | tail -3
```

Then verify Info.plist has the new key and doesn't have URL types:

```bash
plutil -p Owlet/Owlet/Info.plist | grep -E "InputMonitoring|URLTypes|ShortVersion"
```

Expected: `NSInputMonitoringUsageDescription` present, `CFBundleURLTypes` absent, `CFBundleShortVersionString` = "0.2.0".

- [ ] **Step 3: Commit**

```bash
cd ~/repos/owlet
git add Owlet/project.yml Owlet/Owlet/Info.plist
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "build(owlet): add InputMonitoring usage, drop owlet:// URL scheme, bump to 0.2.0"
```

---

### Task 10: `install.sh` — strip Hammerspoon, add xattr, open both permission panes

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: Remove Hammerspoon brew install section**

Delete the entire `# ---------- Hammerspoon ----------` block (about 12 lines) from `install.sh`. It currently lives between `# ---------- Shell env: OLLAMA_KEEP_ALIVE ----------` and `# ---------- Owlet.app ...`.

- [ ] **Step 2: Replace the init.lua refresh logic with a strip**

Find the `# ---------- ~/.hammerspoon/init.lua ----------` section (around line 130-200). Replace the entire block with:

```bash
# ---------- ~/.hammerspoon/init.lua cleanup ----------
# v0.2 strips the prompt-rewriter:hotkey block (if present) so old
# installs that had Hammerspoon as the hotkey owner stop firing duplicate
# events. The owlet-diag:hotkey block (debug aid) is also stripped.
# Other Lua content in init.lua is preserved.
if [ -f "$HS_INIT" ]; then
  for marker in "prompt-rewriter:hotkey" "owlet-diag:hotkey"; do
    if grep -Fq "$marker" "$HS_INIT"; then
      echo "==> Stripping $marker block from ~/.hammerspoon/init.lua"
      awk -v marker="$marker" '
        $0 ~ "===== " marker " BEGIN" { skip=1; next }
        $0 ~ "===== " marker " END"   { skip=0; next }
        !skip { print }
      ' "$HS_INIT" > "$HS_INIT.tmp" && mv "$HS_INIT.tmp" "$HS_INIT"
    fi
  done
fi
```

Remove the `# ---------- Launch / reload Hammerspoon ----------` block entirely (osascript reload no longer needed).

- [ ] **Step 3: Add the `xattr` quarantine strip**

Find the line `cp -R "$BUILT_APP" "$OWLET_INSTALL_DIR/"` (around line 117). Immediately after it add:

```bash
# Strip Gatekeeper quarantine so the user doesn't see "developer cannot
# be verified" on first launch. Ad-hoc self-sign means we can't notarize.
xattr -dr com.apple.quarantine "$OWLET_INSTALL_DIR/$OWLET_APP_NAME" 2>/dev/null || true
```

- [ ] **Step 4: Open both permission panes on fresh install**

Find the `if [ "$OWLET_FRESH_INSTALL" = "1" ]; then` block. Replace it with:

```bash
if [ "$OWLET_FRESH_INSTALL" = "1" ]; then
  echo "==> Opening System Settings -> Privacy & Security -> Accessibility for Owlet"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" \
    >/dev/null 2>&1 || true
  sleep 1  # Give the first pane time to open before triggering the second.
  echo "==> Opening System Settings -> Privacy & Security -> Input Monitoring for Owlet"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" \
    >/dev/null 2>&1 || true
fi
```

- [ ] **Step 5: Update the trailing message**

Find the `cat <<'EOF' ... NOTE: First install...` block at the end. Replace with:

```bash
if [ "$OWLET_FRESH_INSTALL" = "1" ]; then
  cat <<'EOF'

NOTE: v0.2 first install — Owlet needs TWO macOS permissions:

  • Accessibility    — to read your selection and replace it with the rewrite
  • Input Monitoring — to detect your fn+Ctrl+R hotkey

Both panes are now open. Toggle Owlet ON in EACH, then relaunch
Owlet from /Applications. After that, fn+Ctrl+R works in every app.

Owlet will auto-launch on login from now on.
EOF
fi
```

- [ ] **Step 6: Test idempotency by running install.sh once**

```bash
cd ~/repos/owlet
bash install.sh 2>&1 | tail -20
```

Expected: completes without errors. Old hotkey blocks (if any) stripped from init.lua. Owlet built, signed, copied, xattr stripped. Both permission panes opened.

- [ ] **Step 7: Commit**

```bash
cd ~/repos/owlet
git add install.sh
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "feat(installer): drop Hammerspoon, add xattr strip, open both perm panes

Removes the Hammerspoon brew install + the prompt-rewriter:hotkey
block refresh + the osascript reload. Adds an awk-strip of both
'prompt-rewriter:hotkey' and 'owlet-diag:hotkey' blocks from init.lua
on upgrade (preserves other Lua). Adds xattr -dr com.apple.quarantine
after cp to avoid Gatekeeper prompt. Opens BOTH Accessibility and
Input Monitoring panes on fresh install. Trailing message updated."
```

---

### Task 11: README rewrite (no Hammerspoon mentions)

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite README**

Replace `README.md` content with:

```markdown
# Owlet

Small, friendly local-LLM tools for macOS. v0.2 ships **Owlet Rewriter** — a Grammarly-style popup that rewrites the text you've selected into clearer English using Ollama (`qwen3:8b`). No cloud, no API keys, no browser extension.

**Workflow:** select text → press `fn+Ctrl+R` → review the inline diff → click Replace (in-place) or Copy.

## Prerequisites

- macOS 14+ (tested on macOS 26.5 Apple Silicon)
- [Ollama](https://ollama.com/download)
- [Homebrew](https://brew.sh) — used to install xcodegen
- Xcode (full IDE — Command Line Tools alone are not enough)

## Install

```bash
cd ~/repos/owlet
./install.sh
```

The installer:

1. Pulls `qwen3:8b` (~5.2 GB) via Ollama.
2. Creates a Python venv at `tools/rewriter/.venv/` and installs deps.
3. Adds `OLLAMA_KEEP_ALIVE=24h` to `~/.zshrc` if not already set.
4. Installs xcodegen if missing.
5. Builds `Owlet.app` (Release), self-signs ad-hoc, copies to `~/Applications/`.
6. Strips Gatekeeper quarantine (`xattr -dr com.apple.quarantine`).
7. Launches Owlet and opens System Settings for both required permissions.

**Manual step (once):** toggle **Owlet** ON in BOTH `Privacy & Security → Accessibility` AND `Privacy & Security → Input Monitoring`, then relaunch Owlet from `/Applications`. macOS doesn't allow scripts to grant TCC permissions.

## Usage

1. Select text in any app.
2. Press `fn+Ctrl+R`.
3. Review the inline diff (deleted words in red strikethrough, added words in green).
4. **Enter** to Replace · **Cmd+C** to Copy · **Esc** to Cancel.

In Electron apps (Slack, Discord, VS Code, Notion, Claude desktop) and Chromium browsers, Owlet's AX read returns nothing — the fallback path uses synthetic `Cmd+C`, which works in every app that responds to Cmd+C. Replace in these apps puts the rewrite on the clipboard for manual `Cmd+V`.

## Auto-launch at login

On first successful launch (after permissions are granted) Owlet registers itself as a Login Item via `SMAppService`. You can disable this in `System Settings → General → Login Items`. If you disable it, Owlet's hotkey works only when you launch the app manually.

## Customisation

- **Change the model:** edit `MODEL = "qwen3:8b"` in `tools/rewriter/rewrite_prompt.py`.
- **Change the prompt:** edit `SYSTEM_PROMPT` in the same file.
- **Change the hotkey:** v0.2 hardcodes `fn+Ctrl+R`. Configurable hotkey is a v0.3 follow-up.

## Project layout

```
~/repos/owlet/
├── tools/rewriter/      # Python CLI (Ollama backend)
├── Owlet/               # SwiftUI app (Xcode project, generated by xcodegen)
├── docs/superpowers/    # specs + plans
├── install.sh           # one-shot installer / refresh script
└── README.md
```

## Manual smoke test checklist

After install:

- [ ] **TextEdit** — type a draft, select, `fn+Ctrl+R`. Popup with inline diff → Enter → text replaced in place.
- [ ] **Claude desktop** (Electron) — same flow → popup → Replace puts rewrite on clipboard for `Cmd+V`.
- [ ] **Chrome / Safari article body** — same as Claude.
- [ ] **Slack / Discord / Notion / VS Code** — same.
- [ ] **Terminal / iTerm / Ghostty** — same.
- [ ] **Empty selection** — popup shows "Select some text first".
- [ ] **Password field** — popup shows "Owlet won't read from password fields".
- [ ] **Spam fn+Ctrl+R rapidly** — only one popup, in-flight cancelled.
- [ ] **Kill Owlet** via Activity Monitor → press hotkey → nothing (expected).
- [ ] **Reboot** → Owlet auto-launches → hotkey works.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Hotkey doesn't fire | Check Owlet is running (Activity Monitor). Verify Accessibility AND Input Monitoring are both ON in System Settings. |
| Permission revoked surprise alert | A required permission was disabled in System Settings. Re-toggle and relaunch Owlet. |
| Owlet quit on first launch | Permission modal expected Quit — you need to grant permissions in System Settings then relaunch from `/Applications`. |
| First rewrite takes ~5 s | Model cold-start. `OLLAMA_KEEP_ALIVE=24h` keeps it warm. |
| "Looks like Ollama isn't running" | `ollama serve` in another terminal. |
| Replace does nothing in some apps | Apps without AX text-write support fall back to clipboard. Press `Cmd+V` to paste manually. |

## Upgrading from v0.1

v0.2 removes the Hammerspoon dependency. Re-running `install.sh` will:
- Strip the `prompt-rewriter:hotkey` block from `~/.hammerspoon/init.lua` (other Lua content is preserved).
- Build and install the new self-contained `Owlet.app`.

The new Owlet.app's ad-hoc signature is different from v0.1's, so macOS invalidates the existing Accessibility grant. You'll need to re-grant Accessibility AND grant Input Monitoring (new in v0.2) before fn+Ctrl+R works again.

Hammerspoon itself is left installed if you had it. It's no longer required.

## Why "Owlet"?

A friendly small owl — inspired by the Pokémon Rowlet. The "-let" suffix reads as "small thing", matching the toolkit's spirit.
```

- [ ] **Step 2: Commit**

```bash
cd ~/repos/owlet
git add README.md
git -c user.email="dev@greenpassport.co" -c user.name="rowlet" commit -m "docs: rewrite README for v0.2 (no Hammerspoon)

Adds Input Monitoring step, login-item explanation, upgrade-from-v0.1
section, and updates troubleshooting for the new permission flow."
```

---

## Phase 7 — Validation

### Task 12: Full test suite + manual smoke

**Files:** none

- [ ] **Step 1: Run the full Swift test suite**

```bash
cd ~/repos/owlet/Owlet
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' test 2>&1 \
  | grep -E "Test Suite.*passed|Test Suite.*failed|TEST SUCCEEDED|TEST FAILED" | tail -15
```

Expected: All test suites pass (CleanOutputTests, DiffEngineTests, OllamaClientTests, PopupStateTests, RewriterFlowTests, ThemeSnapshotTests (if present), ChordMatcherTests, PermissionCheckerTests, LoginItemManagerTests). Roughly 40+ tests.

- [ ] **Step 2: Run install.sh end-to-end**

```bash
cd ~/repos/owlet
bash install.sh 2>&1 | tail -25
```

Expected:
- No Hammerspoon brew install
- xcodebuild + codesign succeed
- `~/Applications/Owlet.app` exists
- Both permission panes opened in System Settings
- Owlet launched and (since not yet re-granted) showed PermissionModal then quit

- [ ] **Step 3: Re-grant permissions**

Manually:
1. System Settings → Privacy & Security → Accessibility — find Owlet (add if missing via + → `~/Applications` → `Owlet.app`), toggle ON.
2. System Settings → Privacy & Security → Input Monitoring — same.
3. Launch Owlet.app from `~/Applications` (double-click).

Verify Owlet is now running:
```bash
pgrep -x Owlet >/dev/null && echo "running" || echo "not running"
```

- [ ] **Step 4: Manual smoke test checklist** (from README)

Walk the README's checklist. Document any failure. Common ones:
- TextEdit happy path → must work
- Claude desktop / Electron → popup appears, rewrite produced, Replace fallback to clipboard
- Empty selection → "Select some text first"
- Spam hotkey → one popup

- [ ] **Step 5: Reboot test** (optional but recommended)

Reboot the Mac. Verify Owlet auto-launches (login item). Verify hotkey still works.

- [ ] **Step 6: No commit needed for smoke pass.** If any test failed, file a follow-up commit fixing the specific issue and re-run.

---

### Task 13: Tag v0.2.0

**Files:** none (git tag only)

- [ ] **Step 1: Verify clean working tree**

```bash
cd ~/repos/owlet
git status
```

Expected: `nothing to commit, working tree clean`.

- [ ] **Step 2: Tag and push**

```bash
cd ~/repos/owlet
git tag -a v0.2.0 -m "Owlet v0.2.0 — Hammerspoon removed

Owlet is now fully self-contained:
- CGEventTap for global fn+Ctrl+R hotkey (Input Monitoring required)
- Swift port of Cmd+C capture (works in Electron, Chrome, Terminal)
- Combined permission modal on first launch
- SMAppService login item registration
- install.sh no longer installs or wires Hammerspoon
- Old prompt-rewriter:hotkey block stripped from init.lua on upgrade"

git push origin main
git push origin v0.2.0
```

---

## Self-review notes (already applied in this plan)

- **Spec coverage:** Every spec section maps to tasks. Architecture (Section 2 of spec) → Tasks 5, 6, 8. Components (Section 3) → Tasks 2, 3, 4, 5, 7, 8. First-launch flow (Section 4) → Task 8. install.sh changes (Section 5) → Task 10. Edge cases (Section 6) — event-tap async dispatch (Task 5), self-heal both disable causes (Task 5), modifier-release port (Task 6), xattr (Task 10), permission revocation polling (Task 8). Out-of-scope items (Section 10) honored: no settings UI, no menu bar status icon, no notarization, no stable cert.
- **Type consistency:** `ChordMatcher.isOwletRewrite(key:flags:)` defined in Task 2, used in Task 5 (`HotkeyEventTap.handle`). `ModifierFlags` defined in Task 2, used in Task 5. `PermissionStatus` / `Permission` defined in Task 3, used in Tasks 7 and 8. `HotkeyEventTap.StartError` defined in Task 5, used in Task 8.
- **Placeholder scan:** No TBD/TODO in step bodies. All Swift code is complete. All bash commands are exact. The "@unknown default: return true" in `LoginItemManager.shouldRegister` is intentional optimism for future SMAppService.Status cases, not a placeholder.
- **Known carry-forward** (intentional, documented in spec section 10–11): stable signing identity for TCC stability is v0.3 work, menu bar status icon is v0.3, configurable hotkey is v0.3.

---

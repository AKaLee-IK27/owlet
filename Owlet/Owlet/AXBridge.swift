import ApplicationServices
import AppKit

struct SelectionSnapshot: Equatable {
    enum CaptureMethod { case ax, clipboardFallback }
    let text: String
    let sourceAppBundleID: String
    let focusedElement: AXUIElement?  // nil for non-AX-cooperative apps (Electron, Chrome, etc.)
    let captureMethod: CaptureMethod

    static func == (lhs: SelectionSnapshot, rhs: SelectionSnapshot) -> Bool {
        // AXUIElement isn't Equatable; compare by other fields. Used only in tests.
        lhs.text == rhs.text
            && lhs.sourceAppBundleID == rhs.sourceAppBundleID
            && lhs.captureMethod == rhs.captureMethod
    }
}

struct FocusSnapshot {
    let appBundleID: String
    let focusedElement: AXUIElement
}

enum CaptureOutcome {
    case captured(SelectionSnapshot)
    case noFocus
    case passwordField
    case empty
}

enum AXBridge {

    // MARK: Trust check
    // Note: avoid kAXTrustedCheckOptionPrompt (C global, not concurrency-safe in Swift 6).
    // Use the stable string literal directly instead.
    static func isTrusted(promptIfNeeded: Bool = false) -> Bool {
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": promptIfNeeded] as CFDictionary)
    }

    // MARK: Capture
    static func capture() -> CaptureOutcome {
        let focus = currentFocus()  // may be nil for Electron/Chrome/Terminal; don't bail yet

        // Password field guard (only if we have focus)
        if let focus = focus, isPasswordField(focus.focusedElement) {
            return .passwordField
        }

        // Fast path: AX read (cooperative apps: TextEdit, Pages, Notes, etc.)
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

    // MARK: Replace
    enum ReplaceResult { case okAX, okPaste, failed(String) }

    static func replaceSelection(_ text: String, in element: AXUIElement) -> ReplaceResult {
        // Re-validate focus to avoid pasting into the wrong field.
        guard let current = currentFocus(), AXUIElementsEqual(current.focusedElement, element) else {
            return .failed("focus changed")
        }
        // 1) Try AX write.
        let cf: CFTypeRef = text as CFTypeRef
        let setErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, cf)
        if setErr == .success { return .okAX }

        // 2) Clipboard + synthetic Cmd+V, with save/restore.
        let pb = NSPasteboard.general
        let originalContents = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let pasted = postCmdV()
        // Restore old clipboard after a brief delay so the paste lands first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let original = originalContents {
                pb.clearContents()
                pb.setString(original, forType: .string)
            }
        }
        return pasted ? .okPaste : .failed("AX write + Cmd+V both failed")
    }

    // MARK: Focus helpers
    static func currentFocus() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        // Defensive: misbehaved apps can return non-AXUIElement CFTypeRefs.
        let typeID = CFGetTypeID(element)
        guard typeID == AXUIElementGetTypeID() else { return nil }
        return FocusSnapshot(appBundleID: bundleID, focusedElement: element as! AXUIElement)
    }

    // MARK: Private
    private static func readSelectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    private static func isPasswordField(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let r = role as? String, r == "AXSecureTextField" { return true }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if let sr = subrole as? String, sr == "AXSecureTextField" { return true }
        return false
    }

    private static func postCmdV() -> Bool { postKey(keyCode: 9 /* V */) }

    private static func postKey(keyCode: CGKeyCode) -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func AXUIElementsEqual(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        CFEqual(a, b)
    }
}

/// Protocol exposed for testing. Production uses AXBridge's static functions
/// behind a small adapter.
protocol AXBridging {
    func capture() -> CaptureOutcome
    func replaceSelection(_ text: String, in element: AXUIElement) -> AXBridge.ReplaceResult
}

struct AXBridgeAdapter: AXBridging {
    func capture() -> CaptureOutcome { AXBridge.capture() }
    func replaceSelection(_ text: String, in element: AXUIElement) -> AXBridge.ReplaceResult {
        AXBridge.replaceSelection(text, in: element)
    }
}

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

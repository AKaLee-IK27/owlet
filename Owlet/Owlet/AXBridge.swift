import ApplicationServices
import AppKit
import os.log

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

        // Fallback: check if clipboard has fresh external content (e.g., Ghostty
        // auto-copy, user Cmd+C). If so, use it directly without Cmd+C.
        if ClipboardGuard.shared.hasExternalClipboardChange(),
           let text = NSPasteboard.general.string(forType: .string),
           !text.isEmpty {
            return .captured(SelectionSnapshot(
                text: text,
                sourceAppBundleID: focus?.appBundleID ?? "",
                focusedElement: focus?.focusedElement,
                captureMethod: .clipboardFallback
            ))
        }

        // Clipboard is stale or empty — synthesize Cmd+C to capture the selection.
        ClipboardGuard.shared.snapshotBeforeOverwrite()
        if let text = swiftCmdCCapture() {
            // 5 s gives the popup plenty of time to consume the clipboard
            // before we restore the original underneath it.
            ClipboardGuard.shared.scheduleRestore(after: 5.0)
            ClipboardGuard.shared.recordOwletChangeCount(NSPasteboard.general.changeCount)
            return .captured(SelectionSnapshot(
                text: text,
                sourceAppBundleID: focus?.appBundleID ?? "",
                focusedElement: focus?.focusedElement,
                captureMethod: .clipboardFallback
            ))
        }
        // Capture failed but Cmd+C may have written something we can't decode
        // as text — image, file, custom UTI — *or* it may not have written at
        // all. We can't tell from this far up. Always scheduleRestore on the
        // failure path: if the clipboard was overwritten, we restore the user's
        // original over the junk; if it wasn't, the restore writes the cached
        // original back to itself (benign no-op, just a spurious changeCount
        // bump). Either way the user's true original is preserved.
        ClipboardGuard.shared.scheduleRestore(after: 0.5)
        ClipboardGuard.shared.recordOwletChangeCount(NSPasteboard.general.changeCount)

        return focus == nil ? .noFocus : .empty
    }

    // MARK: Replace
    enum ReplaceResult { case okAX, okPaste, failed(String) }

    static func replaceSelection(_ text: String, in element: AXUIElement) -> ReplaceResult {
        // Re-validate focus to avoid pasting into the wrong field.
        guard let current = currentFocus(), AXUIElementsEqual(current.focusedElement, element) else {
            return .failed("focus changed")
        }
        // Where the selection begins now, so we can place the caret AFTER the inserted
        // text. Setting kAXSelectedTextAttribute alone leaves the post-insert caret
        // app-dependent — some fields drop it at the START of the inserted word — so we
        // set it explicitly below.
        let insertLocation = selectedRangeLocation(in: element)

        // 1) Try AX write.
        let cf: CFTypeRef = text as CFTypeRef
        let setErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, cf)
        if setErr == .success {
            if let location = insertLocation {
                setCaret(at: location + text.utf16.count, in: element)
            }
            return .okAX
        }

        // 2) Clipboard + synthetic Cmd+V, with save/restore via ClipboardGuard.
        // The guard returns the same original across capture + replace cycles
        // so the user's pre-Owlet clipboard survives even though we overwrite
        // twice (once for capture, once for paste).
        ClipboardGuard.shared.snapshotBeforeOverwrite()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let pasted = postCmdV()
        if pasted {
            // 0.5 s lets the synthetic Cmd+V land in the target app before
            // we swap the clipboard back to the user's original.
            ClipboardGuard.shared.scheduleRestore(after: 0.5)
        } else {
            // Paste failed — leave clipboard as it is (with rewrite text on it
            // so the user can manually Cmd+V) and clear the pending restore so
            // we don't later wipe whatever they end up with.
            ClipboardGuard.shared.cancelPendingRestore()
        }
        return pasted ? .okPaste : .failed("AX write + Cmd+V both failed")
    }

    /// UTF-16 location of the current selection/caret, or nil if unavailable.
    private static func selectedRangeLocation(in element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// Place the caret (a zero-length selection) at a UTF-16 `location`.
    private static func setCaret(at location: Int, in element: AXUIElement) {
        var range = CFRange(location: location, length: 0)
        guard let axValue = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue)
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

    static func isPasswordField(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let r = role as? String, r == "AXSecureTextField" { return true }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if let sr = subrole as? String, sr == "AXSecureTextField" { return true }
        return false
    }

    static func readCaretContext(from element: AXUIElement) -> CaretContext? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        let axRange = rangeValue as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &selectedRange) else { return nil }

        let utf16 = value.utf16
        let clampedLocation = max(0, min(selectedRange.location, utf16.count))
        let end = String.Index(utf16Offset: clampedLocation, in: value)
        let prefix = String(value[..<end])

        let caretRect = caretCocoaRect(in: element, caretLocation: clampedLocation)
        return CaretContext(textBeforeCaret: prefix, caretScreenRect: caretRect)
    }

    /// Caret rect in **Cocoa screen coordinates** (bottom-left origin), or nil.
    ///
    /// `kAXBoundsForRange` returns Quartz screen space (top-left origin); the
    /// overlay needs Cocoa space, so we flip here at the boundary. We try, in order:
    ///   1. a zero-length range at the caret,
    ///   2. the bounds of the character *before* the caret (trailing edge ≈ caret),
    ///   3. the `AXTextMarker` caret bounds — Chromium/WebKit editors (e.g. Apple
    ///      Notes) ignore `kAXBoundsForRange` for `NSRange` and return a degenerate
    ///      rect, but resolve the caret correctly through their opaque marker API.
    /// Each candidate is validated against the focused element's `AXFrame` so a
    /// response in the wrong coordinate space can't drag the overlay off-screen. If
    /// none validate we still return the first geometrically usable rect, preserving
    /// behavior for fields that expose no `AXFrame` anchor.
    /// Diagnostic logger for the deferred "ghost one line too high" investigation
    /// (feat-013, hardening review). The flip/anchor formulas are NOT the bug (refuted
    /// against code + git history), so this only OBSERVES — it logs the raw AX rect, the
    /// flipped Cocoa rect, the chosen candidate, and the anchor, to be compared on both
    /// the built-in and external display at several vertical positions. Capture with:
    ///   log show --predicate 'subsystem=="co.greenpassport.owlet" AND category=="caretgeom"' --info --last 5m
    private static let caretLog = Logger(subsystem: "co.greenpassport.owlet", category: "caretgeom")

    private static func caretCocoaRect(in element: AXUIElement, caretLocation: Int) -> NSRect? {
        let anchor = elementCocoaFrame(element)
        var firstUsable: NSRect?

        // Accept a candidate caret rect only when it resolves near the focused
        // field; remember the first computed rect as a last-resort fallback.
        func validate(_ rect: NSRect) -> NSRect? {
            if firstUsable == nil { firstUsable = rect }
            return rectIsNearAnchor(rect, anchor: anchor) ? rect : nil
        }
        func finish(_ rect: NSRect?, chose: String) -> NSRect? {
            caretLog.info("""
                chose=\(chose, privacy: .public) loc=\(caretLocation, privacy: .public) \
                primaryMaxY=\(primaryScreenMaxY(), privacy: .public) \
                cocoa=\(rect.map { NSStringFromRect($0) } ?? "nil", privacy: .public) \
                anchor=\(anchor.map { NSStringFromRect($0) } ?? "nil", privacy: .public)
                """)
            return rect
        }

        let zeroRaw = axBounds(in: element, location: caretLocation, length: 0)
        caretLog.info("rawZero(quartz)=\(zeroRaw.map { NSStringFromRect($0) } ?? "nil", privacy: .public)")
        if let zero = zeroRaw, zero.height > 0, let r = validate(cocoaRect(fromAXRect: zero)) {
            return finish(r, chose: "zero")
        }
        if caretLocation > 0,
           let char = axBounds(in: element, location: caretLocation - 1, length: 1), char.height > 0 {
            // Trailing edge of the previous character ≈ caret position.
            let trailing = CGRect(x: char.maxX, y: char.origin.y, width: 0, height: char.height)
            if let r = validate(cocoaRect(fromAXRect: trailing)) { return finish(r, chose: "trailing") }
        }
        if let marker = axTextMarkerCaretRect(in: element), marker.height > 0,
           let r = validate(cocoaRect(fromAXRect: marker)) {
            return finish(r, chose: "marker")
        }

        // No candidate validated against the field anchor; fall back to the first
        // rect we computed (nil when the field exposed no usable bounds at all).
        return finish(firstUsable, chose: firstUsable == nil ? "none" : "fallback")
    }

    /// The focused element's `AXFrame` in Cocoa screen coordinates — the field
    /// anchor used to validate caret rects. Nil when the element exposes no frame.
    private static func elementCocoaFrame(_ element: AXUIElement) -> NSRect? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), !rect.isEmpty else { return nil }
        return cocoaRect(fromAXRect: rect)
    }

    /// True when `rect`'s midpoint lies within the field `anchor` expanded by an 80pt
    /// halo, or when no anchor is available (cannot validate). Rejects caret rects that
    /// resolve far from the focused field — e.g. a response in the wrong coordinate
    /// space. The 80pt halo absorbs padding, scrolling, and multi-line offsets.
    /// Exposed (non-private) so the accept/reject boundary can be unit-tested.
    static func rectIsNearAnchor(_ rect: NSRect, anchor: NSRect?) -> Bool {
        guard let anchor, !anchor.isEmpty else { return true }
        let expanded = anchor.insetBy(dx: -80, dy: -80)
        return expanded.contains(NSPoint(x: rect.midX, y: rect.midY))
    }

    /// Caret bounds for Chromium/WebKit editors (e.g. Apple Notes) that return a
    /// degenerate rect from `kAXBoundsForRange`: they expose the selection only
    /// through the opaque `AXTextMarker` API. Read `AXSelectedTextMarkerRange`, then
    /// ask for `AXBoundsForTextMarkerRange`. The marker objects are opaque — never
    /// inspected, only passed back to AX. Returns raw Quartz coordinates (caller
    /// flips), or nil when the app doesn't implement the marker attributes.
    private static func axTextMarkerCaretRect(in element: AXUIElement) -> CGRect? {
        var markerRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, "AXSelectedTextMarkerRange" as CFString, &markerRangeRef) == .success,
              let markerRange = markerRangeRef else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsRef) == .success,
              let bounds = boundsRef, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Query `kAXBoundsForRange` for a UTF-16 range, in raw Quartz coordinates.
    private static func axBounds(in element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var cfRange = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &boundsRef
        ) == .success,
           let boundsValue = boundsRef,
           CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Flip a Quartz/AX screen rect (top-left origin, y grows down) into a Cocoa
    /// screen rect (bottom-left origin, y grows up). Reads the live screen layout.
    static func cocoaRect(fromAXRect rect: CGRect) -> NSRect {
        return cocoaRect(fromAXRect: rect, primaryScreenMaxY: primaryScreenMaxY())
    }

    /// Cocoa `maxY` of the primary display — the screen whose Cocoa frame origin
    /// is `.zero`, which is the screen carrying the menu bar and the anchor for
    /// CoreGraphics global coordinates. This is the correct flip reference: a
    /// monitor mounted *above* the primary makes the all-screens union taller, but
    /// CG's origin stays pinned to the primary's top-left, so flipping against the
    /// union shifts every rect up by that monitor's height and lands overlays on
    /// the wrong screen. Falls back to the first screen, then a safe identity.
    private static func primaryScreenMaxY() -> CGFloat {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        return primary?.frame.maxY ?? 0
    }

    /// Pure flip against the primary display's Cocoa `maxY`. Exposed for unit
    /// testing; see `primaryScreenMaxY()` for why the primary (not the screen
    /// union) is the correct anchor.
    static func cocoaRect(fromAXRect rect: CGRect, primaryScreenMaxY: CGFloat) -> NSRect {
        NSRect(x: rect.origin.x,
               y: primaryScreenMaxY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    static func insertAtCaret(_ text: String, in element: AXUIElement) -> ReplaceResult {
        replaceSelection(text, in: element)
    }

    /// Select a UTF-16 `range` in `element` then replace it — used to apply a Tier 1
    /// recorrection to a word that is not at the caret. Reuses `replaceSelection`'s
    /// AX-write-then-clipboard-paste fallback once the range is selected.
    static func replaceRange(_ range: NSRange, with text: String, in element: AXUIElement) -> ReplaceResult {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else {
            return .failed("could not build CFRange")
        }
        let selErr = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        guard selErr == .success else {
            return .failed("could not select range (AXError \(selErr.rawValue))")
        }
        return replaceSelection(text, in: element)
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
    /// Reads live hardware modifier state (not NSEvent's queue) so the
    /// wait-for-fn+ctrl-release actually waits. Then posts Cmd+C with
    /// explicit cmd-only flags from a privateState source so the synthetic
    /// event isn't merged with held hardware modifiers.
    /// Returns nil if no new text appeared on the clipboard.
    /// Original-clipboard restore is the caller's responsibility (via
    /// ClipboardGuard) — this function only handles the capture itself.
    static func swiftCmdCCapture() -> String? {
        let log = OSLog(subsystem: "co.greenpassport.owlet", category: "capture")
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let beforeCount = pb.changeCount
        os_log("capture: enter, beforeCount=%d, savedLen=%d", log: log, type: .info,
               beforeCount, saved?.count ?? -1)

        // Live hardware modifier state — independent of NSEvent's queue.
        let fnMask: CGEventFlags = .maskSecondaryFn
        let ctrlMask: CGEventFlags = .maskControl
        let releaseDeadline = Date().addingTimeInterval(0.5)
        var loops = 0
        while Date() < releaseDeadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let fnHeld = flags.contains(fnMask)
            let ctrlHeld = flags.contains(ctrlMask)
            if !fnHeld && !ctrlHeld { break }
            loops += 1
            usleep(10_000)
        }
        os_log("capture: post-release-wait, loops=%d", log: log, type: .info, loops)

        // Small settle delay so the kernel's "modifier released" state propagates
        // to the focused app's event dispatcher before our synthetic Cmd+C arrives.
        usleep(50_000)

        // Try synthetic Cmd+C via .hidSystemState first (Hammerspoon uses this).
        // Some Electron apps filter out non-hidSystemState events.
        if postCmdCViaHID() {
            // Poll for clipboard change (up to 1 s).
            let deadline = Date().addingTimeInterval(1.0)
            while pb.changeCount == beforeCount && Date() < deadline {
                usleep(20_000)
            }
            if pb.changeCount != beforeCount {
                os_log("capture: HID Cmd+C succeeded", log: log, type: .info)
                return readResult(beforeCount: beforeCount, saved: saved, log: log)
            }
            os_log("capture: HID Cmd+C produced no clipboard change, falling back to AXMenuItem", log: log, type: .info)
        }

        // Fallback: find the source app's Edit > Copy menu item via AX and press it.
        // Works in apps that reject synthetic keyboard events (Chromium / hardened Electron).
        if pressCopyMenuItem() {
            os_log("capture: AXMenuItem Copy pressed", log: log, type: .info)
            let deadline2 = Date().addingTimeInterval(1.0)
            while pb.changeCount == beforeCount && Date() < deadline2 {
                usleep(20_000)
            }
            return readResult(beforeCount: beforeCount, saved: saved, log: log)
        }

        os_log("capture: both Cmd+C and AXMenu Copy failed", log: log, type: .error)
        return nil
    }

    private static func postCmdCViaHID() -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Walks the source app's AX menu tree to find "Edit > Copy" and AXPresses it.
    /// This bypasses synthetic-keyboard-event filtering used by some Electron apps.
    private static func pressCopyMenuItem() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return false }
        let menuBarEl = menuBar as! AXUIElement

        // Iterate menubar items (File, Edit, View, ...). Find "Edit".
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBarEl, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }

        for menuTitle in children {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(menuTitle, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String, title == "Edit" else { continue }

            // The Edit menu's child is the actual menu (AXMenu) containing items.
            var editChildrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(menuTitle, kAXChildrenAttribute as CFString, &editChildrenRef) == .success,
                  let editChildren = editChildrenRef as? [AXUIElement],
                  let editMenu = editChildren.first else { return false }

            var menuItemsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(editMenu, kAXChildrenAttribute as CFString, &menuItemsRef) == .success,
                  let menuItems = menuItemsRef as? [AXUIElement] else { return false }

            for item in menuItems {
                var itemTitleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitleRef)
                if let itemTitle = itemTitleRef as? String, itemTitle == "Copy" {
                    let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    return err == .success
                }
            }
        }
        return false
    }

    private static func readResult(beforeCount: Int, saved: String?, log: OSLog) -> String? {
        let pb = NSPasteboard.general
        let afterCount = pb.changeCount
        let captured = pb.string(forType: .string)
        os_log("capture: afterCount=%d, capturedLen=%d", log: log, type: .info,
               afterCount, captured?.count ?? -1)
        if afterCount == beforeCount {
            os_log("capture: NO clipboard change", log: log, type: .error)
            return nil
        }
        guard let text = captured, !text.isEmpty else {
            os_log("capture: empty captured text", log: log, type: .error)
            return nil
        }
        if text == saved {
            os_log("capture: captured matches saved (no new selection)", log: log, type: .error)
            return nil
        }
        return text
    }
}

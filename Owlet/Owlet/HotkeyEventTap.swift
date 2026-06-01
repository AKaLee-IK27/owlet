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
    private let onDoubleClick: (@Sendable () -> Void)?
    private let onAutocompleteTextChanged: (@Sendable () -> Void)?
    private let onAutocompleteAccept: (@Sendable () -> Void)?
    private let onAutocompleteDismiss: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var lastShiftKeyDownTime: Date?
    /// Last-seen modifier state, used to detect absent→present / present→absent
    /// transitions on `flagsChanged` events (bare modifier keys never emit keyDown).
    private var previousFlags = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: false, shift: false)
    private var autocompleteSuggestionVisible = false
    private let doubleClickThreshold: TimeInterval = 0.4
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "hotkey")

    /// Action decided from a modifier-key transition. Kept separate from the
    /// CGEvent layer so the transition logic is unit-testable.
    enum ModifierAction: Equatable {
        case none
        case doubleClickShift
        case startOptionHold
        case cancelOptionHold
    }

    enum KeyDownAction: Equatable {
        case passThrough
        case passThroughAndNotifyTextChanged
        case passThroughDismissAndNotifyTextChanged
        case fireHotkey
        case acceptAutocomplete
        case dismissAutocomplete
    }

    /// - Parameters:
    ///   - chord: The chord this tap watches for. Read once at construction.
    ///   - onHotkey: Dispatched to a background queue when the chord fires.
    ///   - optionHoldDetector: Optional detector for Option hold-to-reveal.
    ///   - onDoubleClick: Optional handler for double-click Shift (screenshot flow).
    init(chord: Chord,
         onHotkey: @escaping @Sendable () -> Void,
         optionHoldDetector: OptionHoldDetector? = nil,
         onDoubleClick: (@Sendable () -> Void)? = nil,
         onAutocompleteTextChanged: (@Sendable () -> Void)? = nil,
         onAutocompleteAccept: (@Sendable () -> Void)? = nil,
         onAutocompleteDismiss: (@Sendable () -> Void)? = nil) {
        self.chord = chord
        self.onHotkey = onHotkey
        self.optionHoldDetector = optionHoldDetector
        self.onDoubleClick = onDoubleClick
        self.onAutocompleteTextChanged = onAutocompleteTextChanged
        self.onAutocompleteAccept = onAutocompleteAccept
        self.onAutocompleteDismiss = onAutocompleteDismiss
    }

    @discardableResult
    func start() -> Result<Void, StartError> {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
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
        lock.lock()
        lastShiftKeyDownTime = nil
        previousFlags = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: false, shift: false)
        autocompleteSuggestionVisible = false
        lock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Self.logger.info("Event tap re-enabled after \(String(describing: type), privacy: .public)")
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = ModifierFlags(
            fn: event.flags.contains(.maskSecondaryFn),
            ctrl: event.flags.contains(.maskControl),
            cmd: event.flags.contains(.maskCommand),
            alt: event.flags.contains(.maskAlternate),
            shift: event.flags.contains(.maskShift)
        )

        // Bare modifier keys (Shift, Option) emit flagsChanged, never keyDown/keyUp.
        // Double-click-Shift and Option-hold detection both live here.
        if type == .flagsChanged {
            switch decideModifierAction(flags: flags, now: Date()) {
            case .doubleClickShift:
                optionHoldDetector?.cancel()
                if let handler = onDoubleClick {
                    DispatchQueue.global(qos: .userInitiated).async { handler() }
                }
            case .startOptionHold:
                optionHoldDetector?.handleKeyDown(flags: flags)
            case .cancelOptionHold:
                optionHoldDetector?.cancel()
            case .none:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let keyName = KeyCodeMap.name(for: Int(keyCode)) ?? ""

            switch decideKeyDownAction(keyCode: Int(keyCode), keyName: keyName, flags: flags) {
            case .acceptAutocomplete:
                optionHoldDetector?.cancel()
                setAutocompleteSuggestionVisible(false)
                if let handler = onAutocompleteAccept {
                    DispatchQueue.global(qos: .userInitiated).async { handler() }
                }
                return nil
            case .dismissAutocomplete:
                optionHoldDetector?.cancel()
                setAutocompleteSuggestionVisible(false)
                if let handler = onAutocompleteDismiss {
                    DispatchQueue.global(qos: .userInitiated).async { handler() }
                }
                return nil
            case .fireHotkey:
                optionHoldDetector?.cancel()
                setAutocompleteSuggestionVisible(false)
                if let dismiss = onAutocompleteDismiss {
                    DispatchQueue.global(qos: .utility).async { dismiss() }
                }
                lock.lock()
                lastShiftKeyDownTime = nil
                lock.unlock()
                DispatchQueue.global(qos: .userInitiated).async { [onHotkey] in
                    onHotkey()
                }
                return nil  // consume the event
            case .passThroughAndNotifyTextChanged:
                optionHoldDetector?.cancel()
                if let handler = onAutocompleteTextChanged {
                    DispatchQueue.global(qos: .utility).async { handler() }
                }
                return Unmanaged.passUnretained(event)
            case .passThroughDismissAndNotifyTextChanged:
                optionHoldDetector?.cancel()
                setAutocompleteSuggestionVisible(false)
                if let handler = onAutocompleteTextChanged {
                    DispatchQueue.global(qos: .utility).async { handler() }
                }
                return Unmanaged.passUnretained(event)
            case .passThrough:
                optionHoldDetector?.cancel()
                return Unmanaged.passUnretained(event)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    func setAutocompleteSuggestionVisible(_ visible: Bool) {
        lock.lock()
        autocompleteSuggestionVisible = visible
        lock.unlock()
    }

    func decideKeyDownAction(keyCode: Int, keyName: String, flags: ModifierFlags) -> KeyDownAction {
        let visible: Bool = lock.withLock { autocompleteSuggestionVisible }

        if visible {
            if keyCode == 48 { return .acceptAutocomplete } // Tab
            if keyCode == 53 { return .dismissAutocomplete } // Esc
        }

        if ChordMatcher.matches(chord: chord, key: keyName, flags: flags) {
            return .fireHotkey
        }

        if visible, Self.isPrintableOrEditingKey(keyCode: keyCode, flags: flags) {
            return .passThroughDismissAndNotifyTextChanged
        }

        if Self.isTextChangingKey(keyCode: keyCode, flags: flags) {
            return .passThroughAndNotifyTextChanged
        }
        return .passThrough
    }

    private static func isTextChangingKey(keyCode: Int, flags: ModifierFlags) -> Bool {
        // Command/control shortcuts usually do not mutate text at the caret; do
        // not start the autocomplete loop for Cmd+C, Ctrl+Tab, etc.
        guard !flags.cmd && !flags.ctrl && !flags.fn else { return false }
        return isPrintableOrEditingKey(keyCode: keyCode, flags: flags)
    }

    private static func isPrintableOrEditingKey(keyCode: Int, flags: ModifierFlags) -> Bool {
        if keyCode == 48 || keyCode == 53 { return false } // Tab / Esc handled separately
        if (0...50).contains(keyCode) { return true }      // letters, numbers, punctuation, Space, Return
        return keyCode == 51 || keyCode == 117            // Delete / Forward Delete
    }

    /// Decide what a modifier transition means, given the current flags and the
    /// previously-seen flags. Detects:
    ///   - double-tap of Shift-alone within `doubleClickThreshold`
    ///   - Option-alone pressed (start hold) / released (cancel hold)
    /// Pure with respect to CGEvent — exercised directly by unit tests.
    func decideModifierAction(flags: ModifierFlags, now: Date) -> ModifierAction {
        lock.lock()
        defer { lock.unlock() }
        let prev = previousFlags
        previousFlags = flags

        let shiftPressed = !prev.shift && flags.shift
        let shiftOnly = flags.shift && !flags.fn && !flags.ctrl && !flags.cmd && !flags.alt
        if shiftPressed && shiftOnly {
            if let last = lastShiftKeyDownTime, now.timeIntervalSince(last) < doubleClickThreshold {
                lastShiftKeyDownTime = nil
                return .doubleClickShift
            }
            lastShiftKeyDownTime = now
            return .none
        }

        let optionPressed = !prev.alt && flags.alt
        let optionReleased = prev.alt && !flags.alt
        let optionOnly = flags.alt && !flags.fn && !flags.ctrl && !flags.cmd && !flags.shift
        if optionPressed && optionOnly { return .startOptionHold }
        if optionReleased { return .cancelOptionHold }
        return .none
    }
}

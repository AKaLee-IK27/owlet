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
    private let chord: @Sendable (String, ModifierFlags) -> Bool
    private let onHotkey: @Sendable () -> Void
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "hotkey")

    /// - Parameters:
    ///   - chord: Pure predicate the tap consults on every keyDown to decide
    ///     whether to intercept. Pass `ChordMatcher.isOwletRewrite` or
    ///     `ChordMatcher.isOwletImprove` — multiple instances of the tap can
    ///     coexist, one per chord.
    ///   - onHotkey: Dispatched to a background queue when `chord` returns true.
    init(chord: @escaping @Sendable (String, ModifierFlags) -> Bool,
         onHotkey: @escaping @Sendable () -> Void) {
        self.chord = chord
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

        guard chord(keyName, flags) else {
            return Unmanaged.passUnretained(event)  // pass through
        }

        // Consume the event AND dispatch the work async so the tap doesn't block.
        DispatchQueue.global(qos: .userInitiated).async { [onHotkey] in
            onHotkey()
        }
        return nil
    }

    /// Maps CGKeyCode to a single-character string for chord matching.
    /// Currently only 'r' is needed. If the chord becomes user-configurable
    /// later this needs UCKeyTranslate for full layout support — these
    /// literals assume US/QWERTY-style layouts.
    private func keyCodeToString(_ keyCode: Int) -> String {
        switch keyCode {
        case 15: return "r"
        default: return ""
        }
    }
}

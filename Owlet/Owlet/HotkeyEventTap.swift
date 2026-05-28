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

        let flags = ModifierFlags(
            fn: event.flags.contains(.maskSecondaryFn),
            ctrl: event.flags.contains(.maskControl),
            cmd: event.flags.contains(.maskCommand),
            alt: event.flags.contains(.maskAlternate),
            shift: event.flags.contains(.maskShift)
        )

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let keyName = KeyCodeMap.name(for: Int(keyCode)) ?? ""

            // Chord match takes priority — cancel hold detector and fire rewrite.
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
            // Option keyUp → cancel hold detection.
            if flags.alt, let detector = optionHoldDetector {
                detector.handleOptionKeyUp()
            }
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }
}

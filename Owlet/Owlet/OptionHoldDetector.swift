import Foundation

/// Detects when the Option key is held in isolation for a configurable duration.
/// Pure state machine — no AppKit dependencies. Thread-safe for use from CGEventTap callback.
final class OptionHoldDetector: @unchecked Sendable {

    private let holdThreshold: TimeInterval
    private let onHoldTriggered: @Sendable () -> Void
    private let lock = NSLock()
    private var generation: UInt64 = 0

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
        lock.lock()
        generation &+= 1
        let gen = generation
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + holdThreshold) { [weak self] in
            self?.fireIfArmed(gen)
        }
        return true
    }

    /// Call on Option keyUp. Cancels any pending hold detection.
    /// Note: the flags still show alt=true during keyUp, so we don't check flags here.
    func handleOptionKeyUp() {
        cancel()
    }

    /// Cancel any pending hold detection.
    func cancel() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    private func fireIfArmed(_ gen: UInt64) {
        lock.lock()
        let current = generation
        lock.unlock()
        guard current == gen else { return }
        onHoldTriggered()
    }

    private func isOptionOnly(_ flags: ModifierFlags) -> Bool {
        flags.alt && !flags.fn && !flags.ctrl && !flags.cmd && !flags.shift
    }
}

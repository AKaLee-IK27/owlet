import Foundation

/// Debounces rapid trigger() calls so multiple URL events within the window
/// collapse to one invocation.
final class HotkeyCoordinator {
    private let debounceMs: Int
    private let onFire: () -> Void
    private var lastFire: Date = .distantPast
    private let lock = NSLock()

    init(debounceMs: Int = 200, onFire: @escaping () -> Void) {
        self.debounceMs = debounceMs
        self.onFire = onFire
    }

    func trigger() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(lastFire) * 1000 < Double(debounceMs) { return }
        lastFire = now
        onFire()
    }
}

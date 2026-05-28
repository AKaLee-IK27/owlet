import AppKit
import Foundation

/// Single source of truth for "what should the clipboard be restored to
/// after Owlet's transient writes."
///
/// **Problem this solves.** Capture and Replace both overwrite the clipboard
/// briefly and need to restore the user's original. Naive `asyncAfter` restore
/// races on rapid re-triggers — the second capture's "original" ends up being
/// the first capture's transient clipboard, so the final restore writes
/// captured text back to the clipboard and the user's true original is lost.
///
/// **How this fixes it.** `snapshotBeforeOverwrite()` caches the first true
/// original and returns it on subsequent calls until a restore fires. Rapid
/// re-triggers all share the same cached original; `scheduleRestore` cancels
/// any in-flight restore so they coalesce into the latest deadline.
///
/// Thread-safe via NSLock — call sites are mixed-context (HotkeyEventTap
/// dispatches to background, RewriterFlow is @MainActor, restore fires on
/// main). NSPasteboard itself is documented thread-safe.
final class ClipboardGuard: @unchecked Sendable {

    static let shared = ClipboardGuard()

    private let lock = NSLock()
    private var pendingOriginal: String?
    private var pendingRestoreWorkItem: DispatchWorkItem?

    /// The last-known pasteboard changeCount after an Owlet-initiated write.
    /// Used by AXBridge to detect whether the clipboard was modified externally
    /// (e.g., by Ghostty auto-copy, user Cmd+C) since Owlet last touched it.
    private(set) var lastOwletChangeCount: Int = 0

    private init() {}

    /// Snapshot the current clipboard BEFORE you overwrite it.
    ///
    /// If a previous overwrite is still pending its restore, the true
    /// original is already cached — this returns that and does NOT update
    /// the cache with whatever transient value Owlet just wrote.
    ///
    /// TODO: external-change detection. If the user manually `Cmd+C`s
    /// something between capture and restore, we still think the cached
    /// value is the original and would overwrite their new copy. Track
    /// `NSPasteboard.changeCount` after each Owlet write; on next
    /// `snapshotBeforeOverwrite`, if current count != last-known-count an
    /// external write happened and the cache should refresh.
    @discardableResult
    func snapshotBeforeOverwrite() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if pendingOriginal != nil {
            return pendingOriginal
        }
        let current = NSPasteboard.general.string(forType: .string)
        pendingOriginal = current
        return current
    }

    /// Schedule the original to be restored after `delay` seconds.
    /// Cancels any in-flight restore so rapid re-triggers coalesce into one
    /// restore at the latest deadline.
    func scheduleRestore(after delay: TimeInterval) {
        lock.lock()
        pendingRestoreWorkItem?.cancel()
        let work = DispatchWorkItem { self.performRestore() }
        pendingRestoreWorkItem = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Abort a pending overwrite cycle without restoring. Call this when an
    /// overwrite attempt failed and the clipboard is unchanged — leaving
    /// `pendingOriginal` set would cause the NEXT capture to incorrectly
    /// treat the clipboard as already-overwritten.
    func cancelPendingRestore() {
        lock.lock()
        defer { lock.unlock() }
        pendingRestoreWorkItem?.cancel()
        pendingRestoreWorkItem = nil
        pendingOriginal = nil
    }

    /// Record the current pasteboard changeCount after an Owlet write.
    func recordOwletChangeCount(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        lastOwletChangeCount = count
    }

    /// Check whether the clipboard has been modified externally since Owlet
    /// last wrote to it.
    func hasExternalClipboardChange() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return NSPasteboard.general.changeCount != lastOwletChangeCount
    }

    private func performRestore() {
        lock.lock()
        defer { lock.unlock() }
        guard let original = pendingOriginal else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(original, forType: .string)
        lastOwletChangeCount = pb.changeCount
        pendingOriginal = nil
        pendingRestoreWorkItem = nil
    }
}

import AppKit
import SwiftUI

/// Owns the non-activating NSPanel that hosts the SwiftUI popup.
/// Anchors near a focused-element screen rect and manages entry/exit
/// animations using the durations in Theme.Motion.
@MainActor
final class PopupWindowController {

    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?

    /// Show the given SwiftUI content in the floating panel.
    /// - Parameters:
    ///   - content: SwiftUI view to host. Should NOT apply its own frame
    ///     width — the panel sizes itself to `width`.
    ///   - anchorRect: optional screen rect to anchor below (or above if
    ///     below is off-screen). When nil the panel is centered.
    ///   - width: override the panel/content width. Defaults to
    ///     `Theme.Card.width` for the legacy rewriter popup. The v0.4 branded
    ///     floater passes `OwletDesign.Floater.width` (420pt).
    func show<Content: View>(_ content: Content,
                                        anchorRect: NSRect?,
                                        width: CGFloat? = nil) {
        let w = width ?? Theme.Card.width
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: w, height: Theme.Card.minHeight),
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true   // text field can become key; buttons don't
            p.level = .floating
            p.hidesOnDeactivate = false
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel = p
        }

        let hosting = NSHostingView(rootView:
            content
                .frame(width: w)
                .frame(minHeight: Theme.Card.minHeight, maxHeight: Theme.Card.maxHeight)
        )
        panel?.contentView = hosting
        // Resize panel if width changed since last show.
        panel?.setContentSize(NSSize(width: w, height: hosting.fittingSize.height))

        if let anchor = anchorRect {
            position(near: anchor)
        } else {
            panel?.center()
        }

        panel?.alphaValue = 0
        panel?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }

        installClickOutsideMonitor()
        installAppSwitchDismiss()
    }

    func hide(_ completion: (() -> Void)? = nil) {
        removeClickOutsideMonitor()
        removeAppSwitchDismiss()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0
        }, completionHandler: {
            self.panel?.orderOut(nil)
            completion?()
        })
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    private func installAppSwitchDismiss() {
        guard appSwitchObserver == nil else { return }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Ignore Owlet activating itself (e.g. when the context field
            // takes key focus) — only dismiss when ANOTHER app comes forward.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            self?.hide()
        }
    }

    private func removeAppSwitchDismiss() {
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    private func position(near anchor: NSRect) {
        guard let panel = panel,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        else { return }
        let margin: CGFloat = 12
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - panel.frame.height - margin)
        // Flip above if below would go off-screen.
        if origin.y < screen.visibleFrame.minY {
            origin.y = anchor.maxY + margin
        }
        // Constrain x to screen.
        origin.x = max(screen.visibleFrame.minX + margin,
                       min(screen.visibleFrame.maxX - panel.frame.width - margin, origin.x))
        panel.setFrameOrigin(origin)
    }
}

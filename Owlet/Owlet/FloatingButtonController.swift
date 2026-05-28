import AppKit
import SwiftUI

/// Manages a tiny non-activating NSPanel that hosts the floating owl button.
/// Mirrors PopupWindowController patterns.
@MainActor
final class FloatingButtonController {

    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private let onButtonClicked: @MainActor () -> Void

    init(onButtonClicked: @escaping @MainActor () -> Void) {
        self.onButtonClicked = onButtonClicked
    }

    /// Show the floating button at the given screen point.
    func show(at point: NSPoint) {
        guard panel == nil else { return }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let hosting = NSHostingView(rootView: FloatingButtonView(onClick: { [weak self] in
            Task { @MainActor in
                self?.dismissAndTriggerRewrite()
            }
        }))
        p.contentView = hosting

        // Position: constrain to screen bounds with small margin.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let margin: CGFloat = 8
            var origin = point
            origin.x = max(screen.visibleFrame.minX + margin,
                           min(screen.visibleFrame.maxX - 32 - margin, origin.x))
            origin.y = max(screen.visibleFrame.minY + margin,
                           min(screen.visibleFrame.maxY - 32 - margin, origin.y))
            p.setFrameOrigin(origin)
        }

        panel = p
        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        installClickOutsideMonitor()
    }

    /// Hide with fade-out animation.
    func hide() {
        removeClickOutsideMonitor()
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            self.panel = nil
        })
    }

    /// Immediate hide, then trigger the rewrite flow.
    private func dismissAndTriggerRewrite() {
        removeClickOutsideMonitor()
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            self.panel = nil
            self.onButtonClicked()
        })
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self = self, let panel = self.panel else { return }
            let location = event.locationInWindow ?? NSEvent.mouseLocation
            if !panel.frame.contains(location) {
                Task { @MainActor in self.hide() }
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

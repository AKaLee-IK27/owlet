import AppKit
import SwiftUI

/// Owns the non-activating NSPanel that hosts the SwiftUI popup.
/// Anchors near a focused-element screen rect and manages entry/exit
/// animations using the durations in Theme.Motion.
final class PopupWindowController {

    private var panel: NSPanel?

    @MainActor func show<Content: View>(_ content: Content, anchorRect: NSRect?) {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: Theme.Card.width, height: Theme.Card.minHeight),
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
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel = p
        }

        let hosting = NSHostingView(rootView:
            content
                .frame(width: Theme.Card.width)
                .frame(minHeight: Theme.Card.minHeight, maxHeight: Theme.Card.maxHeight)
        )
        panel?.contentView = hosting

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
    }

    func hide(_ completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0
        }, completionHandler: {
            self.panel?.orderOut(nil)
            completion?()
        })
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

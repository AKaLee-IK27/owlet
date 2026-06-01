import AppKit

@MainActor
protocol GhostTextOverlaying: AnyObject {
    var isVisible: Bool { get }
    func show(_ text: String, at caretScreenRect: NSRect)
    func hide()
}

/// Click-through, non-activating panel that paints grey ghost text next to the
/// caret. It never becomes key and never owns input; the event tap remains the
/// sole accept/dismiss path.
@MainActor
final class GhostTextOverlay: GhostTextOverlaying {
    /// Padding between the chip's blurred edge and the suggestion text.
    private static let hInset: CGFloat = 7
    private static let vInset: CGFloat = 3

    private var panel: NSPanel?
    private let backdrop = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ text: String, at caretScreenRect: NSRect) {
        let panel = ensurePanel()

        // Match the ghost to the editor's text size so it reads as an inline
        // continuation rather than a floating label. The caret rect's height is
        // ~the line height; SF's line height is ~1.16x the point size. Fall back
        // to 13pt when the field reports no usable height.
        let lineHeight = caretScreenRect.height
        let fontSize = lineHeight > 1 ? min(max(lineHeight / 1.16, 10), 22) : 13
        label.font = .systemFont(ofSize: fontSize)
        label.stringValue = text
        label.sizeToFit()

        // Wrap the text in a padded backdrop so the suggestion stays legible over
        // any document content, rather than a faint label the user can't read.
        let textWidth = min(label.fittingSize.width, 420)
        let textHeight = label.fittingSize.height
        let width = textWidth + Self.hInset * 2
        let height = textHeight + Self.vInset * 2
        panel.setContentSize(NSSize(width: width, height: height))
        label.frame = NSRect(x: Self.hInset, y: Self.vInset, width: textWidth, height: textHeight)

        // Sit just right of the caret, vertically centered on the caret line, so
        // the ghost shares the caret's baseline instead of floating above it.
        var origin = NSPoint(x: caretScreenRect.maxX + 1,
                             y: caretScreenRect.midY - height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(caretScreenRect) }) ?? NSScreen.main {
            origin.x = min(origin.x, screen.visibleFrame.maxX - width - 4)
            origin.y = max(screen.visibleFrame.minY + 4, min(origin.y, screen.visibleFrame.maxY - height - 4))
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Rounded, blurred chip behind the text — native popover material so it
        // reads on light and dark documents alike and tracks system appearance.
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        backdrop.layer?.masksToBounds = true

        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.alignment = .left
        label.backgroundColor = .clear
        label.drawsBackground = false
        backdrop.addSubview(label)
        panel.contentView = backdrop

        self.panel = panel
        return panel
    }
}

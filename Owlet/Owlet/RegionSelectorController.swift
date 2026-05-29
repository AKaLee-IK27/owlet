import AppKit

/// A borderless panel that *can* become key — the default for borderless
/// windows is `canBecomeKey == false`. Used for the per-screen overlays.
final class RegionSelectorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Manages drag-to-select region capture with **one overlay window per screen**.
///
/// A single window spanning the union of all screens cannot be correct on
/// multi-monitor setups: a window carries one screen's properties (scale,
/// coordinate origin), so the portion over another display renders/positions
/// wrong. One window per `NSScreen` gives each overlay a clean screen-local
/// coordinate space and the right display to capture. Only the screen under the
/// cursor is dimmed, and the dim follows the cursor across screens.
///
/// Esc is handled via `NSEvent` monitors rather than an in-view `keyDown`,
/// because with multiple windows only one can be key — an in-view handler would
/// silently miss every non-key screen. (Owlet already holds Input Monitoring,
/// so the global monitor works.)
@MainActor
final class RegionSelectorController {

    private var panels: [RegionSelectorPanel] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    /// Shows the region selection overlay and returns the selected rect in
    /// global AppKit screen coordinates (bottom-left origin), or nil if the
    /// user cancelled (Esc, right-click, or a click without a drag).
    ///
    /// If the overlay is already showing, this toggles it off and returns nil —
    /// re-triggering the hotkey closes the selector rather than stacking another.
    func selectRegion() async -> CGRect? {
        if continuation != nil || !panels.isEmpty {
            cancel()
            return nil
        }
        return await withCheckedContinuation { cont in
            continuation = cont
            present()
        }
    }

    func complete(with rect: CGRect) {
        guard let cont = continuation else { return }
        continuation = nil
        dismiss()
        cont.resume(returning: rect)
    }

    func cancel() {
        guard let cont = continuation else { return }
        continuation = nil
        dismiss()
        cont.resume(returning: nil)
    }

    // MARK: Private

    private func present() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            cancel()
            return
        }

        let cursor = NSEvent.mouseLocation
        for screen in screens {
            let panel = RegionSelectorPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true

            let view = RegionSelectorView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.isActiveScreen = screen.frame.contains(cursor)
            view.onComplete = { [weak self] rect in self?.complete(with: rect) }
            view.onCancel = { [weak self] in self?.cancel() }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        installKeyMonitors()
    }

    /// Esc cancels. Local catches it when an overlay is key; global catches it
    /// otherwise (Input Monitoring grant makes this reliable). Both are removed
    /// in `dismiss()` — a leaked monitor firing into a torn-down continuation
    /// is exactly the kind of bug that survives a green build.
    private func installKeyMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            Task { @MainActor in self?.cancel() }
            return nil // swallow
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancel() }
        }
    }

    private func dismiss() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }
}

/// The per-screen drag surface, working entirely in its own screen-local
/// coordinate space. Reports the selection in global AppKit screen coordinates
/// (via `convertToScreen`) so the capture path is unchanged.
final class RegionSelectorView: NSView {

    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    /// Whether the cursor is on this view's screen. Only the active screen dims.
    var isActiveScreen = false {
        didSet { if oldValue != isActiveScreen { needsDisplay = true } }
    }

    /// Below this drag size (points, either axis) a mouseUp is a click, which
    /// cancels — "if they click instead of drag, close it".
    private let minDragSize: CGFloat = 5

    private var anchor: CGPoint?
    private var selection: CGRect = .zero // view-local coords
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        isDragging = false
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = anchor else { return }
        isDragging = true
        let cur = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(anchor.x, cur.x),
            y: min(anchor.y, cur.y),
            width: abs(cur.x - anchor.x),
            height: abs(cur.y - anchor.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { anchor = nil; isDragging = false }
        if selection.width >= minDragSize && selection.height >= minDragSize {
            let windowRect = convert(selection, to: nil)
            let globalRect = window?.convertToScreen(windowRect) ?? windowRect
            onComplete?(globalRect)
        } else {
            onCancel?() // click without a meaningful drag
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    // MARK: Cursor + tracking (dim follows the cursor across screens)

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isActiveScreen = true }
    override func mouseExited(with event: NSEvent) {
        // While dragging the mouse is captured to this view; don't un-dim.
        if !isDragging { isActiveScreen = false }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isActiveScreen {
            NSColor.black.withAlphaComponent(0.4).setFill()
            bounds.fill()
            if !isDragging { drawHint() }
        }

        if isDragging && selection.width > 1 && selection.height > 1 {
            NSColor.white.withAlphaComponent(0.12).setFill()
            selection.fill()
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func drawHint() {
        let text = "Drag to select a region · Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 8
        let box = CGRect(
            x: bounds.midX - (size.width + pad * 2) / 2,
            y: bounds.maxY - size.height - pad * 2 - 24,
            width: size.width + pad * 2,
            height: size.height + pad * 2
        )
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad), withAttributes: attrs)
    }
}

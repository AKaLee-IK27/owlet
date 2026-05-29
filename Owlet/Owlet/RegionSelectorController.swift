import AppKit
import SwiftUI

/// Manages full-screen overlay windows for drag-to-select region capture.
@MainActor
final class RegionSelectorController {

    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var selections: [Int: CGRect] = [:]
    private var draggingStates: [Int: Bool] = [:]

    /// Shows the region selection overlay and returns the selected rect,
    /// or nil if the user cancelled (Esc or right-click).
    func selectRegion() async -> CGRect? {
        await withCheckedContinuation { cont in
            continuation = cont

            for screen in NSScreen.screens {
                let panel = NSPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.level = .screenSaver
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
                panel.hidesOnDeactivate = false
                panel.orderFrontRegardless()
                panel.makeKey()

                let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int ?? 0
                selections[screenID] = .zero
                draggingStates[screenID] = false

                let selectionBinding = Binding<CGRect>(
                    get: { self.selections[screenID, default: .zero] },
                    set: { self.selections[screenID] = $0 }
                )
                let draggingBinding = Binding<Bool>(
                    get: { self.draggingStates[screenID, default: false] },
                    set: { self.draggingStates[screenID] = $0 }
                )

                let hosting = NSHostingView(rootView: RegionSelectorOverlayView(
                    selection: selectionBinding,
                    isDragging: draggingBinding,
                    onAnchorSet: { _ in }
                ))
                panel.contentView = hosting
                panels.append(panel)
            }

            // Install global key monitor for Esc
            _ = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                if event.keyCode == 53 { // Esc
                    Task { @MainActor in self?.cancel() }
                }
            }
        }
    }

    func complete(with rect: CGRect) {
        dismissAll()
        continuation?.resume(returning: rect)
        continuation = nil
    }

    func cancel() {
        dismissAll()
        continuation?.resume(returning: nil)
        continuation = nil
    }

    private func dismissAll() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
}

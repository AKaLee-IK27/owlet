import AppKit
import SwiftUI

/// Hosts PermissionModal in a regular (activating) window so the user can
/// click the deep-link buttons. Owlet stays alive until the user clicks Quit.
final class PermissionModalWindowController {

    private var window: NSWindow?

    func show(missing: Set<Permission>, onQuit: @escaping () -> Void) {
        let modal = PermissionModal(missing: missing, onQuit: onQuit)
        let hosting = NSHostingController(rootView: modal)
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable]
        w.title = "Owlet — Permissions Required"
        w.level = .floating
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)  // show in Dock so window can be focused
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    func hide() {
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

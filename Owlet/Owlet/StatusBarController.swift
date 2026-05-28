import AppKit
import SwiftUI

/// Menu bar item so the user can see Owlet is running and quit/restart it.
/// Lives next to the clock area; left-click opens a menu.
@MainActor
final class StatusBarController {

    private let statusItem: NSStatusItem
    private let probePermissions: () -> PermissionStatus

    init(probePermissions: @escaping () -> PermissionStatus = { PermissionChecker.check() }) {
        self.probePermissions = probePermissions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureIcon()
        rebuildMenu()
    }

    /// Called by AppDelegate's periodic permission poll so the menu's status
    /// line reflects the current grant state without the user having to do anything.
    func refresh() {
        rebuildMenu()
    }

    // MARK: Private

    private func configureIcon() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(named: "OwletGlyph") {
            image.size = NSSize(width: 22, height: 22)
            image.isTemplate = false
            button.image = image
        } else if let fallback = NSImage(systemSymbolName: "bird", accessibilityDescription: "Owlet") {
            fallback.isTemplate = true
            button.image = fallback
        } else {
            button.title = "Owlet"
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Owlet — running", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let perms = NSMenuItem(title: permissionsLabel(probePermissions()), action: nil, keyEquivalent: "")
        perms.isEnabled = false
        menu.addItem(perms)

        menu.addItem(NSMenuItem.separator())

        let restart = NSMenuItem(title: "Restart Owlet", action: #selector(handleRestart), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

        let quit = NSMenuItem(title: "Quit Owlet", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func permissionsLabel(_ status: PermissionStatus) -> String {
        switch status {
        case .allGranted:
            return "Permissions: ✓ Accessibility  ✓ Input Monitoring"
        case .missing(let set):
            let ax = set.contains(.accessibility) ? "✗" : "✓"
            let im = set.contains(.inputMonitoring) ? "✗" : "✓"
            return "Permissions: \(ax) Accessibility  \(im) Input Monitoring"
        }
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }

    /// Restart: spawn a detached `/bin/sh` that sleeps a second and reopens us,
    /// then we terminate. The new instance picks up any code changes (after
    /// install.sh) and re-evaluates permissions.
    @objc private func handleRestart() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
    }
}

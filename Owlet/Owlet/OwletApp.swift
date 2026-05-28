import SwiftUI
import AppKit
import os.log

@main
struct OwletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "app")

    private var permissionModal: PermissionModalWindowController?
    private var hotkeyTap: HotkeyEventTap?
    private var statusBar: StatusBarController?
    private var permissionPollTimer: Timer?
    private var lastKnownPermissionStatus: PermissionStatus = .allGranted

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ALWAYS create the status bar item first. Provides a visible signal
        // that Owlet is running and an escape hatch (Quit) regardless of
        // what permission state we end up in.
        self.statusBar = StatusBarController()

        let status = PermissionChecker.check()
        lastKnownPermissionStatus = status
        Self.logger.info("Launch: permission status = \(String(describing: status), privacy: .public)")

        switch status {
        case .allGranted:
            startNormalLaunch()
        case .missing(let missing):
            showPermissionModal(missing: missing)
        }
    }

    private func startNormalLaunch() {
        // Rewriter chord — defaults to Option+Space, user-configurable via Settings.
        // The closure is @Sendable; don't capture self.
        let rewriterTap = HotkeyEventTap(chord: Preferences.shared.hotkey) {
            Task { @MainActor in
                let flow = RewriterFlow()
                await flow.start()
            }
        }
        switch rewriterTap.start() {
        case .success:
            self.hotkeyTap = rewriterTap
            Self.logger.info("Rewriter hotkey tap active")
        case .failure:
            // Should be rare since PermissionChecker said all granted; defensive
            showPermissionModal(missing: [.inputMonitoring])
            return
        }

        // Apply the launch-at-login preference (defaults to true on first launch).
        do {
            try LoginItemManager.setRegistered(Preferences.shared.launchAtLogin)
        } catch {
            Self.logger.warning("Login item apply failed: \(error.localizedDescription, privacy: .public)")
        }

        // (statusBar was already created in applicationDidFinishLaunching.)

        // Poll for permission revocation every 60 s.
        startPermissionPolling()
    }

    private func showPermissionModal(missing: Set<Permission>) {
        let controller = PermissionModalWindowController()
        controller.show(missing: missing) {
            NSApp.terminate(nil)
        }
        self.permissionModal = controller
    }

    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let current = PermissionChecker.check()
            // Keep the status-bar label fresh whether anything changed or not.
            self.statusBar?.refresh()
            if current != self.lastKnownPermissionStatus {
                self.lastKnownPermissionStatus = current
                if case .missing(let missing) = current {
                    self.notifyPermissionRevoked(missing: missing)
                }
            }
        }
    }

    private func notifyPermissionRevoked(missing: Set<Permission>) {
        let names = missing.map { $0.rawValue }.sorted().joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Owlet stopped working"
        alert.informativeText = "A required permission was revoked: \(names). Re-grant in System Settings, then relaunch Owlet."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit Owlet")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if missing.contains(.accessibility) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            if missing.contains(.inputMonitoring) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            }
        }
        NSApp.terminate(nil)
    }
}

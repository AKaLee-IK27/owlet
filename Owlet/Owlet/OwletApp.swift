import SwiftUI
import AppKit
import os.log

@main
struct OwletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Empty Settings scene — Owlet is LSUIElement (.accessory), and SwiftUI's
        // Settings scene window won't reliably front from a menu-bar app.
        // The real Settings UI is presented via AppDelegate.showSettings() using
        // a hand-rolled NSWindow + NSHostingController.
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
    private var prefsObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?
    private var optionHoldDetector: OptionHoldDetector?
    private var floatingButtonController: FloatingButtonController?
    private var autocompleteController: AutocompleteController?
    /// Non-nil only while the engine backend is selected; owns the `owlet-engine`
    /// process + streaming connection so it can be started on enable and torn down
    /// on disable/backend-switch/quit.
    private var sidecarTransport: SidecarTransport?
    /// Session-only pause for inline suggestions (menu-bar toggle). Deliberately
    /// not persisted — a pause that silently survives relaunch becomes a
    /// "why are there no suggestions?" trap (feat-017 territory).
    private var autocompletePaused = false

    /// Present Owlet's Settings window. Promotes activation policy to `.regular`
    /// so the window can take focus from a menu-bar app, and reverts to `.accessory`
    /// when the window closes (so the Dock icon doesn't linger).
    func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Owlet Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 500, height: 460))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
            settingsCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Terminate the engine process on a clean quit so it doesn't orphan.
        sidecarTransport?.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Inject showSettings as a closure — NSApp.delegate goes through SwiftUI's
        // NSApplicationDelegateAdaptor wrapper, so `as? AppDelegate` returns nil
        // and we can't reach this instance through the runtime delegate accessor.
        self.statusBar = StatusBarController(
            onSettings: { [weak self] in self?.showSettings() },
            isPaused: { [weak self] in self?.autocompletePaused ?? false },
            onTogglePause: { [weak self] in self?.toggleAutocompletePause() }
        )

        prefsObserver = NotificationCenter.default.addObserver(
            forName: Preferences.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let change = note.userInfo?["change"] as? Preferences.Change else { return }
            Task { @MainActor in self.handlePreferencesChanged(change) }
        }

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

    private func handlePreferencesChanged(_ change: Preferences.Change) {
        switch change {
        case .hotkey:
            rebindHotkeyTap()
        case .launchAtLogin:
            do {
                try LoginItemManager.setRegistered(Preferences.shared.launchAtLogin)
            } catch {
                Self.logger.warning("Login item apply failed: \(error.localizedDescription, privacy: .public)")
            }
        case .model:
            // Nothing to do here — RewriterFlow.makeDefaultRewriter() reads
            // Preferences.shared.model lazily on each invocation.
            break
        case .visionModel:
            // Nothing to do here — VisionClient reads Preferences.shared.visionModel
            // lazily on each invocation.
            break
        case .autocompleteEnabled:
            if Preferences.shared.autocompleteEnabled {
                // Spawn the engine (if that's the backend) now that suggestions are on.
                sidecarTransport?.start()
            } else {
                autocompleteController?.stop()
                sidecarTransport?.stop() // kill the engine process while disabled
                hotkeyTap?.setAutocompleteSuggestionVisible(false)
            }
        case .autocompleteBackend:
            // Rebuild on the newly selected transport (tears down any running engine).
            installAutocomplete()
            hotkeyTap?.setAutocompleteSuggestionVisible(false)
        case .autocompleteModel:
            autocompleteController?.stop()
            hotkeyTap?.setAutocompleteSuggestionVisible(false)
        case .suggestionLength:
            // Nothing to do here — beginPrediction reads the token cap lazily on
            // the next prediction; the next keystroke picks up the new length.
            break
        case .autocompleteDeniedApps:
            // Nothing to do here — beginPrediction reads the denylist lazily via
            // its deniedAppsProvider on the next prediction.
            break
        }
    }

    /// (Re)build the autocomplete controller with the transport selected in
    /// Preferences, tearing down any previous transport/engine. Spawns the sidecar
    /// engine only when the engine backend is selected AND autocomplete is enabled,
    /// so a default (Ollama) or disabled config never launches a helper process.
    private func installAutocomplete() {
        sidecarTransport?.stop()
        sidecarTransport = nil
        autocompleteController?.stop()

        let transport: SuggestionTransport
        switch Preferences.shared.autocompleteBackend {
        case .engine:
            let sidecar = SidecarTransport(config: EngineSupervisor.defaultConfig())
            sidecarTransport = sidecar
            transport = sidecar
        case .ollama:
            transport = OllamaTransport()
        }

        autocompleteController = AutocompleteController(
            transport: transport,
            pausedProvider: { [weak self] in self?.autocompletePaused ?? false },
            onVisibilityChanged: { [weak self] visible in
                self?.hotkeyTap?.setAutocompleteSuggestionVisible(visible)
            }
        )

        if Preferences.shared.autocompleteEnabled {
            sidecarTransport?.start()
        }
    }

    /// Flip the session-only pause. When pausing, tear down any in-flight or
    /// visible suggestion so the ghost disappears immediately.
    private func toggleAutocompletePause() {
        autocompletePaused.toggle()
        if autocompletePaused {
            autocompleteController?.stop()
            hotkeyTap?.setAutocompleteSuggestionVisible(false)
        }
    }

    private func makeHotkeyTap(optionHoldDetector: OptionHoldDetector?) -> HotkeyEventTap {
        HotkeyEventTap(
            chord: Preferences.shared.hotkey,
            onHotkey: {
                Task { @MainActor in
                    let flow = RewriterFlow()
                    await flow.start()
                }
            },
            optionHoldDetector: optionHoldDetector,
            onDoubleClick: {
                Task { @MainActor in
                    let flow = RewriterFlow()
                    await flow.startFromScreenshot()
                }
            },
            onAutocompleteTextChanged: { [weak self] in
                Task { @MainActor in self?.autocompleteController?.textChanged() }
            },
            onAutocompleteAccept: { [weak self] in
                Task { @MainActor in self?.autocompleteController?.accept() }
            },
            onAutocompleteDismiss: { [weak self] in
                Task { @MainActor in self?.autocompleteController?.dismiss() }
            }
        )
    }

    private func rebindHotkeyTap() {
        hotkeyTap?.stop()
        let newTap = makeHotkeyTap(optionHoldDetector: optionHoldDetector)
        switch newTap.start() {
        case .success:
            hotkeyTap = newTap
            newTap.setAutocompleteSuggestionVisible(autocompleteController?.suggestionVisible ?? false)
            Self.logger.info("Rewriter hotkey rebound to \(Preferences.shared.hotkey.displayString, privacy: .public)")
        case .failure:
            Self.logger.error("Hotkey rebind failed; showing permission modal")
            showPermissionModal(missing: [.inputMonitoring])
        }
    }

    private func startNormalLaunch() {
        // Option hold detector — shows floating button when Option is held.
        let buttonController = FloatingButtonController { [weak self] in
            Task { @MainActor in
                let flow = RewriterFlow()
                await flow.start()
            }
        }
        self.floatingButtonController = buttonController

        let detector = OptionHoldDetector { [weak buttonController] in
            Task { @MainActor in
                let point = NSEvent.mouseLocation
                buttonController?.show(at: point)
            }
        }
        self.optionHoldDetector = detector

        installAutocomplete()

        // Rewriter chord — defaults to Option+Space, user-configurable via Settings.
        let rewriterTap = makeHotkeyTap(optionHoldDetector: detector)
        switch rewriterTap.start() {
        case .success:
            self.hotkeyTap = rewriterTap
            rewriterTap.setAutocompleteSuggestionVisible(autocompleteController?.suggestionVisible ?? false)
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

import SwiftUI
import AppKit

@main
struct OwletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }   // no windows; URL handler does the work
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private lazy var hotkeyCoordinator = HotkeyCoordinator(debounceMs: 200) { [weak self] in
        self?.invokeCurrentVerb()
    }
    private var pendingVerb: OwletVerb = .rewrite

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Trust check — quit with a guidance modal if AX isn't granted.
        if !AXBridge.isTrusted(promptIfNeeded: true) {
            showAXDeniedAndQuit()
            return
        }
        // Register URL event handler.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              let verb = URLSchemeParser.parse(url)
        else { return }
        pendingVerb = verb
        hotkeyCoordinator.trigger()
    }

    private func invokeCurrentVerb() {
        let verb = pendingVerb
        Task { @MainActor in
            let flow = CommandDispatcher.flow(for: verb)
            await flow.start()
        }
    }

    private func showAXDeniedAndQuit() {
        let alert = NSAlert()
        alert.messageText = "Owlet needs Accessibility permission"
        alert.informativeText = """
        Owlet uses Accessibility to read the text you've selected and to replace it with the rewrite when you click Replace.

        Open System Settings → Privacy & Security → Accessibility, enable Owlet, then launch Owlet again.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        NSApp.terminate(nil)
    }
}

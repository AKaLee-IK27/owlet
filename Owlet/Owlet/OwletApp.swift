import SwiftUI
import AppKit

@main
struct OwletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Placeholder — Task 8 wires the full launch tree.
        if !AXBridge.isTrusted(promptIfNeeded: true) {
            NSApp.terminate(nil)
        }
    }
}

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
        // Do not terminate here: test runner uses Owlet.app as TEST_HOST and
        // expects it to stay alive long enough for XCTest to attach.
    }
}

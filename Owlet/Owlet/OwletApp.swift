import SwiftUI

@main
struct OwletApp: App {
    var body: some Scene {
        // No windows — Owlet is a menu bar helper.
        // Phase 6 wires the URL handler, hotkey coordinator, and popup controller.
        Settings { EmptyView() }
    }
}

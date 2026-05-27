import SwiftUI
import AppKit

struct PermissionModal: View {
    let missing: Set<Permission>
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Owlet needs two macOS permissions")
                .font(.system(size: 17, weight: .semibold))

            Text("Grant these in System Settings, then quit and relaunch Owlet from /Applications.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                if missing.contains(.accessibility) {
                    permissionRow(
                        title: "Accessibility",
                        explanation: "To read the text you've selected and replace it with the rewrite.",
                        buttonTitle: "Open Accessibility…",
                        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    )
                }
                if missing.contains(.inputMonitoring) {
                    permissionRow(
                        title: "Input Monitoring",
                        explanation: "To detect your fn+Ctrl+R hotkey system-wide.",
                        buttonTitle: "Open Input Monitoring…",
                        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
                    )
                }
            }

            HStack {
                Spacer()
                Button("Quit", action: onQuit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func permissionRow(title: String, explanation: String, buttonTitle: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary)
            Button(buttonTitle) {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
        }
    }
}

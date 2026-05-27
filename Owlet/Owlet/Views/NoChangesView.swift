import SwiftUI

struct NoChangesView: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Owlet")
                .font(Theme.Fonts.sectionHeader)
                .foregroundStyle(Theme.Colors.textSecondary)
                .textCase(.uppercase)

            Text("Looks good — no changes needed.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.textPrimary)

            ScrollView {
                Text(text)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)

            HStack {
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Card.padding)
        .frame(width: Theme.Card.width)
    }
}

import SwiftUI

struct ResultView: View {
    let original: String
    let rewritten: String
    let segments: [DiffSegment]?       // nil ⇒ render plain rewritten text (over-collapse case)
    let canReplace: Bool

    let onReplace: () -> Void
    let onCopy:    () -> Void
    let onCancel:  () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rewrite")
                .font(Theme.Fonts.sectionHeader)
                .foregroundStyle(Theme.Colors.textSecondary)
                .textCase(.uppercase)

            ScrollView {
                if let segs = segments {
                    DiffView(segments: segs)
                } else {
                    Text(rewritten)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .textSelection(.enabled)
                    Text("Too many changes to diff cleanly")
                        .font(Theme.Fonts.sectionHeader)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.top, 6)
                }
            }
            .frame(maxHeight: 280)

            HStack {
                Text("Owlet")
                    .font(Theme.Fonts.wordmark)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Copy",   action: onCopy)
                    .keyboardShortcut("c", modifiers: .command)
                Button("Replace", action: onReplace)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canReplace)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Card.padding)
        .frame(width: Theme.Card.width)
    }
}

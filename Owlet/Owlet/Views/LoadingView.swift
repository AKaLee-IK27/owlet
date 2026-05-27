import SwiftUI

struct LoadingView: View {
    let sourceText: String
    let isLong: Bool

    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isLong ? "Owlet is thinking… this is a long one." : "Owlet is thinking…")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.Colors.textSecondary.opacity(0.25))
                        .frame(height: 10)
                        .frame(maxWidth: i == 3 ? 200 : .infinity, alignment: .leading)
                }
            }

            Spacer()

            HStack {
                Text("Owlet")
                    .font(Theme.Fonts.wordmark)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .padding(Theme.Card.padding)
        .frame(width: Theme.Card.width)
    }
}

import SwiftUI

/// A 32×32 circular button showing the Owlet owl glyph.
/// Rendered in template mode so it adapts to system appearance.
struct FloatingButtonView: View {
    let onClick: () -> Void

    var body: some View {
        Image("OwletGlyph")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            .onTapGesture {
                onClick()
            }
    }
}

#Preview {
    FloatingButtonView(onClick: {})
        .frame(width: 32, height: 32)
}

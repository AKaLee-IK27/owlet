import SwiftUI

struct DiffView: View {
    let segments: [DiffSegment]

    var body: some View {
        // Use Text concatenation so words wrap naturally as a single paragraph.
        // NOTE: SwiftUI Text concatenation does not support inline background fills —
        // backgrounds would require rendering each word as its own Text in a FlexLayout.
        // V1 ships foreground color + strikethrough only; backgrounds are a v1.1 follow-up.
        segments.reduce(Text("")) { acc, seg in
            acc + styled(seg) + Text(" ")
        }
        .font(Theme.Fonts.body)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
    }

    private func styled(_ seg: DiffSegment) -> Text {
        switch seg.kind {
        case .unchanged:
            return Text(seg.text).foregroundColor(Theme.Colors.textPrimary)
        case .added:
            return Text(seg.text)
                .foregroundColor(Theme.Colors.addedForeground)
                .underline(false)
        case .removed:
            return Text(seg.text)
                .foregroundColor(Theme.Colors.removedForeground)
                .strikethrough(true)
        }
    }
}

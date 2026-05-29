import SwiftUI

struct ErrorView: View {
    let kind: ErrorKind
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Owlet")
                .font(Theme.Fonts.sectionHeader)
                .foregroundStyle(Theme.Colors.textSecondary)
                .textCase(.uppercase)

            Text(message)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                Button("Dismiss", action: onDismiss).keyboardShortcut(.cancelAction)
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .keyboardShortcut("r", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(Theme.Card.padding)
        .frame(width: Theme.Card.width, height: Theme.Card.minHeight)
    }

    private var message: String {
        switch kind {
        case .selectionEmpty:           return "Select some text first."
        case .passwordField:            return "Owlet won't read from password fields."
        case .selectionUnreadable:      return "Owlet can't read the selection in this app."
        case .inputTooLong(let count):  return "That selection is too long (\(count) chars; max 16,000)."
        case .ollamaDown:               return "Looks like Ollama isn't running. Start it and click Retry."
        case .timeout:                  return "That took longer than expected. Retry?"
        case .emptyOutput:              return "Owlet didn't come back with anything. Retry?"
        case .focusLost:                return "The original text lost focus. You can still Copy the rewrite."
        case .axDenied:                 return "Owlet needs Accessibility permission. Open System Settings →"
        case .backendUnavailable(let m):return "Backend unavailable: \(m)"
        case .noTextInImage:            return "No text found in the selected region."
        }
    }
}

import SwiftUI

struct PopupView: View {
    let state: PopupState

    let onReplace: () -> Void
    let onCopy:    () -> Void
    let onCancel:  () -> Void
    let onRetry:   () -> Void

    var body: some View {
        Group {
            switch state {
            case .loading(let src, let long, _):
                LoadingView(sourceText: src, isLong: long)
            case .result(let orig, let rew, let segs, let canReplace, _):
                ResultView(original: orig,
                           rewritten: rew,
                           segments: segs,
                           canReplace: canReplace,
                           onReplace: onReplace,
                           onCopy: onCopy,
                           onCancel: onCancel)
            case .empty(let text):
                NoChangesView(text: text, onDismiss: onCancel)
            case .error(let kind):
                ErrorView(kind: kind, onRetry: onRetry, onDismiss: onCancel)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Card.cornerRadius))
        .transition(.opacity.combined(with: .offset(y: Theme.Motion.entryOffset)))
        .animation(Theme.Motion.stateTransition, value: stateKey)
    }

    /// Stable key so `.animation(value:)` re-triggers between cases.
    private var stateKey: String {
        switch state {
        case .loading:  return "loading"
        case .result:   return "result"
        case .empty:    return "empty"
        case .error:    return "error"
        }
    }
}

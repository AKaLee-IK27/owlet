import Foundation

/// Stub flow used when a non-shipped verb is invoked (translate/grammar/unknown).
final class UnavailableFlow: CaptureFlow {
    let tag = "unavailable"
    let popup: PopupWindowController
    init(popup: PopupWindowController = PopupWindowController()) { self.popup = popup }

    @MainActor
    func start() async {
        let state = PopupState.error(.backendUnavailable(message: "That tool isn't available yet."))
        popup.show(PopupView(state: state,
                              onReplace: {}, onCopy: {}, onCancel: { [self] in popup.hide() },
                              onRetry: {}),
                   anchorRect: nil)
    }
}

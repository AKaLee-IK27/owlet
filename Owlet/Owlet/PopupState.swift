import Foundation

/// What the popup is currently showing.
enum PopupState: Equatable {
    case loading(sourceText: String, isLong: Bool, captureMethod: SelectionSnapshot.CaptureMethod = .ax)
    case result(original: String, rewritten: String, segments: [DiffSegment]?, canReplace: Bool, captureMethod: SelectionSnapshot.CaptureMethod = .ax)
    case empty(text: String)                      // rewrite ≈ original
    case error(ErrorKind)
}

/// All failure modes the popup can surface to the user. Each is rendered
/// with a friendly message in ErrorView; copy is centralized in Theme/ErrorKind.
enum ErrorKind: Equatable {
    case selectionEmpty
    case passwordField
    case selectionUnreadable
    case inputTooLong(charCount: Int)
    case ollamaDown
    case timeout
    case emptyOutput
    case focusLost
    case axDenied
    case backendUnavailable(message: String)
}

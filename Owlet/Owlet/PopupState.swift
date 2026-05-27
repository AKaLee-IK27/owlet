import Foundation

/// What the popup is currently showing.
enum PopupState: Equatable {
    case loading(sourceText: String, isLong: Bool)
    case result(original: String, rewritten: String, segments: [DiffSegment]?, canReplace: Bool)
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

// TEMPORARY: stubbed so PopupState compiles before DiffEngine lands.
// Task 10 will move this to DiffEngine.swift and delete this stub.
struct DiffSegment: Equatable {
    enum Kind: Equatable { case unchanged, added, removed }
    let text: String
    let kind: Kind
}

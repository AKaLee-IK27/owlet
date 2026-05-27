import Foundation

/// Common entry point for any Owlet command flow.
/// `start()` runs the full lifecycle for one invocation: capture → call backend
/// → present popup state → handle user action → dismiss.
protocol CaptureFlow {
    var tag: String { get }
    @MainActor func start() async
}

import Foundation

@MainActor
final class RewriterFlow: CaptureFlow {
    let tag = "rewriter"
    func start() async {
        // Full implementation lands in Task 24.
        // Placeholder so CommandDispatcher compiles and dispatcher tests pass.
    }
}

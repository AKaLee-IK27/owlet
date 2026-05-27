import Foundation

enum CommandDispatcher {
    /// Map a parsed verb to the flow that owns its lifecycle.
    /// Constructs flows fresh per invocation (state lives on the flow).
    @MainActor
    static func flow(for verb: OwletVerb) -> CaptureFlow {
        switch verb {
        case .rewrite:                return RewriterFlow()
        case .translate, .grammar, .unknown:
            return UnavailableFlow()
        }
    }
}

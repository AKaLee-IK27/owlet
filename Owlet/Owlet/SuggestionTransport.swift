import Foundation

/// A request to (re)compute suggestions for the caret context identified by `seq`.
/// `suffix` is carried for forward-compat (FIM) but ignored by v1 transports.
struct ContextRequest: Sendable, Equatable {
    let seq: UInt64
    let prefix: String
    let suffix: String
    let appID: String
    let trigger: Trigger
    let model: String
    let maxTokens: Int
}

/// A suggestion a transport pushes back for a given `seq` (Host-side shape).
struct TransportSuggestion: Sendable, Equatable {
    let tier: SuggestionTier
    let text: String
    let replaceRange: ReplaceRange?
}

/// The seam between the controller and inference.
///
/// A single `ContextRequest` may produce *multiple* suggestions over time (Tier 0
/// instantly, Tier 2 after the engine's pause-debounce), so results arrive through
/// `onSuggestion` keyed by `seq` rather than a one-shot return value. The controller
/// drops stale `seq`s; debounce/coalescing lives inside the transport (or, for the
/// sidecar, inside the engine), never in the controller.
///
/// Contract: a transport delivers a given `seq`'s suggestions in **non-decreasing tier
/// order** (Tier 0 before Tier 2), never a lower tier after a higher one for the same
/// `seq`. (The sidecar's single ordered UDS stream preserves the engine's send order.)
/// The controller also enforces this defensively, so a violation degrades to "no
/// regression" rather than a worse suggestion replacing a better one.
@MainActor
protocol SuggestionTransport: AnyObject {
    /// Called on the main actor when a suggestion is available for `seq`.
    var onSuggestion: ((UInt64, TransportSuggestion) -> Void)? { get set }
    /// The caret context changed; (re)compute suggestions for `request.seq`.
    func updateContext(_ request: ContextRequest)
    /// Abort in-flight work (the controller calls this on dismiss/stop).
    func cancel(seq: UInt64)
    /// Tear down any persistent resources (connections, tasks).
    func stop()
}

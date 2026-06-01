import Foundation

// Swift mirror of the Rust sidecar protocol (`tools/engine/src/proto.rs`, feat-021).
// Length-prefixed frames: 4-byte big-endian payload length + UTF-8 JSON. Messages are
// internally tagged (`{"type":"Ping"}`) so they decode symmetrically on both sides.
// The wire field names match serde's defaults: `app_id`, `replace_range`; enum values
// are the variant names (`"Keystroke"`, `"Complete"`).

enum Trigger: String, Codable, Equatable, Sendable {
    case keystroke = "Keystroke"
    case wordBoundary = "WordBoundary"
    case pause = "Pause"
    case hotkey = "Hotkey"
}

enum SuggestionTier: String, Codable, Equatable, Sendable {
    case complete = "Complete"
    case recorrect = "Recorrect"
    case sentence = "Sentence"
}

/// A half-open character range `[start, end)` a correction replaces.
struct ReplaceRange: Codable, Equatable, Sendable {
    let start: UInt32
    let end: UInt32
}

/// Host → Engine.
enum HostMessage: Equatable, Sendable {
    case contextUpdate(seq: UInt64, prefix: String, suffix: String, appID: String, trigger: Trigger)
    case cancel(seq: UInt64)
    case shutdown
    case ping
}

/// Engine → Host.
enum EngineMessage: Equatable, Sendable {
    case suggestion(seq: UInt64, tier: SuggestionTier, text: String, replaceRange: ReplaceRange?)
    case pong
    case error(seq: UInt64?, message: String)
}

extension HostMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, seq, prefix, suffix, trigger
        case appID = "app_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .contextUpdate(seq, prefix, suffix, appID, trigger):
            try c.encode("ContextUpdate", forKey: .type)
            try c.encode(seq, forKey: .seq)
            try c.encode(prefix, forKey: .prefix)
            try c.encode(suffix, forKey: .suffix)
            try c.encode(appID, forKey: .appID)
            try c.encode(trigger, forKey: .trigger)
        case let .cancel(seq):
            try c.encode("Cancel", forKey: .type)
            try c.encode(seq, forKey: .seq)
        case .shutdown:
            try c.encode("Shutdown", forKey: .type)
        case .ping:
            try c.encode("Ping", forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "ContextUpdate":
            self = .contextUpdate(
                seq: try c.decode(UInt64.self, forKey: .seq),
                prefix: try c.decode(String.self, forKey: .prefix),
                suffix: try c.decode(String.self, forKey: .suffix),
                appID: try c.decode(String.self, forKey: .appID),
                trigger: try c.decode(Trigger.self, forKey: .trigger))
        case "Cancel":
            self = .cancel(seq: try c.decode(UInt64.self, forKey: .seq))
        case "Shutdown":
            self = .shutdown
        case "Ping":
            self = .ping
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown HostMessage type \"\(type)\"")
        }
    }
}

extension EngineMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, seq, tier, text, message
        case replaceRange = "replace_range"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .suggestion(seq, tier, text, replaceRange):
            try c.encode("Suggestion", forKey: .type)
            try c.encode(seq, forKey: .seq)
            try c.encode(tier, forKey: .tier)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(replaceRange, forKey: .replaceRange)
        case .pong:
            try c.encode("Pong", forKey: .type)
        case let .error(seq, message):
            try c.encode("Error", forKey: .type)
            try c.encodeIfPresent(seq, forKey: .seq)
            try c.encode(message, forKey: .message)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "Suggestion":
            self = .suggestion(
                seq: try c.decode(UInt64.self, forKey: .seq),
                tier: try c.decode(SuggestionTier.self, forKey: .tier),
                text: try c.decode(String.self, forKey: .text),
                replaceRange: try c.decodeIfPresent(ReplaceRange.self, forKey: .replaceRange))
        case "Pong":
            self = .pong
        case "Error":
            self = .error(
                seq: try c.decodeIfPresent(UInt64.self, forKey: .seq),
                message: try c.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown EngineMessage type \"\(type)\"")
        }
    }
}

enum EngineProtocolError: Error, Equatable {
    case frameTooLarge(Int)
}

enum EngineFraming {
    /// Hard cap mirroring the Rust side so a corrupt length can't trigger a huge alloc.
    static let maxFrame = 4 * 1024 * 1024

    /// JSON-encode and length-prefix a host message into a ready-to-write frame.
    static func encodeFrame(_ msg: HostMessage) throws -> Data {
        try frame(JSONEncoder().encode(msg))
    }

    /// Prepend a 4-byte big-endian length to a JSON payload.
    static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maxFrame else { throw EngineProtocolError.frameTooLarge(payload.count) }
        let len = UInt32(payload.count)
        var out = Data([
            UInt8((len >> 24) & 0xFF),
            UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8) & 0xFF),
            UInt8(len & 0xFF),
        ])
        out.append(payload)
        return out
    }
}

/// Accumulates incoming bytes and pops complete frame payloads. Mirrors the Rust
/// `read_frame` loop: tolerates partial reads, distinguishes "need more" (nil) from a
/// corrupt oversized length (throws).
final class FrameBuffer {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete frame's payload, or nil if not enough bytes have arrived yet.
    func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let len = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if Int(len) > EngineFraming.maxFrame { throw EngineProtocolError.frameTooLarge(Int(len)) }
        let total = 4 + Int(len)
        guard buffer.count >= total else { return nil }
        let payload = Data(buffer.dropFirst(4).prefix(Int(len)))
        buffer = Data(buffer.dropFirst(total))
        return payload
    }

    /// Decode the next complete engine message, or nil if incomplete.
    func nextEngineMessage() throws -> EngineMessage? {
        guard let payload = try next() else { return nil }
        return try JSONDecoder().decode(EngineMessage.self, from: payload)
    }
}

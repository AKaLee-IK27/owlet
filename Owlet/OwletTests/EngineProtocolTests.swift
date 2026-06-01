import XCTest
@testable import Owlet

final class EngineProtocolTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Codable round-trips

    func test_hostMessages_roundTrip() throws {
        let messages: [HostMessage] = [
            .ping,
            .shutdown,
            .cancel(seq: 7),
            .contextUpdate(seq: 42, prefix: "the quick brown ", suffix: " jumps",
                           appID: "com.apple.TextEdit", trigger: .keystroke),
        ]
        for msg in messages {
            let data = try encoder.encode(msg)
            let back = try decoder.decode(HostMessage.self, from: data)
            XCTAssertEqual(msg, back)
        }
    }

    func test_engineMessages_roundTrip() throws {
        let messages: [EngineMessage] = [
            .pong,
            .suggestion(seq: 42, tier: .complete, text: "fox", replaceRange: nil),
            .suggestion(seq: 43, tier: .recorrect, text: "their", replaceRange: ReplaceRange(start: 4, end: 9)),
            .error(seq: 1, message: "boom"),
            .error(seq: nil, message: "no seq"),
        ]
        for msg in messages {
            let data = try encoder.encode(msg)
            let back = try decoder.decode(EngineMessage.self, from: data)
            XCTAssertEqual(msg, back)
        }
    }

    // MARK: - Wire shape matches the Rust side (proto.rs)

    func test_ping_wireShape() throws {
        let json = String(data: try encoder.encode(HostMessage.ping), encoding: .utf8)
        XCTAssertEqual(json, #"{"type":"Ping"}"#)
    }

    func test_suggestion_omitsNilReplaceRange() throws {
        let data = try encoder.encode(EngineMessage.suggestion(seq: 1, tier: .sentence, text: "hi", replaceRange: nil))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("replace_range"), "nil range must be omitted: \(json)")
    }

    func test_contextUpdate_usesSnakeCaseAppID() throws {
        let data = try encoder.encode(HostMessage.contextUpdate(
            seq: 1, prefix: "p", suffix: "", appID: "app", trigger: .pause))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""app_id":"app""#), json)
        XCTAssertTrue(json.contains(#""trigger":"Pause""#), json)
    }

    /// Decode bytes shaped exactly like what `owlet-engine` emits (verified against the
    /// real socket smoke), so a drift in either side's field names fails here.
    func test_decodesEngineWireVectors() throws {
        let pong = try decoder.decode(EngineMessage.self, from: Data(#"{"type":"Pong"}"#.utf8))
        XCTAssertEqual(pong, .pong)

        let suggestion = try decoder.decode(
            EngineMessage.self,
            from: Data(#"{"type":"Suggestion","seq":5,"tier":"Complete","text":"ng"}"#.utf8))
        XCTAssertEqual(suggestion, .suggestion(seq: 5, tier: .complete, text: "ng", replaceRange: nil))
    }

    func test_decodeUnknownTypeThrows() {
        XCTAssertThrowsError(try decoder.decode(EngineMessage.self, from: Data(#"{"type":"Nope"}"#.utf8)))
    }

    // MARK: - Framing

    func test_frameBuffer_assemblesMultipleFramesInOneChunk() throws {
        let messages: [EngineMessage] = [
            .pong,
            .suggestion(seq: 1, tier: .complete, text: "abc", replaceRange: nil),
            .error(seq: 2, message: "x"),
        ]
        var blob = Data()
        for msg in messages {
            blob.append(try EngineFraming.frame(encoder.encode(msg)))
        }
        let buffer = FrameBuffer()
        buffer.append(blob)
        var decoded: [EngineMessage] = []
        while let msg = try buffer.nextEngineMessage() { decoded.append(msg) }
        XCTAssertEqual(decoded, messages)
        XCTAssertNil(try buffer.nextEngineMessage())
    }

    func test_frameBuffer_survivesByteAtATime() throws {
        let msg = EngineMessage.suggestion(seq: 99, tier: .recorrect, text: "their",
                                           replaceRange: ReplaceRange(start: 0, end: 5))
        let framed = try EngineFraming.frame(encoder.encode(msg))
        let buffer = FrameBuffer()
        for byte in framed.dropLast() {
            buffer.append(Data([byte]))
            XCTAssertNil(try buffer.nextEngineMessage(), "must not decode before the last byte arrives")
        }
        buffer.append(Data([framed.last!]))
        XCTAssertEqual(try buffer.nextEngineMessage(), msg)
    }

    func test_frameBuffer_rejectsOversizedLength() {
        // A length prefix above the 4 MiB cap must throw, not allocate.
        let bogus = UInt32(EngineFraming.maxFrame + 1)
        let header = Data([
            UInt8((bogus >> 24) & 0xFF), UInt8((bogus >> 16) & 0xFF),
            UInt8((bogus >> 8) & 0xFF), UInt8(bogus & 0xFF),
        ])
        let buffer = FrameBuffer()
        buffer.append(header)
        XCTAssertThrowsError(try buffer.next())
    }

    func test_frame_roundTripThroughBuffer() throws {
        let payload = Data("hello".utf8)
        let framed = try EngineFraming.frame(payload)
        XCTAssertEqual(framed.count, 4 + payload.count)
        let buffer = FrameBuffer()
        buffer.append(framed)
        XCTAssertEqual(try buffer.next(), payload)
    }
}

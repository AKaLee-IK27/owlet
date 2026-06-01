import XCTest
@testable import Owlet

/// End-to-end check of `EngineClient`'s real POSIX socket path against the actual
/// `owlet-engine` binary: spawn it, connect, and round-trip framed messages. Skips
/// cleanly when the binary hasn't been built (e.g. a Swift-only CI lane), so it never
/// fails for a reason unrelated to the Host code.
final class EngineClientIntegrationTests: XCTestCase {

    private func engineBinaryURL() -> URL? {
        // #filePath = <repo>/Owlet/OwletTests/EngineClientIntegrationTests.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OwletTests
            .deletingLastPathComponent()  // Owlet
            .deletingLastPathComponent()  // <repo>
        let binary = repoRoot.appendingPathComponent("tools/engine/target/debug/owlet-engine")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }

    func test_realRoundTrip_pingAndTier0Completion() throws {
        guard let binary = engineBinaryURL() else {
            throw XCTSkip("owlet-engine not built — run `cd tools/engine && cargo build` to enable")
        }

        // Keep well under the 104-byte sun_path limit — NSTemporaryDirectory() +
        // a globally-unique string would overflow it (and trip the engine's guard).
        let socketPath = "/tmp/owlet-engine-it-\(getpid()).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--socket", socketPath]
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let client = EngineClient()
        defer { client.close() }

        // The engine binds asynchronously after launch; retry the connect briefly.
        var connected = false
        for _ in 0..<40 {
            if (try? client.connect(socketPath: socketPath)) != nil, client.isConnected {
                connected = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(connected, "could not connect to spawned owlet-engine")
        client.setReadTimeout(seconds: 3)

        try client.send(.ping)
        XCTAssertEqual(try client.readMessage(), .pong)

        // "becaus" → "e" from the embedded starter dictionary (Tier 0).
        try client.send(.contextUpdate(seq: 1, prefix: "becaus", suffix: "",
                                        appID: "test", trigger: .keystroke))
        XCTAssertEqual(try client.readMessage(),
                       .suggestion(seq: 1, tier: .complete, text: "e", replaceRange: nil))

        try client.send(.shutdown)
    }
}

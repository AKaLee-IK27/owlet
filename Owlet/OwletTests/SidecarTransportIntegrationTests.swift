import XCTest
@testable import Owlet

/// End-to-end check of the full streaming stack: SidecarTransport spawns the real
/// `owlet-engine` via its supervisor, connects over UDS, and streams a Tier 0
/// suggestion back through the background reader to `onSuggestion`. Skips when the
/// engine binary hasn't been built.
final class SidecarTransportIntegrationTests: XCTestCase {

    private func engineBinaryURL() -> URL? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OwletTests
            .deletingLastPathComponent()  // Owlet
            .deletingLastPathComponent()  // <repo>
        let binary = repoRoot.appendingPathComponent("tools/engine/target/debug/owlet-engine")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }

    func test_streamsTier0SuggestionFromRealEngine() async throws {
        guard let binary = engineBinaryURL() else {
            throw XCTSkip("owlet-engine not built — run `cd tools/engine && cargo build` to enable")
        }
        let socketPath = "/tmp/owlet-sidecar-it-\(getpid()).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        let config = EngineSupervisor.Config(executableURL: binary, socketPath: socketPath)

        let ready = expectation(description: "engine handshake (Pong)")
        ready.assertForOverFulfill = false
        let got = expectation(description: "tier0 suggestion streamed back")
        got.assertForOverFulfill = false

        let transport = await MainActor.run { () -> SidecarTransport in
            let t = SidecarTransport(config: config)
            t.onReady = { ready.fulfill() }
            t.onSuggestion = { seq, suggestion in
                if seq == 1, suggestion.tier == .complete, suggestion.text == "e" { got.fulfill() }
            }
            t.start()
            return t
        }

        await fulfillment(of: [ready], timeout: 8)
        await MainActor.run {
            transport.updateContext(ContextRequest(
                seq: 1, prefix: "becaus", suffix: "", appID: "test",
                trigger: .keystroke, model: "m", maxTokens: 18))
        }
        await fulfillment(of: [got], timeout: 8)
        await MainActor.run { transport.stop() }
    }
}

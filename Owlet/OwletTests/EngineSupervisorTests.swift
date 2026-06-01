import XCTest
@testable import Owlet

@MainActor
final class EngineSupervisorTests: XCTestCase {

    /// A fake engine process whose termination the test drives explicitly.
    final class FakeHandle: EngineProcessHandle {
        var onTerminate: (@MainActor () -> Void)?
        private(set) var terminateCalled = false
        func terminate() { terminateCalled = true }
        @MainActor func simulateExit() { onTerminate?() }
    }

    private func makeConfig() -> EngineSupervisor.Config {
        EngineSupervisor.Config(executableURL: URL(fileURLWithPath: "/fake/owlet-engine"),
                                socketPath: "/tmp/fake-owlet/engine.sock")
    }

    func test_startUnlinksStaleSocketThenSpawns() {
        var unlinked: [String] = []
        var lastHandle: FakeHandle?
        let supervisor = EngineSupervisor(
            config: makeConfig(),
            launch: { _ in let h = FakeHandle(); lastHandle = h; return h },
            unlinkSocket: { unlinked.append($0) },
            scheduleRespawn: { $0() })

        supervisor.start()

        XCTAssertEqual(unlinked, ["/tmp/fake-owlet/engine.sock"], "must unlink before bind")
        XCTAssertEqual(supervisor.spawnCount, 1)
        XCTAssertTrue(supervisor.isRunning)
        XCTAssertNotNil(lastHandle)
    }

    func test_unexpectedTerminationRespawns() {
        var unlinkCount = 0
        var handles: [FakeHandle] = []
        let supervisor = EngineSupervisor(
            config: makeConfig(),
            launch: { _ in let h = FakeHandle(); handles.append(h); return h },
            unlinkSocket: { _ in unlinkCount += 1 },
            scheduleRespawn: { $0() }) // respawn synchronously

        supervisor.start()
        XCTAssertEqual(supervisor.spawnCount, 1)

        handles[0].simulateExit() // engine crashed

        XCTAssertEqual(supervisor.spawnCount, 2, "crash should trigger a respawn")
        XCTAssertEqual(unlinkCount, 2, "each respawn unlinks the stale socket again")
        XCTAssertTrue(supervisor.isRunning)
    }

    func test_stopPreventsRespawn() {
        var handles: [FakeHandle] = []
        let supervisor = EngineSupervisor(
            config: makeConfig(),
            launch: { _ in let h = FakeHandle(); handles.append(h); return h },
            unlinkSocket: { _ in },
            scheduleRespawn: { $0() })

        supervisor.start()
        supervisor.stop()

        XCTAssertTrue(handles[0].terminateCalled, "stop must terminate the running process")
        XCTAssertFalse(supervisor.isRunning)

        // A late termination callback from the now-dead process must not respawn.
        handles[0].simulateExit()
        XCTAssertEqual(supervisor.spawnCount, 1)
        XCTAssertFalse(supervisor.isRunning)
    }

    func test_launchFailureSchedulesRetryThenSucceeds() {
        var attempts = 0
        let supervisor = EngineSupervisor(
            config: makeConfig(),
            launch: { _ in
                attempts += 1
                if attempts == 1 { throw NSError(domain: "test", code: 1) }
                return FakeHandle()
            },
            unlinkSocket: { _ in },
            scheduleRespawn: { $0() }) // run the scheduled retry immediately

        supervisor.start()

        XCTAssertEqual(attempts, 2, "a failed launch should be retried")
        XCTAssertEqual(supervisor.spawnCount, 1, "spawnCount counts successful launches only")
        XCTAssertTrue(supervisor.isRunning)
    }

    func test_doubleStartDoesNotSpawnTwice() {
        let supervisor = EngineSupervisor(
            config: makeConfig(),
            launch: { _ in FakeHandle() },
            unlinkSocket: { _ in },
            scheduleRespawn: { $0() })

        supervisor.start()
        supervisor.start() // idempotent while already running

        XCTAssertEqual(supervisor.spawnCount, 1)
    }
}

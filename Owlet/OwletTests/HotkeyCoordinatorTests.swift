import XCTest
@testable import Owlet

final class HotkeyCoordinatorTests: XCTestCase {

    func test_debounce_collapsesRapidFires() async throws {
        actor Counter { var v = 0; func inc() { v += 1 } }
        let counter = Counter()
        let coord = HotkeyCoordinator(debounceMs: 100) {
            Task { await counter.inc() }
        }
        coord.trigger(); coord.trigger(); coord.trigger()
        try await Task.sleep(nanoseconds: 250_000_000)   // 250 ms
        let observed = await counter.v
        XCTAssertEqual(observed, 1, "expected debounce to collapse 3 → 1, got \(observed)")
    }

    func test_secondFireAfterDebounce_runsAgain() async throws {
        actor Counter { var v = 0; func inc() { v += 1 } }
        let counter = Counter()
        let coord = HotkeyCoordinator(debounceMs: 50) {
            Task { await counter.inc() }
        }
        coord.trigger()
        try await Task.sleep(nanoseconds: 150_000_000)
        coord.trigger()
        try await Task.sleep(nanoseconds: 150_000_000)
        let observed = await counter.v
        XCTAssertEqual(observed, 2)
    }
}

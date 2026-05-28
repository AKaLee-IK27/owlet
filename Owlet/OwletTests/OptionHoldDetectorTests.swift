import XCTest
@testable import Owlet

final class OptionHoldDetectorTests: XCTestCase {

    func test_fires_afterHoldThreshold() async {
        let expect = expectation(description: "hold triggered")
        let detector = OptionHoldDetector(holdThreshold: 0.05) {
            expect.fulfill()
        }
        let optionOnly = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        detector.handleKeyDown(flags: optionOnly)
        await fulfillment(of: [expect], timeout: 0.5)
    }

    func test_doesNotFire_beforeThreshold() {
        let fired = AtomicBool()
        let detector = OptionHoldDetector(holdThreshold: 10.0) {
            fired.value = true
        }
        let optionOnly = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        detector.handleKeyDown(flags: optionOnly)
        detector.cancel()
        XCTAssertFalse(fired.value)
    }

    func test_cancels_onOptionKeyUp() {
        let fired = AtomicBool()
        let detector = OptionHoldDetector(holdThreshold: 0.5) {
            fired.value = true
        }
        let optionOnly = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        detector.handleKeyDown(flags: optionOnly)
        detector.handleOptionKeyUp()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(fired.value)
    }

    func test_cancels_onOtherKeyDown() {
        let fired = AtomicBool()
        let detector = OptionHoldDetector(holdThreshold: 0.5) {
            fired.value = true
        }
        let optionOnly = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        detector.handleKeyDown(flags: optionOnly)
        detector.cancel()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(fired.value)
    }

    func test_ignores_nonOptionKeyDown() {
        let fired = AtomicBool()
        let detector = OptionHoldDetector(holdThreshold: 0.05) {
            fired.value = true
        }
        let cmdOnly = ModifierFlags(fn: false, ctrl: false, cmd: true, alt: false, shift: false)
        detector.handleKeyDown(flags: cmdOnly)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(fired.value)
    }

    func test_ignores_optionPlusOtherModifiers() {
        let fired = AtomicBool()
        let detector = OptionHoldDetector(holdThreshold: 0.05) {
            fired.value = true
        }
        let optionShift = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: true)
        detector.handleKeyDown(flags: optionShift)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(fired.value)
    }

    func test_rapidPresses_dontAccumulate() {
        let fireCount = AtomicInt()
        let detector = OptionHoldDetector(holdThreshold: 0.05) {
            fireCount.increment()
        }
        let optionOnly = ModifierFlags(fn: false, ctrl: false, cmd: false, alt: true, shift: false)
        detector.handleKeyDown(flags: optionOnly)
        detector.handleOptionKeyUp()
        detector.handleKeyDown(flags: optionOnly)
        detector.handleOptionKeyUp()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(fireCount.value, 0)
    }
}

/// Thread-safe boolean for use in concurrent test closures.
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    var value: Bool = false
}

/// Thread-safe integer for use in concurrent test closures.
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}

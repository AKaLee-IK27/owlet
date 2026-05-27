import XCTest
@testable import Owlet

final class PermissionCheckerTests: XCTestCase {

    private struct MockProbe: PermissionProbe {
        let ax: Bool
        let im: Bool
        func isAccessibilityGranted() -> Bool { ax }
        func isInputMonitoringGranted() -> Bool { im }
    }

    func test_bothGranted_returnsAllGranted() {
        let result = PermissionChecker.check(probe: MockProbe(ax: true, im: true))
        XCTAssertEqual(result, .allGranted)
    }

    func test_noneGranted_returnsBothMissing() {
        let result = PermissionChecker.check(probe: MockProbe(ax: false, im: false))
        XCTAssertEqual(result, .missing([.accessibility, .inputMonitoring]))
    }

    func test_onlyAXMissing() {
        let result = PermissionChecker.check(probe: MockProbe(ax: false, im: true))
        XCTAssertEqual(result, .missing([.accessibility]))
    }

    func test_onlyIMMissing() {
        let result = PermissionChecker.check(probe: MockProbe(ax: true, im: false))
        XCTAssertEqual(result, .missing([.inputMonitoring]))
    }
}

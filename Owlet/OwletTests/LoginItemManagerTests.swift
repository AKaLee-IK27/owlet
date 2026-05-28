import XCTest
import ServiceManagement
@testable import Owlet

final class LoginItemManagerTests: XCTestCase {

    func test_shouldRegister_whenStatusEnabled_returnsFalse() {
        XCTAssertFalse(LoginItemManager.shouldRegister(status: .enabled))
    }

    func test_shouldRegister_whenStatusNotRegistered_returnsTrue() {
        XCTAssertTrue(LoginItemManager.shouldRegister(status: .notRegistered))
    }

    func test_shouldRegister_whenStatusRequiresApproval_returnsTrue() {
        XCTAssertTrue(LoginItemManager.shouldRegister(status: .requiresApproval))
    }

    func test_shouldRegister_whenStatusNotFound_returnsTrue() {
        XCTAssertTrue(LoginItemManager.shouldRegister(status: .notFound))
    }

    // MARK: setRegistered / isRegistered (post v0.3)

    func test_isRegistered_matches_smAppService_enabled() {
        // Pure decision wrapper — we can't actually mutate SMAppService in a
        // unit test, but we can verify the boolean projection.
        XCTAssertTrue(LoginItemManager.isRegistered(status: .enabled))
        XCTAssertFalse(LoginItemManager.isRegistered(status: .notRegistered))
        XCTAssertFalse(LoginItemManager.isRegistered(status: .requiresApproval))
        XCTAssertFalse(LoginItemManager.isRegistered(status: .notFound))
    }
}

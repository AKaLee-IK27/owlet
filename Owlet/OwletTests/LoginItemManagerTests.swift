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
}

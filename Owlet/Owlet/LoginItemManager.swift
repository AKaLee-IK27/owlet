import Foundation
import ServiceManagement
import os.log

enum LoginItemManager {

    enum Failure: Error {
        case registerThrew(String)
        case unregisterThrew(String)
    }

    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "loginitem")

    /// Pure projection used by tests. The runtime call sites read
    /// `SMAppService.mainApp.status` directly via `currentlyRegistered()`.
    static func isRegistered(status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled: return true
        case .notRegistered, .requiresApproval, .notFound: return false
        @unknown default: return false
        }
    }

    /// Pure decision used by tests. Skip only if already enabled.
    static func shouldRegister(status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled: return false
        case .notRegistered, .requiresApproval, .notFound: return true
        @unknown default: return true
        }
    }

    /// Current registration status of the main app's login-item helper.
    static func currentlyRegistered() -> Bool {
        isRegistered(status: SMAppService.mainApp.status)
    }

    /// Apply the user's preference. Throws on failure so the Settings UI
    /// can surface the underlying error and revert the toggle.
    static func setRegistered(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            guard shouldRegister(status: service.status) else {
                logger.info("Login item already enabled, no-op")
                return
            }
            do { try service.register() } catch {
                logger.error("register() threw: \(error.localizedDescription, privacy: .public)")
                throw Failure.registerThrew(error.localizedDescription)
            }
            logger.info("Registered Owlet as a login item")
        } else {
            guard isRegistered(status: service.status) else {
                logger.info("Login item already not enabled, no-op")
                return
            }
            do { try service.unregister() } catch {
                logger.error("unregister() threw: \(error.localizedDescription, privacy: .public)")
                throw Failure.unregisterThrew(error.localizedDescription)
            }
            logger.info("Unregistered Owlet as a login item")
        }
    }
}

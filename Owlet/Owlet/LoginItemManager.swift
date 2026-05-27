import Foundation
import ServiceManagement
import os.log

enum LoginItemManager {
    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "loginitem")

    /// Pure decision: should we attempt to register based on current status?
    /// Only skip if already enabled — every other status is worth trying.
    static func shouldRegister(status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled: return false
        case .notRegistered, .requiresApproval, .notFound: return true
        @unknown default: return true  // optimistic; try registering on future cases
        }
    }

    /// Register Owlet as a login item if it's not already enabled.
    /// No-op (with logging) if registration fails. Doesn't throw — login item
    /// failure is non-fatal; the app still works for the current session.
    static func registerIfNeeded() {
        let service = SMAppService.mainApp
        guard shouldRegister(status: service.status) else {
            logger.info("Login item already enabled, skipping register")
            return
        }
        do {
            try service.register()
            logger.info("Registered Owlet as a login item")
        } catch {
            logger.error("Failed to register login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Exposed for a future settings UI. Not called in v0.2.
    static func unregister() {
        let service = SMAppService.mainApp
        do {
            try service.unregister()
        } catch {
            logger.error("Failed to unregister login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}

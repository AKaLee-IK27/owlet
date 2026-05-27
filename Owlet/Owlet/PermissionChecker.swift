import Foundation
import ApplicationServices
import IOKit.hid

enum Permission: String, Hashable, CaseIterable {
    case accessibility
    case inputMonitoring
}

enum PermissionStatus: Equatable {
    case allGranted
    case missing(Set<Permission>)
}

/// Test seam: production uses `SystemProbe`, tests inject a mock.
protocol PermissionProbe {
    func isAccessibilityGranted() -> Bool
    func isInputMonitoringGranted() -> Bool
}

struct SystemProbe: PermissionProbe {
    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }
    func isInputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
}

enum PermissionChecker {
    static func check(probe: PermissionProbe = SystemProbe()) -> PermissionStatus {
        var missing = Set<Permission>()
        if !probe.isAccessibilityGranted() { missing.insert(.accessibility) }
        if !probe.isInputMonitoringGranted() { missing.insert(.inputMonitoring) }
        return missing.isEmpty ? .allGranted : .missing(missing)
    }
}

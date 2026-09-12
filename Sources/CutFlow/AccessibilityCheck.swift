import AppKit
import ApplicationServices
import CutFlowCore

struct AccessibilityCheck {
    let reportedTrust: Bool
    let probe: AccessEvidence.Probe
    let detail: String

    static func read() -> AccessibilityCheck {
        let reported = AXIsProcessTrustedWithOptions(nil)
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return .init(reportedTrust: reported, probe: .unavailable, detail: "Finder 未运行")
        }
        let element = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        var role: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if result == .success, role as? String == kAXApplicationRole {
            return .init(reportedTrust: reported, probe: .allowed, detail: "实际调用成功")
        }
        if result == .apiDisabled {
            return .init(reportedTrust: reported, probe: .denied, detail: "系统拒绝当前进程（\(result.rawValue)）")
        }
        return .init(reportedTrust: reported, probe: .unavailable, detail: "暂时无法验证（\(result.rawValue)）")
    }
}

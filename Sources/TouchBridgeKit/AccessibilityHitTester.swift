import ApplicationServices
import CoreGraphics
import Foundation
import TouchBridgeCore

/// Accessibility hit test (AXUIElementCopyElementAtPosition) for smart target and the touch context menu.
/// Coordinates: global display space, origin top left of the main display (same as CGEvent).
public final class AXHitTester: AccessibilityProbe {
    private let system = AXUIElementCreateSystemWide()
    /// How many ancestors are checked when the element itself is not a control (text inside a button …)
    public var ancestorLevels = 2

    /// timeout: per AX message (seconds); keeps a hanging app from blocking the touch thread
    public init(timeout: Float = 0.05) {
        AXUIElementSetMessagingTimeout(system, timeout)
    }

    public func elementRef(at p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        let rc = AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &el)
        return rc == .success ? el : nil
    }

    public func element(at p: CGPoint) -> AXElementInfo? {
        guard let el = elementRef(at: p) else { return nil }
        return info(of: el)
    }

    public func info(of el: AXUIElement) -> AXElementInfo {
        let role = string(el, kAXRoleAttribute) ?? "AXUnknown"
        var info = AXElementInfo(role: role, frame: frame(of: el))
        // Controls are decided by role alone – saves IPC round trips on the hot path
        if SmartTarget.actionableRoles.contains(role) { return info }
        info.actions = actions(of: el)
        if !SmartTarget.containerRoles.contains(role) {
            var cur = el
            for _ in 0..<ancestorLevels {
                guard let parent = element(cur, kAXParentAttribute) else { break }
                let r = string(parent, kAXRoleAttribute) ?? "AXUnknown"
                info.ancestorRoles.append(r)
                if SmartTarget.actionableRoles.contains(r) || SmartTarget.containerRoles.contains(r) { break }
                cur = parent
            }
        }
        return info
    }

    public func actions(of el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let a = names as? [String] else { return [] }
        return a
    }

    @discardableResult
    public func perform(_ action: String, on el: AXUIElement) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
    }

    public func actionDescription(_ action: String, of el: AXUIElement) -> String? {
        var d: CFString?
        guard AXUIElementCopyActionDescription(el, action as CFString, &d) == .success, let s = d.map({ $0 as String }), !s.isEmpty else { return nil }
        return s
    }

    public func frame(of el: AXUIElement) -> CGRect? {
        guard let pv = value(el, kAXPositionAttribute), let sv = value(el, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &pt), AXValueGetValue(sv, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private func raw(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private func string(_ el: AXUIElement, _ attr: String) -> String? { raw(el, attr) as? String }

    private func value(_ el: AXUIElement, _ attr: String) -> AXValue? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    private func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}

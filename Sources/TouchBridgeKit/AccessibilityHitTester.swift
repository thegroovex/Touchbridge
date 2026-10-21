import ApplicationServices
import CoreGraphics
import Foundation
import TouchBridgeCore

/// Accessibility hit test (AXUIElementCopyElementAtPosition) for smart target and the touch context menu.
/// Coordinates: global display space, origin top left of the main display (same as CGEvent).
///
/// Threading: AX calls are synchronous IPC to the target app and can block for the whole messaging timeout
/// (e.g. while the app tracks a context menu it does not answer). Use instances only from one dedicated serial
/// queue, never from the main thread or the touch engine.
///
/// Timeouts: a timeout set on the system-wide element is process-global (it applies to every element without its
/// own timeout), so several testers would overwrite each other. Each tester therefore sets the global value right
/// before its own hit test (safe because all testers share one serial queue) and sets its timeout on every element
/// it hands out, so later calls on that element (actions, attributes, AXShowMenu) use the per-element timeout.
public final class AXHitTester: AccessibilityProbe {
    private let system = AXUIElementCreateSystemWide()
    /// How many ancestors are checked when the element itself is not a control (text inside a button …)
    public var ancestorLevels = 2
    /// Per AX message (seconds)
    public let timeout: Float

    /// timeout: per AX message (seconds); keeps a hanging app from blocking the caller for long
    public init(timeout: Float = 0.05) {
        self.timeout = timeout
    }

    public func elementRef(at p: CGPoint) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(system, timeout)
        var el: AXUIElement?
        let rc = AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &el)
        guard rc == .success, let e = el else { return nil }
        AXUIElementSetMessagingTimeout(e, timeout)
        return e
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

    /// Performs an AX action with a per-element timeout (default: this tester's timeout). Apps that track a
    /// menu inside the action handler answer only when it closes – the call then returns .cannotComplete.
    @discardableResult
    public func perform(_ action: String, on el: AXUIElement, timeout: Float? = nil) -> AXError {
        AXUIElementSetMessagingTimeout(el, timeout ?? self.timeout)
        return AXUIElementPerformAction(el, action as CFString)
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
        let e = v as! AXUIElement
        AXUIElementSetMessagingTimeout(e, timeout)
        return e
    }
}

/// On-screen popup menus via CGWindowListCopyWindowInfo (cheap, no AX, safe on the main thread).
public enum PopupMenuScanner {
    public static func current() -> [PopupMenuWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let layer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return PopupMenus.windows(in: list, popupLayer: layer)
    }
}

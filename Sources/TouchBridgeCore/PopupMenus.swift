import CoreGraphics
import Foundation

/// An on-screen popup/context menu window (from CGWindowListCopyWindowInfo).
public struct PopupMenuWindow: Equatable {
    public var number: Int
    public var ownerPID: Int
    /// Global coordinates, origin top left of the main display (same space as CGEvent)
    public var frame: CGRect

    public init(number: Int, ownerPID: Int, frame: CGRect) {
        self.number = number
        self.ownerPID = ownerPID
        self.frame = frame
    }
}

/// Finds open menus in a window list. Pure logic so it can be tested without a window server.
public enum PopupMenus {
    /// kCGPopUpMenuWindowLevel (CGWindowLevelForKey(.popUpMenuWindow)); context menus, menu bar menus,
    /// NSMenu.popUp – all live on this layer.
    public static let popUpMenuLayer = 101
    /// Smaller windows on that layer are not menus (e.g. leftovers of a closing animation)
    public static let minSize = CGSize(width: 24, height: 16)

    /// window info dictionaries as returned by CGWindowListCopyWindowInfo (keys kCGWindowLayer, kCGWindowBounds …)
    public static func windows(in info: [[String: Any]], popupLayer: Int = popUpMenuLayer) -> [PopupMenuWindow] {
        info.compactMap { w in
            guard (w["kCGWindowLayer"] as? Int) == popupLayer else { return nil }
            if let alpha = w["kCGWindowAlpha"] as? Double, alpha <= 0.01 { return nil }
            if let onScreen = w["kCGWindowIsOnscreen"] as? Bool, !onScreen { return nil }
            guard let b = w["kCGWindowBounds"] as? [String: Any], let r = rect(b),
                  r.width >= minSize.width, r.height >= minSize.height else { return nil }
            return PopupMenuWindow(number: w["kCGWindowNumber"] as? Int ?? 0,
                                   ownerPID: w["kCGWindowOwnerPID"] as? Int ?? 0, frame: r)
        }
    }

    /// Menus from `before` that are still on screen in `after` (same window number)
    public static func stillOpen(_ before: [PopupMenuWindow], in after: [PopupMenuWindow]) -> [PopupMenuWindow] {
        let numbers = Set(after.map(\.number))
        return before.filter { numbers.contains($0.number) }
    }

    private static func rect(_ b: [String: Any]) -> CGRect? {
        func num(_ k: String) -> CGFloat? {
            if let d = b[k] as? Double { return CGFloat(d) }
            if let i = b[k] as? Int { return CGFloat(i) }
            if let n = b[k] as? NSNumber { return CGFloat(n.doubleValue) }
            return nil
        }
        guard let x = num("X"), let y = num("Y"), let w = num("Width"), let h = num("Height") else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

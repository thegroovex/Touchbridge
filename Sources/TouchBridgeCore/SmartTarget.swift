import CoreGraphics
import Foundation

/// What the accessibility hit test found at a point (global display coordinates, origin top left).
public struct AXElementInfo: Equatable {
    public var role: String
    public var actions: [String]
    public var frame: CGRect?
    /// Roles of the nearest ancestors (parent first), at most a few levels
    public var ancestorRoles: [String]

    public init(role: String, actions: [String] = [], frame: CGRect? = nil, ancestorRoles: [String] = []) {
        self.role = role; self.actions = actions; self.frame = frame; self.ancestorRoles = ancestorRoles
    }
}

/// Accessibility lookup (TouchBridgeKit: AXUIElementCopyElementAtPosition; tests: a fake).
public protocol AccessibilityProbe: AnyObject {
    func element(at point: CGPoint) -> AXElementInfo?
}

public struct SmartTargetConfig: Equatable {
    public init(radius: CGFloat = 10) { self.radius = radius }
    /// Search radius around the finger (points)
    public var radius: CGFloat
    /// Upper bound for hit tests besides the one at the finger
    public var maxSamples = 12
    /// Time budget for the whole lookup (seconds)
    public var budget: Double = 0.005
    /// Elements up to this size are clicked in their centre; larger ones (text fields, lists) at the nearest inner point
    public var centreMaxSize: CGFloat = 64
    /// Distance kept from the edge of large elements
    public var inset: CGFloat = 3
}

/// Smart target: a tap that lands next to a control snaps onto it. Pure selection logic; the AX lookup sits behind
/// AccessibilityProbe.
public enum SmartTarget {
    /// Controls a tap is meant for
    public static let actionableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuButton",
        "AXPopUpButton", "AXComboBox", "AXTab", "AXTextField", "AXSearchField", "AXSecureTextField", "AXSlider",
        "AXIncrementor", "AXStepper", "AXDisclosureTriangle", "AXColorWell", "AXDockItem", "AXSegmentedControl",
        "AXToolbarButton", "AXSwitch", "AXToggle",
    ]
    /// Background / containers: tapping these means "probably missed a control"
    public static let containerRoles: Set<String> = [
        "AXGroup", "AXWindow", "AXScrollArea", "AXSplitGroup", "AXSplitter", "AXLayoutArea", "AXLayoutItem",
        "AXApplication", "AXUnknown", "AXSheet", "AXDrawer", "AXToolbar", "AXTabGroup", "AXRadioGroup",
        "AXWebArea", "AXMenuBar", "AXMenu", "AXGrowArea", "AXMatte", "AXRuler", "AXList", "AXOutline", "AXTable",
        "AXBrowser", "AXScrollBar", "AXValueIndicator",
    ]
    /// Content where the exact tap position matters (text, table rows): never moved
    public static let contentRoles: Set<String> = [
        "AXTextArea", "AXCell", "AXRow", "AXColumn", "AXOutlineRow", "AXHeading", "AXDateField", "AXTimeField",
    ]

    public static func isActionable(_ e: AXElementInfo) -> Bool {
        if actionableRoles.contains(e.role) { return true }
        if e.ancestorRoles.contains(where: { actionableRoles.contains($0) }) { return true }
        return !containerRoles.contains(e.role) && e.actions.contains("AXPress")
    }

    /// Leave the tap where it is: on a control, or on content where the position matters
    public static func keepsTap(_ e: AXElementInfo) -> Bool {
        if isActionable(e) || contentRoles.contains(e.role) { return true }
        return e.ancestorRoles.contains { contentRoles.contains($0) }
    }

    /// Sample points ordered by distance: 8 points at radius/2, then the 4 axis points at radius, then the diagonals.
    public static func samplePoints(around p: CGPoint, radius: CGFloat, maxSamples: Int) -> [CGPoint] {
        guard radius > 0, maxSamples > 0 else { return [] }
        let d = CGFloat(0.70710678)
        let axis: [(CGFloat, CGFloat)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        let diag: [(CGFloat, CGFloat)] = [(d, d), (-d, d), (d, -d), (-d, -d)]
        var out: [CGPoint] = []
        let rings: [([(CGFloat, CGFloat)], CGFloat)] = [(axis + diag, radius / 2), (axis, radius), (diag, radius)]
        for ring in rings {
            for dir in ring.0 { out.append(CGPoint(x: p.x + dir.0 * ring.1, y: p.y + dir.1 * ring.1)) }
        }
        return Array(out.prefix(maxSamples))
    }

    /// Distance from a point to a rectangle (0 inside)
    public static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// Click point inside an element: centre for small controls, nearest inner point for large ones
    public static func snapPoint(for frame: CGRect, from p: CGPoint, config: SmartTargetConfig) -> CGPoint {
        if frame.width <= config.centreMaxSize && frame.height <= config.centreMaxSize {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        let ix = min(config.inset, frame.width / 2), iy = min(config.inset, frame.height / 2)
        let r = frame.insetBy(dx: ix, dy: iy)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    public struct Result: Equatable {
        public var point: CGPoint
        /// Role of the element snapped to (nil = unchanged)
        public var role: String?
        public var probes: Int
        public var snapped: Bool { role != nil }
    }

    /// Where to click for a tap at `p`. Returns `p` unchanged when the finger is on a control / content, when
    /// nothing actionable is within the radius, or when the time budget runs out before anything was found.
    public static func resolve(_ p: CGPoint, probe: AccessibilityProbe, config: SmartTargetConfig,
                               clock: () -> Double = { CFAbsoluteTimeGetCurrent() }) -> Result {
        let start = clock()
        var probes = 1
        guard let centre = probe.element(at: p) else { return Result(point: p, role: nil, probes: probes) }
        if keepsTap(centre) { return Result(point: p, role: nil, probes: probes) }

        // Frames of leaf elements already examined: a sample inside one would hit it again. Containers are not
        // recorded – their children sit on top of them.
        var seen: [CGRect] = []
        func remember(_ e: AXElementInfo) {
            if let f = e.frame, !containerRoles.contains(e.role) { seen.append(f) }
        }
        remember(centre)
        var best: (dist: CGFloat, point: CGPoint, role: String)?
        var bestRing: CGFloat?
        for s in samplePoints(around: p, radius: config.radius, maxSamples: config.maxSamples) {
            let ring = hypot(s.x - p.x, s.y - p.y)
            // a hit is never improved by samples further out than the ring it was found on
            if let r = bestRing, ring > r + 0.01 { break }
            if clock() - start > config.budget { break }
            // the element at this sample was already examined
            if seen.contains(where: { $0.contains(s) }) { continue }
            probes += 1
            guard let e = probe.element(at: s) else { continue }
            remember(e)
            guard isActionable(e) else { continue }
            let frame = e.frame
            let dist = frame.map { distance(from: p, to: $0) } ?? ring
            guard dist <= config.radius + 0.01 else { continue }
            if best == nil || dist < best!.dist {
                let target = frame.map { snapPoint(for: $0, from: p, config: config) } ?? s
                best = (dist, target, e.role)
                if bestRing == nil { bestRing = ring }
            }
        }
        guard let b = best else { return Result(point: p, role: nil, probes: probes) }
        return Result(point: b.point, role: b.role, probes: probes)
    }
}

// MARK: - Touch context menu

/// Entries of the touch context menu (built when the element does not offer its own menu)
public enum TouchMenuEntry: Equatable {
    case axAction(String)
    case copy, paste, rightClick

    public var title: String {
        switch self {
        case .axAction(let a): return TouchContextMenuModel.title(for: a)
        case .copy: return L("Copy", "Kopieren")
        case .paste: return L("Paste", "Einsetzen")
        case .rightClick: return L("Right click", "Rechtsklick")
        }
    }
}

public enum TouchContextMenuModel {
    public static let showMenu = "AXShowMenu"
    /// AX actions offered as menu rows, in this order
    public static let actionOrder = ["AXPress", "AXConfirm", "AXPick", "AXOpen", "AXIncrement", "AXDecrement",
                                     "AXRaise", "AXShowAlternateUI", "AXShowDefaultUI", "AXCancel"]

    /// The element brings its own context menu
    public static func prefersShowMenu(_ actions: [String]) -> Bool { actions.contains(showMenu) }

    public static func entries(actions: [String]) -> [TouchMenuEntry] {
        let known = actionOrder.filter { actions.contains($0) }.map { TouchMenuEntry.axAction($0) }
        return known + [.copy, .paste, .rightClick]
    }

    public static func title(for action: String) -> String {
        switch action {
        case "AXPress": return L("Press", "Drücken")
        case "AXConfirm": return L("Confirm", "Bestätigen")
        case "AXPick": return L("Select", "Auswählen")
        case "AXOpen": return L("Open", "Öffnen")
        case "AXIncrement": return L("Increase", "Erhöhen")
        case "AXDecrement": return L("Decrease", "Verringern")
        case "AXRaise": return L("Bring to front", "Nach vorne holen")
        case "AXShowAlternateUI": return L("Show more", "Mehr anzeigen")
        case "AXShowDefaultUI": return L("Show less", "Weniger anzeigen")
        case "AXCancel": return L("Cancel", "Abbrechen")
        case "AXShowMenu": return L("Show menu", "Menü anzeigen")
        default: return action.hasPrefix("AX") ? String(action.dropFirst(2)) : action
        }
    }
}

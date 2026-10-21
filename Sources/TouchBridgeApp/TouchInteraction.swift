import AppKit
import ApplicationServices
import TouchBridgeCore
import TouchBridgeKit

/// GestureEngine delegate of the app: touch context menu on long press and smart target for taps.
final class TouchInteraction: NSObject, GestureEngineDelegate {
    private let settings: () -> TouchSettings
    private let log: (String) -> Void
    /// Short timeout: smart target runs on every tap
    private let tapProbe = AXHitTester(timeout: 0.03)
    private let menuProbe = AXHitTester(timeout: 0.25)
    private let poster = EventPoster()
    private var trusted = AXIsProcessTrusted()
    private var trustedChecked = CFAbsoluteTimeGetCurrent()
    /// Element and point of the open touch menu
    private var menuElement: AXUIElement?
    private var menuPoint = CGPoint.zero

    init(settings: @escaping () -> TouchSettings, log: @escaping (String) -> Void) {
        self.settings = settings
        self.log = log
    }

    /// AXIsProcessTrusted, refreshed at most every 3 s (taps are hot path)
    private var accessibilityTrusted: Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - trustedChecked > 3 { trusted = AXIsProcessTrusted(); trustedChecked = now }
        return trusted
    }

    // MARK: - Smart target

    func tapTarget(for point: CGPoint) -> CGPoint {
        let s = settings()
        guard s.smartTarget, accessibilityTrusted else { return point }
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = SmartTarget.resolve(point, probe: tapProbe, config: SmartTargetConfig(radius: CGFloat(s.smartTargetRadius)))
        if r.snapped {
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            log(String(format: "🎯 Smart target: (%.0f,%.0f) -> (%.0f,%.0f) %@, %d probes, %.1f ms",
                       point.x, point.y, r.point.x, r.point.y, r.role ?? "?", r.probes, ms))
        }
        return r.point
    }

    // MARK: - Touch context menu

    func onLongPress(at point: CGPoint) -> Bool {
        let s = settings()
        guard s.contextMenu, accessibilityTrusted else { return false }   // engine sends a right click
        guard let el = menuProbe.elementRef(at: point) else {
            log("📋 Touch menu: no accessibility element at \(Int(point.x)),\(Int(point.y)) – right click")
            return false
        }
        let actions = menuProbe.actions(of: el)
        // Async: never block the engine's tick; menu tracking runs its own loop
        DispatchQueue.main.async { [weak self] in self?.present(el, actions: actions, at: point) }
        return true
    }

    private func present(_ el: AXUIElement, actions: [String], at point: CGPoint) {
        if TouchContextMenuModel.prefersShowMenu(actions) {
            let rc = menuProbe.perform(TouchContextMenuModel.showMenu, on: el)
            // Apps that track their menu inside the action handler only answer after it closes -> timeout
            if rc == .success || rc == .cannotComplete {
                log("📋 Touch menu: AXShowMenu (\(rc == .success ? "ok" : "no reply, assuming shown"))")
                return
            }
            log("📋 Touch menu: AXShowMenu failed (\(rc.rawValue)) – own menu")
        }
        showOwnMenu(el, actions: actions, at: point)
    }

    private func showOwnMenu(_ el: AXUIElement, actions: [String], at point: CGPoint) {
        menuElement = el
        menuPoint = point
        let menu = NSMenu()
        menu.autoenablesItems = false
        let font = NSFont.systemFont(ofSize: 20)
        menu.font = font
        menu.minimumWidth = 240
        for (i, entry) in TouchContextMenuModel.entries(actions: actions).enumerated() {
            if entry == .copy && i > 0 { menu.addItem(.separator()) }
            var title = entry.title
            if case .axAction(let a) = entry, TouchContextMenuModel.title(for: a) == String(a.dropFirst(2)),
               let d = menuProbe.actionDescription(a, of: el) {
                title = d.prefix(1).uppercased() + d.dropFirst()
            }
            let item = NSMenuItem(title: title, action: #selector(menuChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.representedObject = entry.storageKey
            // large rows for fingers
            item.attributedTitle = NSAttributedString(string: "  " + title + "  ", attributes: [.font: font])
            menu.addItem(item)
        }
        log("📋 Touch menu: own menu with \(menu.items.filter { !$0.isSeparatorItem }.count) entries")
        // NSMenu uses bottom-left screen coordinates; open slightly right/below the finger so it stays visible
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let loc = NSPoint(x: point.x + 14, y: primaryHeight - point.y - 14)
        menu.popUp(positioning: nil, at: loc, in: nil)
    }

    @objc private func menuChosen(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let entry = TouchMenuEntry(storageKey: key) else { return }
        let p = menuPoint
        let el = menuElement
        menuElement = nil
        // let the menu close before events are posted
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            switch entry {
            case .axAction(let a):
                if let el = el {
                    let rc = self.menuProbe.perform(a, on: el)
                    if rc != .success { self.log("📋 Touch menu: \(a) failed (\(rc.rawValue))") }
                }
            case .copy:
                self.poster.key(KeyLayout.shared.code(for: ["c"]) ?? 8, flags: .maskCommand)
            case .paste:
                self.poster.click(p, right: false, clicks: 1)
                self.poster.key(KeyLayout.shared.code(for: ["v"]) ?? 9, flags: .maskCommand)
            case .rightClick:
                self.poster.click(p, right: true, clicks: 1)
            }
        }
    }
}

private extension TouchMenuEntry {
    var storageKey: String {
        switch self {
        case .axAction(let a): return a
        case .copy: return "#copy"
        case .paste: return "#paste"
        case .rightClick: return "#right"
        }
    }

    init?(storageKey k: String) {
        switch k {
        case "#copy": self = .copy
        case "#paste": self = .paste
        case "#right": self = .rightClick
        default: guard !k.isEmpty else { return nil }; self = .axAction(k)
        }
    }
}

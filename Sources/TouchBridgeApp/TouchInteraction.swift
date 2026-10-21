import AppKit
import ApplicationServices
import TouchBridgeCore
import TouchBridgeKit

/// GestureEngine delegate of the app: touch context menu on long press and smart target for taps.
///
/// All Accessibility IPC runs on one serial queue (`axQueue`), never on the main thread: the main run loop also
/// carries the HID callbacks and the engine tick. AX calls block for the full messaging timeout when the target
/// app does not answer – Chrome, for example, tracks the menu opened by AXShowMenu inside the action handler and
/// answers nothing until it closes. On the main thread that stalled touch delivery, late lifts turned taps into
/// long presses, and every long press then fell back to a right click.
final class TouchInteraction: NSObject, GestureEngineDelegate {
    private let settings: () -> TouchSettings
    private let log: (String) -> Void
    private let axQueue = DispatchQueue(label: "touchbridge.accessibility", qos: .userInitiated)
    /// Short timeout: smart target runs on every tap (axQueue only)
    private let tapProbe = AXHitTester(timeout: 0.03)
    /// Per-element timeout for hit test, action list and AXShowMenu (axQueue only)
    private let menuProbe = AXHitTester(timeout: 0.3)
    private let poster = EventPoster()
    private var trusted = AXIsProcessTrusted()
    private var trustedChecked = CFAbsoluteTimeGetCurrent()
    /// Element and point of the open own touch menu (main thread)
    private var menuElement: AXUIElement?
    private var menuPoint = CGPoint.zero
    /// A context-menu request is running on axQueue (main thread)
    private var menuJobActive = false
    /// Smart target: a hit test is still running on axQueue (guarded by lock)
    private let lock = NSLock()
    private var smartBusy = false
    /// How long a tap waits for smart target before clicking at the finger
    private let smartTargetWait: Double = 0.04

    init(settings: @escaping () -> TouchSettings, log: @escaping (String) -> Void) {
        self.settings = settings
        self.log = log
    }

    /// Log from axQueue: the app's log buffer belongs to the main thread
    private func logFromQueue(_ line: String) { DispatchQueue.main.async { [weak self] in self?.log(line) } }

    /// AXIsProcessTrusted, refreshed at most every 3 s (taps are hot path)
    private var accessibilityTrusted: Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - trustedChecked > 3 { trusted = AXIsProcessTrusted(); trustedChecked = now }
        return trusted
    }

    // MARK: - Smart target

    func tapTarget(for point: CGPoint) -> CGPoint {
        let s = settings()
        guard s.smartTarget, accessibilityTrusted, !menuJobActive else { return point }
        lock.lock()
        if smartBusy { lock.unlock(); return point }   // previous hit test still hanging – do not queue up
        smartBusy = true
        lock.unlock()
        final class Box { var result: SmartTarget.Result?; var ms = 0.0 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let config = SmartTargetConfig(radius: CGFloat(s.smartTargetRadius))
        axQueue.async { [weak self] in
            guard let self = self else { done.signal(); return }
            let t0 = CFAbsoluteTimeGetCurrent()
            let r = SmartTarget.resolve(point, probe: self.tapProbe, config: config)
            self.lock.lock()
            box.result = r
            box.ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            self.smartBusy = false
            self.lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + smartTargetWait) == .success else { return point }
        lock.lock()
        let r = box.result, ms = box.ms
        lock.unlock()
        guard let res = r else { return point }
        if res.snapped {
            log(String(format: "🎯 Smart target: (%.0f,%.0f) -> (%.0f,%.0f) %@, %d probes, %.1f ms",
                       point.x, point.y, res.point.x, res.point.y, res.role ?? "?", res.probes, ms))
        }
        return res.point
    }

    // MARK: - Open menus

    func openMenuFrames() -> [CGRect] { PopupMenuScanner.current().map(\.frame) }

    func tappedOutsideMenu(at point: CGPoint) {
        // The left click usually closes the menu; if it is still there after 150 ms, Escape closes it
        let before = PopupMenuScanner.current()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            let still = PopupMenus.stillOpen(before, in: PopupMenuScanner.current())
            guard !still.isEmpty else { return }
            self.log("📋 Menu still open after a tap outside it – sending Escape")
            self.poster.key(53, flags: [])   // kVK_Escape
        }
    }

    // MARK: - Touch context menu

    func onLongPress(at point: CGPoint) -> Bool {
        let s = settings()
        guard s.contextMenu, accessibilityTrusted else { return false }   // engine sends a right click
        if menuJobActive {
            log("📋 Touch menu: previous request still running – long press ignored")
            return true
        }
        menuJobActive = true
        // Everything AX happens on axQueue; the engine tick returns immediately
        axQueue.async { [weak self] in
            guard let self = self else { return }
            let el = self.menuProbe.elementRef(at: point)
            let actions = el.map { self.menuProbe.actions(of: $0) } ?? []
            var shown = false
            if let el = el, TouchContextMenuModel.prefersShowMenu(actions) {
                let rc = self.menuProbe.perform(TouchContextMenuModel.showMenu, on: el)
                // Apps that track their menu inside the action handler only answer after it closes -> timeout
                if rc == .success || rc == .cannotComplete {
                    self.logFromQueue("📋 Touch menu: AXShowMenu (\(rc == .success ? "ok" : "no reply within 0.3 s, assuming shown"))")
                    shown = true
                } else {
                    self.logFromQueue("📋 Touch menu: AXShowMenu failed (\(rc.rawValue)) – own menu")
                }
            }
            var titles: [String: String] = [:]
            if let el = el, !shown {
                for a in actions where TouchContextMenuModel.title(for: a) == String(a.dropFirst(2)) {
                    if let d = self.menuProbe.actionDescription(a, of: el) { titles[a] = d.prefix(1).uppercased() + d.dropFirst() }
                }
            }
            DispatchQueue.main.async {
                self.menuJobActive = false
                guard !shown else { return }
                guard let el = el else {
                    self.log("📋 Touch menu: no accessibility element at \(Int(point.x)),\(Int(point.y)) – right click")
                    self.poster.click(point, right: true, clicks: 1)
                    return
                }
                self.showOwnMenu(el, actions: actions, titles: titles, at: point)
            }
        }
        return true
    }

    /// Own large NSMenu (main thread; AX descriptions were fetched on axQueue)
    private func showOwnMenu(_ el: AXUIElement, actions: [String], titles: [String: String], at point: CGPoint) {
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
            if case .axAction(let a) = entry, let d = titles[a] { title = d }
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
                    self.axQueue.async {
                        let rc = self.menuProbe.perform(a, on: el)
                        if rc != .success { self.logFromQueue("📋 Touch menu: \(a) failed (\(rc.rawValue))") }
                    }
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

import AppKit
import TouchBridgeCore
import TouchBridgeKit

/// Counters for one phase of the test ("manual" or a probe variant)
struct TouchCounters {
    var viewDirect = 0, viewIndirect = 0, viewOther = 0
    var recognizerDirect = 0, recognizerIndirect = 0, recognizerOther = 0
    var pan = 0, magnification = 0, press = 0, click = 0
    var mouse = 0, scroll = 0, magnifyEvents = 0, rotateEvents = 0, swipeEvents = 0, smartMagnify = 0
    var eventTypes: [UInt: Int] = [:]

    var line: String {
        let types = eventTypes.sorted { $0.key < $1.key }.map { "\(TouchCounters.name($0.key))×\($0.value)" }.joined(separator: " ")
        return "view touches direct \(viewDirect) / indirect \(viewIndirect)" + (viewOther > 0 ? " / other \(viewOther)" : "")
            + " | recognizer touches direct \(recognizerDirect) / indirect \(recognizerIndirect)" + (recognizerOther > 0 ? " / other \(recognizerOther)" : "")
            + " | gestures pan \(pan) magnify \(magnification) press \(press) click \(click)"
            + " | mouse \(mouse) scroll \(scroll) magnifyEv \(magnifyEvents) rotateEv \(rotateEvents) swipeEv \(swipeEvents) smartMagnify \(smartMagnify)"
            + " | NSEvent types: " + (types.isEmpty ? "-" : types)
    }

    static func name(_ raw: UInt) -> String {
        switch raw {
        case 1: return "lDown"; case 2: return "lUp"; case 3: return "rDown"; case 4: return "rUp"; case 5: return "moved"
        case 6: return "lDrag"; case 22: return "scroll"; case 29: return "gesture"; case 30: return "magnify"
        case 31: return "swipe"; case 18: return "rotate"; case 19: return "beginGesture"; case 20: return "endGesture"
        case 32: return "smartMagnify"; case 34: return "pressure"; case 37: return "directTouch"; case 38: return "changeMode"
        default: return "t\(raw)"
        }
    }
}

/// View that accepts direct and indirect touches and counts everything it gets
final class TouchTestView: NSView {
    weak var controller: TouchTestController?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.direct, .indirect]
        wantsRestingTouches = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    private func count(_ e: NSEvent) {
        for t in e.touches(matching: .any, in: self) { controller?.countViewTouch(t.type) }
    }
    override func touchesBegan(with event: NSEvent) { count(event) }
    override func touchesMoved(with event: NSEvent) { count(event) }
    override func touchesEnded(with event: NSEvent) { count(event) }
    override func touchesCancelled(with event: NSEvent) { count(event) }
    override func mouseDown(with event: NSEvent) { controller?.bump { $0.mouse += 1 } }
    override func mouseDragged(with event: NSEvent) { controller?.bump { $0.mouse += 1 } }
    override func mouseUp(with event: NSEvent) { controller?.bump { $0.mouse += 1 } }
    override func rightMouseDown(with event: NSEvent) { controller?.bump { $0.mouse += 1 } }
    override func scrollWheel(with event: NSEvent) { controller?.bump { $0.scroll += 1 } }
    override func magnify(with event: NSEvent) { controller?.bump { $0.magnifyEvents += 1 } }
    override func rotate(with event: NSEvent) { controller?.bump { $0.rotateEvents += 1 } }
    override func swipe(with event: NSEvent) { controller?.bump { $0.swipeEvents += 1 } }
    override func smartMagnify(with event: NSEvent) { controller?.bump { $0.smartMagnify += 1 } }
}

/// "Touch Test" window: shows what AppKit delivers (direct/indirect NSTouch, gesture recognizers, mouse, NSEvent
/// types) per phase, optionally while the real-touch experiment runs. Results are appended to
/// Desktop/TouchBridge-RealTouch-Probe.txt.
final class TouchTestController: NSObject, NSWindowDelegate, NSGestureRecognizerDelegate {
    private(set) var window: NSWindow?
    private let view = TouchTestView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
    private let label = NSTextField(wrappingLabelWithString: "")
    private var monitor: Any?
    private var refreshTimer: Timer?
    private var dirty = true
    private(set) var phase = "manual"
    private var order: [String] = ["manual"]
    private var counters: [String: TouchCounters] = ["manual": TouchCounters()]
    var onRunProbe: (() -> Void)?
    var onClose: (() -> Void)?
    var extraInfo: () -> [String] = { [] }
    var probeRunning = false { didSet { runButton?.isEnabled = !probeRunning; dirty = true } }
    private weak var runButton: NSButton?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(on display: CGDirectDisplayID) {
        if window == nil { build() }
        guard let w = window else { return }
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }
            ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let size = NSSize(width: min(f.width * 0.8, 1100), height: min(f.height * 0.8, 760))
            w.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        WindowFront.bring(w)
        w.makeFirstResponder(view)
        startMonitoring()
    }

    /// Global CG rect (top-left origin) of the touch area – where the probe plays its gestures
    var touchRegionCG: CGRect? {
        guard let w = window, w.isVisible else { return nil }
        let r = w.convertToScreen(view.convert(view.bounds, to: nil))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height).insetBy(dx: r.width * 0.15, dy: r.height * 0.2)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L("TouchBridge – Touch Test", "TouchBridge – Touch-Test")
        w.isReleasedWhenClosed = false
        w.delegate = self
        view.controller = self

        let pan = NSPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        let mag = NSMagnificationGestureRecognizer(target: self, action: #selector(magnified(_:)))
        let press = NSPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        for g in [pan, mag, press, click] as [NSGestureRecognizer] {
            g.delegate = self
            g.allowedTouchTypes = [.direct, .indirect]
            view.addGestureRecognizer(g)
        }

        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(wrappingLabelWithString: L(
            "Touch, drag and pinch in this window (or run the experiment). Counters show what macOS delivers: direct = real screen touches, indirect = trackpad-style touches.",
            "In diesem Fenster tippen, ziehen und pinchen (oder das Experiment starten). Die Zähler zeigen, was macOS liefert: direct = echte Bildschirm-Touches, indirect = Trackpad-artige Touches."))
        hint.translatesAutoresizingMaskIntoConstraints = false
        let run = NSButton(title: L("Run real touch experiment", "Echtes-Touch-Experiment starten"), target: self, action: #selector(runProbe))
        let reset = NSButton(title: L("Reset counters", "Zähler zurücksetzen"), target: self, action: #selector(resetCounters))
        let save = NSButton(title: L("Save to desktop", "Auf Schreibtisch sichern"), target: self, action: #selector(saveAction))
        runButton = run
        let buttons = NSStackView(views: [run, reset, save])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for v in [hint, buttons, label, view] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            view.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        w.contentView = content
        window = w
    }

    private func startMonitoring() {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .any) { [weak self] e in
                if let self = self, e.window === self.window {
                    self.bump { $0.eventTypes[e.type.rawValue, default: 0] += 1 }
                }
                return e
            }
        }
        if refreshTimer == nil {
            let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        }
        dirty = true
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        onClose?()
    }

    // MARK: counting

    func bump(_ change: (inout TouchCounters) -> Void) {
        var c = counters[phase] ?? TouchCounters()
        change(&c)
        counters[phase] = c
        dirty = true
    }

    func countViewTouch(_ t: NSTouch.TouchType) {
        bump {
            switch t {
            case .direct: $0.viewDirect += 1
            case .indirect: $0.viewIndirect += 1
            default: $0.viewOther += 1
            }
        }
    }

    func setPhase(_ p: String?) {
        let name = p ?? "manual (after experiment)"
        phase = name
        if counters[name] == nil { counters[name] = TouchCounters(); order.append(name) }
        dirty = true
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        bump {
            switch touch.type {
            case .direct: $0.recognizerDirect += 1
            case .indirect: $0.recognizerIndirect += 1
            default: $0.recognizerOther += 1
            }
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }

    @objc private func panned(_ g: NSGestureRecognizer) { bump { $0.pan += 1 } }
    @objc private func magnified(_ g: NSGestureRecognizer) { bump { $0.magnification += 1 } }
    @objc private func pressed(_ g: NSGestureRecognizer) { bump { $0.press += 1 } }
    @objc private func clicked(_ g: NSGestureRecognizer) { bump { $0.click += 1 } }

    @objc private func runProbe() { onRunProbe?() }
    @objc private func resetCounters() {
        counters = ["manual": TouchCounters()]
        order = ["manual"]
        phase = "manual"
        dirty = true
    }
    @objc private func saveAction() {
        let text = report(title: "Touch Test window (manual save)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.joined(separator: "\n"), forType: .string)
        let err = RealTouchProbe.append(text)
        let a = NSAlert()
        if let err = err {
            a.messageText = L("Could not save the file", "Datei konnte nicht gesichert werden")
            a.informativeText = L("The results were copied to the clipboard – just paste them into the chat.\n\n", "Die Ergebnisse sind in der Zwischenablage – einfach in den Chat einfügen.\n\n") + err
        } else {
            a.messageText = L("Saved", "Gesichert")
            a.informativeText = L("Saved as \"TouchBridge-RealTouch-Probe.txt\" on the desktop and copied to the clipboard.", "Als „TouchBridge-RealTouch-Probe.txt“ auf dem Schreibtisch gesichert und in die Zwischenablage kopiert.")
        }
        a.runModal()
    }

    private func refresh() {
        guard dirty, window?.isVisible == true else { return }
        dirty = false
        var lines = [L("Phase: ", "Phase: ") + phase + (probeRunning ? L("  (experiment running – do not touch)", "  (Experiment läuft – nicht berühren)") : "")]
        for k in order { lines.append("[\(k)] " + (counters[k] ?? TouchCounters()).line) }
        lines.append("")
        lines.append(contentsOf: TouchTestController.screenInfo())
        lines.append(contentsOf: extraInfo())
        label.stringValue = lines.joined(separator: "\n")
    }

    /// Text block for the results file
    func report(title: String) -> [String] {
        var out = ["=== \(title) – TouchBridge \(Updater.currentVersion) – \(Date())",
                   "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for k in order { out.append("[\(k)] " + (counters[k] ?? TouchCounters()).line) }
        out.append(contentsOf: TouchTestController.screenInfo())
        out.append(contentsOf: extraInfo())
        return out
    }

    /// NSScreen touch capabilities – macOS 27 API (NSScreen.TouchCapabilities) probed dynamically, so it builds
    /// with older SDKs and runs on older systems.
    static func screenInfo() -> [String] {
        let selectors = ["touchCapabilities", "supportedTouchTypes", "isTouchCapable", "supportsTouch", "maximumTouchCount"]
        var out: [String] = []
        for s in NSScreen.screens {
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let name: String
            if #available(macOS 10.15, *) { name = s.localizedName } else { name = "Screen \(id)" }
            var caps: [String] = []
            for sel in selectors where s.responds(to: NSSelectorFromString(sel)) {
                // Only report presence: value(forKey:) raises for unknown struct return types
                caps.append("\(sel)=present")
            }
            out.append("Screen \(name) (id \(id)): " + (caps.isEmpty ? "no touch capability API" : caps.joined(separator: ", ")))
        }
        return out
    }
}

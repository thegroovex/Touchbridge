import AppKit
import TouchBridgeUSB
import TouchBridgeCore
import TouchBridgeKit

/// Counters for one phase of the test ("manual" or a probe variant)
struct TouchCounters {
    var viewDirect = 0, viewIndirect = 0, viewOther = 0
    var recognizerDirect = 0, recognizerIndirect = 0, recognizerOther = 0
    var pan = 0, magnification = 0, press = 0, click = 0
    var mouse = 0, scroll = 0, magnifyEvents = 0, rotateEvents = 0, swipeEvents = 0, smartMagnify = 0
    var eventTypes: [UInt: Int] = [:]
    /// Sums of NSEvent.rotation (degrees) and .magnification seen by the event monitor
    var rotationSum = 0.0, magnificationSum = 0.0, rotationZero = 0
    /// Rotation recognizer actions and recognizer values (largest absolute value, value at the last action)
    var rotation = 0
    var recRotationMax = 0.0, recRotationLast = 0.0, recMagnificationMax = 0.0, recMagnificationLast = 0.0, panTranslationMax = 0.0
    /// delegate gestureRecognizer(_:shouldReceive:) calls per recognizer and the most distinct touches seen at once
    var shouldReceiveByRecognizer: [String: Int] = [:]
    var delegateMaxSimultaneous = 0
    /// Custom NSGestureRecognizer subclass (touchesBegan/Moved/Ended/Cancelled): touch callbacks, touches by type,
    /// touches begun and the most fingers down at once
    var counterEvents = 0, counterDirect = 0, counterIndirect = 0, counterOther = 0, counterBegan = 0, counterMaxFingers = 0

    var line: String {
        let types = eventTypes.sorted { $0.key < $1.key }.map { "\(TouchCounters.name($0.key))×\($0.value)" }.joined(separator: " ")
        return "view touches direct \(viewDirect) / indirect \(viewIndirect)" + (viewOther > 0 ? " / other \(viewOther)" : "")
            + " | recognizer touches direct \(recognizerDirect) / indirect \(recognizerIndirect)" + (recognizerOther > 0 ? " / other \(recognizerOther)" : "")
            + " | gestures pan \(pan) magnify \(magnification) press \(press) click \(click)"
            + " | mouse \(mouse) scroll \(scroll) magnifyEv \(magnifyEvents) rotateEv \(rotateEvents) swipeEv \(swipeEvents) smartMagnify \(smartMagnify)"
            + " | NSEvent types: " + (types.isEmpty ? "-" : types)
            + String(format: " | rotation sum %.1f° (zero-valued %d) magnification sum %.3f", rotationSum, rotationZero, magnificationSum)
            + "\n    recognizer delegate shouldReceive: " + (shouldReceiveByRecognizer.isEmpty ? "-" :
                shouldReceiveByRecognizer.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
            + " | max simultaneous touches (delegate) \(delegateMaxSimultaneous)"
            + "\n    touch counter recognizer: callbacks \(counterEvents), touches direct \(counterDirect) / indirect \(counterIndirect)"
            + (counterOther > 0 ? " / other \(counterOther)" : "") + ", began \(counterBegan), max fingers \(counterMaxFingers)"
            + String(format: "\n    recognizer values: rotate actions %d, rotation max %.1f° last %.1f° | magnification max %.3f last %.3f | pan translation max %.0f pt",
                     rotation, recRotationMax, recRotationLast, recMagnificationMax, recMagnificationLast, panTranslationMax)
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

/// Passive NSGestureRecognizer subclass that only counts the NSTouches AppKit hands to gesture recognizers
/// (macOS 27 / TN3212: the only path for direct touches). It never begins, so it does not block other
/// recognizers; it fails once all fingers are lifted so it is reset for the next sequence.
final class TouchCountingRecognizer: NSGestureRecognizer {
    /// (touches by type in this callback, touches begun, fingers currently down)
    var onTouches: ((_ direct: Int, _ indirect: Int, _ other: Int, _ began: Int, _ down: Int) -> Void)?
    var onSequenceEnd: (() -> Void)?
    private var active = Set<Int>()
    private var lastWindowPoint: NSPoint?

    /// Required for NSGestureRecognizer subclasses with the macOS 27 SDK (otherwise NSZeroPoint + logged error)
    override func location(in view: NSView?) -> NSPoint {
        guard let p = lastWindowPoint else { return .zero }
        return view?.convert(p, from: nil) ?? p
    }

    private func handle(_ event: NSEvent) {
        var direct = 0, indirect = 0, other = 0, began = 0
        for t in event.touches(matching: .any, in: view) {
            switch t.type {
            case .direct: direct += 1; lastWindowPoint = t.location(in: nil)
            case .indirect: indirect += 1
            default: other += 1
            }
            let id = t.identity.hash
            if t.phase.contains(.began) { began += 1; active.insert(id) }
            if t.phase.contains(.ended) || t.phase.contains(.cancelled) { active.remove(id) }
            else if !t.phase.contains(.began) { active.insert(id) }
        }
        let touching = event.touches(matching: .touching, in: view).count
        onTouches?(direct, indirect, other, began, max(active.count, touching))
        if active.isEmpty && touching == 0 { finish() }
    }
    private func finish() {
        active.removeAll()
        onSequenceEnd?()
        if state == .possible { state = .failed }
    }
    override func touchesBegan(with event: NSEvent) { handle(event) }
    override func touchesMoved(with event: NSEvent) { handle(event) }
    override func touchesEnded(with event: NSEvent) { handle(event) }
    override func touchesCancelled(with event: NSEvent) { handle(event); finish() }
    override func mouseUp(with event: NSEvent) { if state == .possible { state = .failed } }
    override func reset() { active.removeAll(); super.reset() }
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
    /// Distinct touches seen by the recognizer delegate in the current touch sequence
    private var delegateTouchIDs = Set<Int>()
    private var lastDelegateTouch = Date.distantPast
    private var cancellableInfo = "-"

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
        let rot = NSRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        let counter = TouchCountingRecognizer(target: nil, action: nil)
        counter.onTouches = { [weak self] d, i, o, b, down in
            self?.bump {
                $0.counterEvents += 1; $0.counterDirect += d; $0.counterIndirect += i; $0.counterOther += o
                $0.counterBegan += b; $0.counterMaxFingers = max($0.counterMaxFingers, down)
            }
        }
        counter.onSequenceEnd = { [weak self] in self?.delegateTouchIDs.removeAll() }
        cancellableInfo = "not available (pre-macOS 27 AppKit)"
        var cancellable = 0
        for g in [pan, mag, press, click, rot, counter] as [NSGestureRecognizer] {
            g.delegate = self
            // Gesture recognizers reject .indirect (NSInternalInconsistencyException); allow direct only.
            if let err = tb_try({ g.allowedTouchTypes = [.direct] }) {
                NSLog("TouchBridge: direct touches not allowed for %@: %@", "\(type(of: g))", err)
            }
            // macOS 27: NSGestureRecognizer.isCancellableByScrollGesture (TN3212). Set dynamically so the app
            // still builds with older SDKs and runs on macOS 12-26. The passive counter stays uncancellable.
            if g !== counter, g.responds(to: NSSelectorFromString("setCancellableByScrollGesture:")),
               tb_try({ g.setValue(true, forKey: "cancellableByScrollGesture") }) == nil {
                cancellable += 1
            }
            view.addGestureRecognizer(g)
        }
        if cancellable > 0 { cancellableInfo = "set on \(cancellable) recognizers" }

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
                    self.bump {
                        $0.eventTypes[e.type.rawValue, default: 0] += 1
                        if e.type == .rotate { $0.rotationSum += Double(e.rotation); if e.rotation == 0 { $0.rotationZero += 1 } }
                        if e.type == .magnify { $0.magnificationSum += Double(e.magnification) }
                    }
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
        if Date().timeIntervalSince(lastDelegateTouch) > 1.5 { delegateTouchIDs.removeAll() }
        lastDelegateTouch = Date()
        delegateTouchIDs.insert(touch.identity.hash)
        let name = TouchTestController.recognizerName(gestureRecognizer)
        let typeName: String
        switch touch.type {
        case .direct: typeName = "direct"
        case .indirect: typeName = "indirect"
        default: typeName = "other"
        }
        let simultaneous = delegateTouchIDs.count
        bump {
            switch touch.type {
            case .direct: $0.recognizerDirect += 1
            case .indirect: $0.recognizerIndirect += 1
            default: $0.recognizerOther += 1
            }
            $0.shouldReceiveByRecognizer["\(name)/\(typeName)", default: 0] += 1
            $0.delegateMaxSimultaneous = max($0.delegateMaxSimultaneous, simultaneous)
        }
        return true
    }

    static func recognizerName(_ g: NSGestureRecognizer) -> String {
        switch g {
        case is TouchCountingRecognizer: return "counter"
        case is NSPanGestureRecognizer: return "pan"
        case is NSMagnificationGestureRecognizer: return "magnify"
        case is NSRotationGestureRecognizer: return "rotate"
        case is NSPressGestureRecognizer: return "press"
        case is NSClickGestureRecognizer: return "click"
        default: return "\(type(of: g))"
        }
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }

    @objc private func panned(_ g: NSPanGestureRecognizer) {
        let t = g.translation(in: view)
        let d = Double(hypot(t.x, t.y))
        bump { $0.pan += 1; $0.panTranslationMax = max($0.panTranslationMax, d) }
    }
    @objc private func magnified(_ g: NSMagnificationGestureRecognizer) {
        let m = Double(g.magnification)
        bump { $0.magnification += 1; $0.recMagnificationLast = m; if abs(m) > abs($0.recMagnificationMax) { $0.recMagnificationMax = m } }
    }
    @objc private func rotated(_ g: NSRotationGestureRecognizer) {
        let r = Double(g.rotationInDegrees)
        bump { $0.rotation += 1; $0.recRotationLast = r; if abs(r) > abs($0.recRotationMax) { $0.recRotationMax = r } }
    }
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
        resetCounters()
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
        lines.append(contentsOf: setupInfo())
        lines.append(contentsOf: TouchTestController.screenInfo())
        lines.append(contentsOf: extraInfo())
        label.stringValue = lines.joined(separator: "\n")
    }

    /// Text block for the results file
    func report(title: String) -> [String] {
        var out = ["=== \(title) – TouchBridge \(Updater.currentVersion) – \(Date())",
                   "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        out.append(contentsOf: setupInfo())
        for k in order { out.append("[\(k)] " + (counters[k] ?? TouchCounters()).line) }
        out.append(contentsOf: TouchTestController.screenInfo())
        out.append(contentsOf: extraInfo())
        return out
    }

    /// Build SDK (decides AppKit's linked-on-or-after behaviour), recognizer setup and whether anything covers the
    /// touch area (TN3212: a covering view, even a transparent one, keeps recognizers from being gathered).
    func setupInfo() -> [String] {
        var hit = "-"
        if let content = window?.contentView, window?.isVisible == true {
            // hitTest(_:) takes the point in the superview's coordinate system
            let inWindow = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let top = content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow)
            hit = top === view ? "TouchTestView (nothing covers it)" : "covered by \(top.map { "\(type(of: $0))" } ?? "nothing (nil)")"
        }
        return [TouchTestController.buildInfo(),
                "Recognizers: click, press, pan, magnify, rotate, touch counter (allowedTouchTypes = direct) | isCancellableByScrollGesture: \(cancellableInfo) | hit test at touch area centre: \(hit)"]
    }

    /// "Build: SDK macOS 27.0 (…)" – compile-time SDK, LC_BUILD_VERSION of the executable and DTSDKName/DTXcode from Info.plist
    static func buildInfo() -> String {
        func ver(_ v: UInt32) -> String {
            let patch = v & 0xff
            return "\(v >> 16).\((v >> 8) & 0xff)" + (patch > 0 ? ".\(patch)" : "")
        }
        let maxAllowed = Int(tb_sdk_compile_max_allowed()), minRequired = Int(tb_sdk_compile_min_required())
        var minos: UInt32 = 0, sdk: UInt32 = 0
        let lc = tb_main_build_version(&minos, &sdk) == 1 ? "binary sdk \(ver(sdk)), minos \(ver(minos))" : "binary build version unknown"
        let info = Bundle.main.infoDictionary ?? [:]
        let plist = ["DTSDKName", "DTXcode", "DTXcodeBuild", "LSMinimumSystemVersion"].compactMap { k in info[k].map { "\(k) \($0)" } }
        return "Build: \(lc) | compile-time SDK \(maxAllowed / 10000).\((maxAllowed / 100) % 100) (__MAC_OS_X_VERSION_MAX_ALLOWED \(maxAllowed), min required \(minRequired))"
            + (plist.isEmpty ? " | no DT* keys (not run from the app bundle)" : " | " + plist.joined(separator: ", "))
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
                // value(forKey:) raised for unknown return types; read via NSInvocation inside @try instead
                caps.append("\(sel): " + tb_describe_getter(s, sel))
            }
            out.append("Screen \(name) (id \(id)): " + (caps.isEmpty ? "no touch capability API" : caps.joined(separator: ", ")))
        }
        return out
    }
}

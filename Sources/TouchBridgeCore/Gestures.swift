import CoreGraphics
import Foundation
#if canImport(Carbon)
import Carbon
#endif

// MARK: - Synthetische macOS-Events

/// Ziel der Gesten-Engine (in Tests durch einen Recorder ersetzt).
public protocol EventSink: AnyObject {
    func move(_ p: CGPoint)
    func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clicks: Int64)
    func click(_ p: CGPoint, right: Bool, clicks: Int64)
    /// Pixel-Scroll mit Scroll-Phase (Feld 99): 1 began, 2 changed, 4 ended, 8 cancelled, 128 mayBegin
    func scroll(dx: Int32, dy: Int32, phase: Int64)
    func key(_ code: CGKeyCode, flags: CGEventFlags)
    /// Trackpad-Zoomgeste (Magnify); phase 1 = Beginn, 2 = Änderung, 4 = Ende
    func magnify(_ amount: Double, phase: Int64)
    /// Nachlauf-Scroll nach dem Loslassen (Feld 123 kCGScrollWheelEventMomentumPhase: 1 begin, 2 continue, 3 end)
    func momentum(dx: Int32, dy: Int32, phase: Int64)
    /// Trackpad-Drehgeste (Grad, positiv = gegen den Uhrzeigersinn); phase 1/2/4
    func rotate(_ degrees: Double, phase: Int64)
    /// Intelligentes Zoomen (wie 2-Finger-Doppeltippen auf dem Trackpad)
    func smartZoom(at p: CGPoint)
    /// Erste vorhandene App aus der Liste öffnen (Launchpad / Apps)
    func openApp(_ candidates: [String])
}

public extension EventSink {
    func magnify(_ amount: Double, phase: Int64) {}
    func momentum(dx: Int32, dy: Int32, phase: Int64) {}
    func rotate(_ degrees: Double, phase: Int64) {}
    func smartZoom(at p: CGPoint) {}
    func openApp(_ candidates: [String]) {}
    /// Middle (other) mouse button click
    func middleClick(_ p: CGPoint) {
        mouse(.otherMouseDown, p, .center, clicks: 1)
        mouse(.otherMouseUp, p, .center, clicks: 1)
    }
    func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton) { mouse(type, p, button, clicks: 1) }
    func click(_ p: CGPoint, right: Bool = false) { click(p, right: right, clicks: 1) }
}

public final class EventPoster: EventSink {
    public init() {}
    private let src = CGEventSource(stateID: .hidSystemState)
    /// Eigene Events markieren, damit der Systemzeiger-Filter (Event-Tap) sie durchlässt
    private func mark(_ e: CGEvent) { e.setIntegerValueField(.eventSourceUserData, value: SystemPointerFilter.marker) }
    private func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }

    public func move(_ p: CGPoint) { mouse(.mouseMoved, p, .left, clicks: 1) }

    public func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clicks: Int64) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        mark(e)
        e.post(tap: .cghidEventTap)
    }

    public func click(_ p: CGPoint, right: Bool, clicks: Int64) {
        if right {
            mouse(.rightMouseDown, p, .right, clicks: clicks)
            mouse(.rightMouseUp, p, .right, clicks: clicks)
        } else {
            mouse(.leftMouseDown, p, .left, clicks: clicks)
            mouse(.leftMouseUp, p, .left, clicks: clicks)
        }
    }

    /// Kontinuierlicher Pixel-Scroll wie vom Trackpad. scrollPhase -> Feld 99, momentumPhase -> Feld 123
    /// (beide nie gleichzeitig ≠ 0, wie beim echten Trackpad).
    private func postScroll(dx: Int32, dy: Int32, scrollPhase: Int64, momentumPhase: Int64) {
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                              wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(field(99), value: scrollPhase)      // kCGScrollWheelEventScrollPhase
        e.setIntegerValueField(field(123), value: momentumPhase)   // kCGScrollWheelEventMomentumPhase
        HIDEventBridge.attachScroll(e, dx: dx, dy: dy, phase: scrollPhase, momentum: momentumPhase)
        mark(e)
        e.post(tap: .cghidEventTap)
    }

    /// phase: 1 = began, 2 = changed, 4 = ended, 8 = cancelled, 128 = mayBegin (kCGScrollPhase...)
    public func scroll(dx: Int32, dy: Int32, phase: Int64) {
        postScroll(dx: dx, dy: dy, scrollPhase: phase, momentumPhase: 0)
    }

    public func momentum(dx: Int32, dy: Int32, phase: Int64) {
        postScroll(dx: dx, dy: dy, scrollPhase: 0, momentumPhase: phase)
    }

    public func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            mark(e)
            e.post(tap: .cghidEventTap)
        }
    }

    /// Gesture-Event (CGS-Typ 29, undokumentiert): Feld 110 = IOHIDEventType, Feld 132 = Phase.
    private func gestureEvent(hidType: Int64, phase: Int64?) -> CGEvent? {
        guard let e = CGEvent(source: src) else { return nil }
        e.type = CGEventType(rawValue: 29) ?? .null
        e.setIntegerValueField(field(110), value: hidType)
        if let p = phase { e.setIntegerValueField(field(132), value: p) }
        return e
    }

    /// Wie ein echtes Trackpad: Gesture-Event (CGS-Typ 29) mit HID-Typ Zoom (8), Phase (Feld 132) und Betrag (Feld 113).
    /// Undokumentiert, aber seit Jahren stabil (u. a. Mac Mouse Fix, WebKit-Test-SPI).
    public func magnify(_ amount: Double, phase: Int64) {
        guard let e = gestureEvent(hidType: HIDEventBridge.typeZoom, phase: phase) else { return }
        e.setDoubleValueField(field(113), value: amount)
        HIDEventBridge.attachMagnify(e, amount: amount, phase: phase)
        mark(e)
        e.post(tap: .cghidEventTap)
    }

    /// Drehen: HID-Typ Rotation (5), Grad in Feld 114 (wie Mac Mouse Fix' TouchSimulator)
    public func rotate(_ degrees: Double, phase: Int64) {
        guard let e = gestureEvent(hidType: HIDEventBridge.typeRotation, phase: phase) else { return }
        e.setDoubleValueField(field(114), value: degrees)
        HIDEventBridge.attachRotate(e, degrees: degrees, phase: phase)
        mark(e)
        e.post(tap: .cghidEventTap)
    }

    /// Intelligentes Zoomen: HID-Typ ZoomToggle (22), ohne Phase
    public func smartZoom(at p: CGPoint) {
        move(p)
        guard let e = gestureEvent(hidType: HIDEventBridge.typeZoomToggle, phase: nil) else { return }
        HIDEventBridge.attachSmartZoom(e)
        mark(e)
        e.post(tap: .cghidEventTap)
    }

    public func openApp(_ candidates: [String]) {
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [path]
        try? p.run()
    }
}

public enum Key {
    public static let left: CGKeyCode = 123, right: CGKeyCode = 124, down: CGKeyCode = 125, up: CGKeyCode = 126
    public static let equal: CGKeyCode = 24, minus: CGKeyCode = 27
    /// Zoom-Tasten passend zur aktiven Tastaturbelegung (DE: „+“ = 0x1E, „-“ = 0x2C; US: „=“ = 0x18, „-“ = 0x1B)
    public static var zoomIn: CGKeyCode { KeyLayout.shared.code(for: ["+", "="]) ?? equal }
    public static var zoomOut: CGKeyCode { KeyLayout.shared.code(for: ["-"]) ?? minus }
}

/// Sucht die Taste, die in der aktuellen Belegung (ohne Shift) ein bestimmtes Zeichen erzeugt
public final class KeyLayout {
    public static let shared = KeyLayout()
    private var cache: [String: CGKeyCode] = [:]
    private var layoutID = ""

    public func code(for chars: [String]) -> CGKeyCode? {
        #if canImport(Carbon)
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
        let id = idPtr.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        if id != layoutID { cache = [:]; layoutID = id }
        let key = chars.joined()
        if let c = cache[key] { return c }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var table: [String: CGKeyCode] = [:]
        data.withUnsafeBytes { buf in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var len = 0
                var out = [UniChar](repeating: 0, count: 4)
                let rc = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &out)
                guard rc == noErr, len == 1 else { continue }
                let ch = String(utf16CodeUnits: out, count: 1)
                if table[ch] == nil { table[ch] = CGKeyCode(code) }
            }
        }
        for ch in chars { if let c = table[ch] { cache[key] = c; return c } }
        #endif
        return nil
    }
}

// MARK: - Gesten

public struct GestureConfig {
    public init() {}
    public var tapSlop: CGFloat = 12          // px Bewegung, ab der aus Tap ein Drag wird
    public var tapMaxDuration: Double = 0.45
    public var longPress: Double = 0.5        // Halten ohne Bewegung = Rechtsklick (bzw. onLongPress)
    public var doubleTapInterval: Double = 0.4
    public var scrollThreshold: CGFloat = 10
    public var pinchThreshold: CGFloat = 36
    public var swipeDistance: CGFloat = 90
    public var invertScroll = false
    public var scrollGain: CGFloat = 1.0
    /// 1-Finger-Ziehen scrollt statt zu ziehen (Zeiger/Drag)
    public var oneFingerScroll = false
    /// Pinch als echte Trackpad-Zoomgeste (stufenlos, auch Karten/Fotos); aus = Cmd + / Cmd −
    public var nativeZoom = true
    /// Nachlauf nach dem Loslassen (Momentum-Phase wie beim Trackpad)
    public var momentumScroll = true
    /// Abklingfaktor pro Frame (1/120 s)
    public var momentumDecay: Double = 0.95
    /// Mindestgeschwindigkeit beim Loslassen (px/s), damit Nachlauf startet
    public var momentumMinSpeed: Double = 150
    /// Nachlauf endet unter dieser Geschwindigkeit (px/s)
    public var momentumStopSpeed: Double = 12
    /// Zeitfenster für die Geschwindigkeitsschätzung beim Loslassen
    public var velocityWindow: Double = 0.08
    /// 2-Finger-Drehen als Trackpad-Drehgeste
    public var rotate = true
    /// Winkel (Grad), ab dem zwei Finger als Drehen gelten
    public var rotateThreshold: CGFloat = 12
    /// Zeitfenster für 2-Finger-Doppeltippen (Rechtsklick wird so lange zurückgehalten, wenn belegt)
    public var twoFingerDoubleTapInterval: Double = 0.3
    /// Zuordnung Mehrfinger-Gesten -> Aktionen
    public var gestures = GestureMap.defaults
}

/// Hooks for the app: touch context menu (long press) and smart target (tap snapping)
public protocol GestureEngineDelegate: AnyObject {
    /// Long press without movement (slot action "Touch context menu"). true = handled, otherwise a right click is sent.
    func onLongPress(at point: CGPoint) -> Bool
    /// Where a one-finger tap should click (smart target). Default: unchanged.
    func tapTarget(for point: CGPoint) -> CGPoint
}

public extension GestureEngineDelegate {
    func tapTarget(for point: CGPoint) -> CGPoint { point }
}

public final class GestureEngine {
    public enum Mode { case idle, oneFinger, dragging, longPressed, twoFinger, scrolling, pinching, rotating, threeFinger, done }

    public private(set) var mode: Mode = .idle
    private let poster: EventSink
    /// Zeitquelle (in Tests ersetzbar)
    public var clock: () -> Double = { CFAbsoluteTimeGetCurrent() }
    private var cfg: GestureConfig
    /// Aktuelle Einstellungen; Änderungen wirken ab dem nächsten Frame.
    public var config: GestureConfig {
        get { cfg }
        set { cfg = newValue; if !cfg.momentumScroll { stopMomentum() } }
    }
    public weak var delegate: GestureEngineDelegate?

    private var startTime = 0.0
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var maxFingers = 0
    private var c0 = CGPoint.zero
    private var lastC = CGPoint.zero
    private var d0: CGFloat = 0
    private var a0: CGFloat = 0
    private var pinchRef: CGFloat = 0
    private var rotRef: CGFloat = 0
    private var remX: CGFloat = 0, remY: CGFloat = 0
    private var lastTapTime = 0.0
    private var lastTapPoint = CGPoint.zero
    private var tapCount: Int64 = 0
    // 3–5 Finger
    private var multiCount = 0
    private var r0: CGFloat = 0
    // Scroll-Geschwindigkeit (aufsummierte, gesendete Scroll-Position je Zeit)
    private var samples: [(t: Double, x: CGFloat, y: CGFloat)] = []
    private var posX: CGFloat = 0, posY: CGFloat = 0
    private struct Momentum { var vx: Double; var vy: Double; var last: Double; var remX: Double; var remY: Double; var began: Bool }
    private var momentumState: Momentum?
    /// Nachlauf wurde durch neue Berührung gestoppt: mayBegin gesendet, ggf. noch cancelled senden
    private var mayBeganSent = false
    /// 2-Finger-Tap, dessen Rechtsklick auf ein mögliches Doppeltippen wartet
    private var pendingRightClick: (p: CGPoint, t: Double)?

    public init(poster: EventSink, config: GestureConfig) { self.poster = poster; self.cfg = config }

    public var isActive: Bool { mode != .idle }
    /// Nachlauf läuft – der Aufrufer sollte tick() mit ~120 Hz aufrufen
    public var isMomentumActive: Bool { momentumState != nil }

    /// touches: aktive Kontakte (nach Contact-ID sortiert) in globalen Bildschirmkoordinaten
    public func update(_ touches: [CGPoint]) {
        let now = clock()
        let n = touches.count
        if n == 0 { finish(now); return }
        if mode == .idle {
            startTime = now; maxFingers = 0; multiCount = 0
            if let m = momentumState {
                // Neue Berührung stoppt den Nachlauf (wie beim Trackpad: Momentum-Ende, dann mayBegin)
                momentumState = nil
                if m.began {
                    poster.momentum(dx: 0, dy: 0, phase: 3)
                    poster.scroll(dx: 0, dy: 0, phase: 128)
                    mayBeganSent = true
                }
            }
            if n != 2 { flushPendingRightClick() }
        }
        maxFingers = max(maxFingers, n)

        // Ein laufender Drag / Long-Press bleibt beim ersten Finger
        if mode == .dragging {
            lastPoint = touches[0]
            poster.mouse(.leftMouseDragged, lastPoint, .left)
            return
        }
        if mode == .longPressed || mode == .done { return }

        if maxFingers >= 3 {
            flushPendingRightClick()
            cancelMayBegin()
            if mode == .scrolling || mode == .pinching || mode == .rotating { endTwoFinger(now, momentum: false) }
            guard n >= 3 else { return }
            let c = centroid(touches)
            let r = meanRadius(touches, c)
            if mode != .threeFinger || n > multiCount {
                // Start bzw. weiterer Finger kam hinzu: neu ausgehen
                mode = .threeFinger; c0 = c; r0 = r; multiCount = max(multiCount, n)
                return
            }
            let dx = c.x - c0.x, dy = c.y - c0.y
            let move = hypot(dx, dy)
            if multiCount >= 4, r0 > 0 {
                let spread = abs(r - r0)
                if spread > cfg.pinchThreshold * 0.75 && spread > move {
                    if r / r0 < 0.75 { fire(.fourFingerPinchIn, at: c); mode = .done; return }
                    if r / r0 > 1.3 { fire(.fourFingerSpread, at: c); mode = .done; return }
                }
            }
            if max(abs(dx), abs(dy)) > cfg.swipeDistance {
                let four = multiCount >= 4
                let t: GestureTrigger
                if abs(dx) > abs(dy) {
                    t = dx < 0 ? (four ? .fourFingerSwipeLeft : .threeFingerSwipeLeft)
                               : (four ? .fourFingerSwipeRight : .threeFingerSwipeRight)
                } else {
                    t = dy < 0 ? (four ? .fourFingerSwipeUp : .threeFingerSwipeUp)
                               : (four ? .fourFingerSwipeDown : .threeFingerSwipeDown)
                }
                fire(t, at: c)
                mode = .done
            }
            return
        }

        if maxFingers == 2 {
            guard n == 2 else {
                if mode == .scrolling || mode == .pinching || mode == .rotating { endTwoFinger(now, momentum: true); mode = .done }
                return
            }
            let c = centroid(touches)
            let d = hypot(touches[0].x - touches[1].x, touches[0].y - touches[1].y)
            let a = angle(touches)
            switch mode {
            case .scrolling:
                scrollTo(c, now)
            case .pinching:
                if cfg.nativeZoom {
                    if pinchRef > 0 && d > 0 {
                        let m = Double(d / pinchRef - 1)
                        if abs(m) > 0.002 { poster.magnify(m, phase: 2); pinchRef = d }
                    }
                } else if pinchRef > 0 {
                    let r = d / pinchRef
                    if r > 1.18 { poster.key(Key.zoomIn, flags: .maskCommand); pinchRef = d }
                    else if r < 0.85 { poster.key(Key.zoomOut, flags: .maskCommand); pinchRef = d }
                }
            case .rotating:
                let deg = -Double(angleDiff(a, rotRef)) * 180 / Double.pi
                if abs(deg) > 0.3 { poster.rotate(deg, phase: 2); rotRef = a }
            case .twoFinger:
                // Pinch vs. Drehen vs. Scrollen: beim Pinch ändert sich der Fingerabstand stärker als der Mittelpunkt
                // wandert; beim Drehen ändert sich der Winkel, Abstand und Mittelpunkt bleiben
                let spread = abs(d - d0), move = hypot(c.x - c0.x, c.y - c0.y)
                let rot = abs(angleDiff(a, a0)) * 180 / CGFloat.pi
                if spread > cfg.pinchThreshold || (spread > cfg.pinchThreshold * 0.5 && spread > move) {
                    flushPendingRightClick(); cancelMayBegin()
                    mode = .pinching; pinchRef = d
                    if cfg.nativeZoom { poster.move(c); poster.magnify(0, phase: 1) }
                } else if cfg.rotate && cfg.gestures[.rotate] != GestureAction.none && d > 40 && rot > cfg.rotateThreshold && move < cfg.scrollThreshold * 1.5
                            && spread < cfg.pinchThreshold * 0.5 {
                    flushPendingRightClick(); cancelMayBegin()
                    let act = cfg.gestures[.rotate]
                    if act == .rotate {
                        mode = .rotating; rotRef = a
                        poster.move(c); poster.rotate(0, phase: 1)
                    } else {
                        // remapped: fire once per gesture
                        GestureActionRunner.run(act, on: poster, at: c)
                        mode = .done
                    }
                } else if move > cfg.scrollThreshold && spread < move * 0.6 {
                    flushPendingRightClick()
                    startScroll(from: c, now)
                }
            default:
                mode = .twoFinger; c0 = c; d0 = d; a0 = a
                poster.move(c) // Scroll-Events gehen an das Fenster unter dem Cursor
            }
            return
        }

        // Ein Finger
        let p = touches[0]
        lastPoint = p
        switch mode {
        case .idle:
            mode = .oneFinger; startPoint = p
            poster.move(p)
        case .oneFinger:
            if hypot(p.x - startPoint.x, p.y - startPoint.y) > cfg.tapSlop {
                if cfg.oneFingerScroll {
                    startScroll(from: startPoint, now)
                    scrollTo(p, now)
                } else {
                    cancelMayBegin()
                    poster.mouse(.leftMouseDown, startPoint, .left)
                    poster.mouse(.leftMouseDragged, p, .left)
                    mode = .dragging
                }
            }
        case .scrolling:
            scrollTo(p, now)
        default: break
        }
    }

    private func fire(_ t: GestureTrigger, at p: CGPoint) {
        GestureActionRunner.run(cfg.gestures[t], on: poster, at: p)
    }

    private func startScroll(from c: CGPoint, _ now: Double) {
        mode = .scrolling; lastC = c; remX = 0; remY = 0
        posX = 0; posY = 0
        samples = [(t: now, x: 0, y: 0)]
        mayBeganSent = false
        poster.scroll(dx: 0, dy: 0, phase: 1)
    }

    private func scrollTo(_ c: CGPoint, _ now: Double) {
        let gx = (c.x - lastC.x) * cfg.scrollGain, gy = (c.y - lastC.y) * cfg.scrollGain
        remX += gx
        remY += gy
        let ix = Int32(remX.rounded(.towardZero)), iy = Int32(remY.rounded(.towardZero))
        remX -= CGFloat(ix); remY -= CGFloat(iy)
        let sign: Int32 = cfg.invertScroll ? -1 : 1
        if ix != 0 || iy != 0 { poster.scroll(dx: ix * sign, dy: iy * sign, phase: 2) }
        posX += gx * CGFloat(sign); posY += gy * CGFloat(sign)
        samples.append((t: now, x: posX, y: posY))
        samples.removeAll { now - $0.t > 0.25 }
        lastC = c
    }

    /// Scrollen beenden (Phase ended) und ggf. Nachlauf vorbereiten (beginnt mit dem nächsten tick()).
    private func endScroll(_ now: Double, momentum: Bool) {
        poster.scroll(dx: 0, dy: 0, phase: 4)
        if momentum && cfg.momentumScroll { armMomentum(now) }
        samples = []
    }

    /// Geschwindigkeit aus den letzten ~80 ms vor dem Loslassen
    private func armMomentum(_ now: Double) {
        guard let last = samples.last, now - last.t < cfg.velocityWindow else { return }
        let window = samples.filter { last.t - $0.t <= cfg.velocityWindow }
        guard let first = window.first, last.t - first.t > 0.004 else { return }
        let dt = last.t - first.t
        let vx = Double(last.x - first.x) / dt, vy = Double(last.y - first.y) / dt
        guard hypot(vx, vy) >= cfg.momentumMinSpeed else { return }
        momentumState = Momentum(vx: vx, vy: vy, last: now, remX: 0, remY: 0, began: false)
    }

    /// Nachlauf sofort beenden (z. B. Einstellung aus, Moduswechsel)
    public func stopMomentum() {
        guard let m = momentumState else { return }
        momentumState = nil
        if m.began { poster.momentum(dx: 0, dy: 0, phase: 3) }
    }

    private func stepMomentum(_ now: Double) {
        guard var m = momentumState else { return }
        let dt = min(0.05, max(0, now - m.last))
        m.last = now
        guard dt > 0 else { momentumState = m; return }
        let decay = pow(cfg.momentumDecay, dt * 120)
        m.vx *= decay; m.vy *= decay
        m.remX += m.vx * dt; m.remY += m.vy * dt
        let ix = Int32(m.remX.rounded(.towardZero)), iy = Int32(m.remY.rounded(.towardZero))
        m.remX -= Double(ix); m.remY -= Double(iy)
        if hypot(m.vx, m.vy) < cfg.momentumStopSpeed {
            momentumState = nil
            if m.began { poster.momentum(dx: ix, dy: iy, phase: 3) }
            return
        }
        if !m.began {
            m.began = true
            poster.momentum(dx: ix, dy: iy, phase: 1)
        } else if ix != 0 || iy != 0 {
            poster.momentum(dx: ix, dy: iy, phase: 2)
        }
        momentumState = m
    }

    private func cancelMayBegin() {
        guard mayBeganSent else { return }
        mayBeganSent = false
        poster.scroll(dx: 0, dy: 0, phase: 8)
    }

    /// Runs the (held back) 2-finger tap action – right click by default
    private func flushPendingRightClick() {
        guard let p = pendingRightClick else { return }
        pendingRightClick = nil
        GestureActionRunner.run(cfg.gestures[.twoFingerTap], on: poster, at: p.p)
    }

    /// Laufende 2-Finger-Geste (Scrollen, Pinch, Drehen) sauber beenden
    private func endTwoFinger(_ now: Double, momentum: Bool) {
        switch mode {
        case .scrolling: endScroll(now, momentum: momentum)
        case .pinching: if cfg.nativeZoom { poster.magnify(0, phase: 4) }
        case .rotating: poster.rotate(0, phase: 4)
        default: break
        }
    }

    /// Wird regelmäßig aufgerufen (Long-Press, zurückgehaltener Rechtsklick; während des Nachlaufs mit ~120 Hz)
    public func tick() {
        let now = clock()
        if momentumState != nil { stepMomentum(now) }
        if let p = pendingRightClick, mode == .idle, now - p.t >= cfg.twoFingerDoubleTapInterval {
            pendingRightClick = nil
            GestureActionRunner.run(cfg.gestures[.twoFingerTap], on: poster, at: p.p)
        }
        guard mode == .oneFinger else { return }
        if now - startTime >= cfg.longPress {
            mode = .longPressed
            let act = cfg.gestures[.longPress]
            if act == .contextMenu {
                if delegate?.onLongPress(at: startPoint) != true { poster.click(startPoint, right: true) }
            } else {
                GestureActionRunner.run(act, on: poster, at: startPoint)
            }
        }
    }

    private func finish(_ now: Double) {
        if mode != .scrolling { cancelMayBegin() }
        switch mode {
        case .oneFinger:
            if now - startTime <= cfg.tapMaxDuration {
                if now - lastTapTime < cfg.doubleTapInterval,
                   hypot(startPoint.x - lastTapPoint.x, startPoint.y - lastTapPoint.y) < 30 {
                    tapCount += 1
                } else { tapCount = 1 }
                let target = delegate?.tapTarget(for: startPoint) ?? startPoint
                poster.click(target, right: false, clicks: tapCount)
                lastTapTime = now; lastTapPoint = startPoint
            }
        case .dragging:
            poster.mouse(.leftMouseUp, lastPoint, .left)
        case .twoFinger:
            if now - startTime < 0.35 {   // Zwei-Finger-Tap
                let double = cfg.gestures[.twoFingerDoubleTap]
                if let p = pendingRightClick, startTime - p.t <= cfg.twoFingerDoubleTapInterval, double != GestureAction.none {
                    pendingRightClick = nil
                    GestureActionRunner.run(double, on: poster, at: c0)
                } else {
                    flushPendingRightClick()
                    // Rechtsklick zurückhalten, falls ein zweiter Tap (Doppeltippen) folgt
                    if double != GestureAction.none { pendingRightClick = (p: c0, t: now) }
                    else { GestureActionRunner.run(cfg.gestures[.twoFingerTap], on: poster, at: c0) }
                }
            } else {
                flushPendingRightClick()
            }
        case .scrolling, .pinching, .rotating:
            endTwoFinger(now, momentum: true)
        default: break
        }
        mode = .idle
        maxFingers = 0
        multiCount = 0
    }

    private func centroid(_ t: [CGPoint]) -> CGPoint {
        let sx = t.reduce(0) { $0 + $1.x }, sy = t.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(t.count), y: sy / CGFloat(t.count))
    }

    private func meanRadius(_ t: [CGPoint], _ c: CGPoint) -> CGFloat {
        t.reduce(0) { $0 + hypot($1.x - c.x, $1.y - c.y) } / CGFloat(t.count)
    }

    private func angle(_ t: [CGPoint]) -> CGFloat { atan2(t[1].y - t[0].y, t[1].x - t[0].x) }

    private func angleDiff(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = a - b
        while d > CGFloat.pi { d -= 2 * CGFloat.pi }
        while d < -CGFloat.pi { d += 2 * CGFloat.pi }
        return d
    }
}

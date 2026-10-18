import CoreGraphics
import Foundation

// MARK: - Synthetische macOS-Events

/// Ziel der Gesten-Engine (in Tests durch einen Recorder ersetzt).
public protocol EventSink: AnyObject {
    func move(_ p: CGPoint)
    func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clicks: Int64)
    func click(_ p: CGPoint, right: Bool, clicks: Int64)
    func scroll(dx: Int32, dy: Int32, phase: Int64)
    func key(_ code: CGKeyCode, flags: CGEventFlags)
}

public extension EventSink {
    func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton) { mouse(type, p, button, clicks: 1) }
    func click(_ p: CGPoint, right: Bool = false) { click(p, right: right, clicks: 1) }
}

public final class EventPoster: EventSink {
    public init() {}
    private let src = CGEventSource(stateID: .hidSystemState)

    public func move(_ p: CGPoint) { mouse(.mouseMoved, p, .left, clicks: 1) }

    public func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clicks: Int64) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
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

    /// phase: 1 = began, 2 = changed, 4 = ended (kCGScrollPhase...)
    public func scroll(dx: Int32, dy: Int32, phase: Int64) {
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                              wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let phaseField = CGEventField(rawValue: 99) { // kCGScrollWheelEventScrollPhase
            e.setIntegerValueField(phaseField, value: phase)
        }
        e.post(tap: .cghidEventTap)
    }

    public func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }
}

public enum Key {
    public static let left: CGKeyCode = 123, right: CGKeyCode = 124, down: CGKeyCode = 125, up: CGKeyCode = 126
    public static let equal: CGKeyCode = 24, minus: CGKeyCode = 27
}

// MARK: - Gesten

public struct GestureConfig {
    public init() {}
    public var tapSlop: CGFloat = 12          // px Bewegung, ab der aus Tap ein Drag wird
    public var tapMaxDuration: Double = 0.45
    public var longPress: Double = 0.65       // Halten = Rechtsklick
    public var doubleTapInterval: Double = 0.4
    public var scrollThreshold: CGFloat = 10
    public var pinchThreshold: CGFloat = 45
    public var swipeDistance: CGFloat = 90
    public var invertScroll = false
    public var scrollGain: CGFloat = 1.0
}

public final class GestureEngine {
    public enum Mode { case idle, oneFinger, dragging, longPressed, twoFinger, scrolling, pinching, threeFinger, done }

    public private(set) var mode: Mode = .idle
    private let poster: EventSink
    /// Zeitquelle (in Tests ersetzbar)
    public var clock: () -> Double = { CFAbsoluteTimeGetCurrent() }
    private var cfg: GestureConfig
    /// Aktuelle Einstellungen; Änderungen wirken ab dem nächsten Frame.
    public var config: GestureConfig { get { cfg } set { cfg = newValue } }

    private var startTime = 0.0
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var maxFingers = 0
    private var c0 = CGPoint.zero
    private var lastC = CGPoint.zero
    private var d0: CGFloat = 0
    private var pinchRef: CGFloat = 0
    private var remX: CGFloat = 0, remY: CGFloat = 0
    private var lastTapTime = 0.0
    private var lastTapPoint = CGPoint.zero
    private var tapCount: Int64 = 0

    public init(poster: EventSink, config: GestureConfig) { self.poster = poster; self.cfg = config }

    public var isActive: Bool { mode != .idle }

    /// touches: aktive Kontakte (nach Contact-ID sortiert) in globalen Bildschirmkoordinaten
    public func update(_ touches: [CGPoint]) {
        let now = clock()
        let n = touches.count
        if n == 0 { finish(now); return }
        if mode == .idle { startTime = now; maxFingers = 0 }
        maxFingers = max(maxFingers, n)

        // Ein laufender Drag / Long-Press bleibt beim ersten Finger
        if mode == .dragging {
            lastPoint = touches[0]
            poster.mouse(.leftMouseDragged, lastPoint, .left)
            return
        }
        if mode == .longPressed || mode == .done { return }

        if maxFingers >= 3 {
            guard n >= 3 else { return }
            let c = centroid(touches)
            if mode != .threeFinger { mode = .threeFinger; c0 = c; return }
            let dx = c.x - c0.x, dy = c.y - c0.y
            if max(abs(dx), abs(dy)) > cfg.swipeDistance {
                if abs(dx) > abs(dy) {
                    // Wie Trackpad: nach links wischen -> Space rechts davon
                    poster.key(dx < 0 ? Key.right : Key.left, flags: .maskControl)
                } else {
                    poster.key(dy < 0 ? Key.up : Key.down, flags: .maskControl) // Mission Control / App-Exposé
                }
                mode = .done
            }
            return
        }

        if maxFingers == 2 {
            guard n == 2 else {
                if mode == .scrolling { poster.scroll(dx: 0, dy: 0, phase: 4); mode = .done }
                return
            }
            let c = centroid(touches)
            let d = hypot(touches[0].x - touches[1].x, touches[0].y - touches[1].y)
            switch mode {
            case .scrolling:
                remX += (c.x - lastC.x) * cfg.scrollGain
                remY += (c.y - lastC.y) * cfg.scrollGain
                let ix = Int32(remX.rounded(.towardZero)), iy = Int32(remY.rounded(.towardZero))
                remX -= CGFloat(ix); remY -= CGFloat(iy)
                let sign: Int32 = cfg.invertScroll ? -1 : 1
                if ix != 0 || iy != 0 { poster.scroll(dx: ix * sign, dy: iy * sign, phase: 2) }
                lastC = c
            case .pinching:
                if pinchRef > 0 {
                    let r = d / pinchRef
                    if r > 1.3 { poster.key(Key.equal, flags: .maskCommand); pinchRef = d }
                    else if r < 0.77 { poster.key(Key.minus, flags: .maskCommand); pinchRef = d }
                }
            case .twoFinger:
                if abs(d - d0) > cfg.pinchThreshold {
                    mode = .pinching; pinchRef = d
                } else if hypot(c.x - c0.x, c.y - c0.y) > cfg.scrollThreshold {
                    mode = .scrolling; lastC = c; remX = 0; remY = 0
                    poster.scroll(dx: 0, dy: 0, phase: 1)
                }
            default:
                mode = .twoFinger; c0 = c; d0 = d
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
                poster.mouse(.leftMouseDown, startPoint, .left)
                poster.mouse(.leftMouseDragged, p, .left)
                mode = .dragging
            }
        default: break
        }
    }

    /// Wird regelmäßig aufgerufen (Long-Press-Erkennung)
    public func tick() {
        guard mode == .oneFinger else { return }
        if clock() - startTime >= cfg.longPress {
            poster.click(startPoint, right: true)
            mode = .longPressed
        }
    }

    private func finish(_ now: Double) {
        switch mode {
        case .oneFinger:
            if now - startTime <= cfg.tapMaxDuration {
                if now - lastTapTime < cfg.doubleTapInterval,
                   hypot(startPoint.x - lastTapPoint.x, startPoint.y - lastTapPoint.y) < 30 {
                    tapCount += 1
                } else { tapCount = 1 }
                poster.click(startPoint, right: false, clicks: tapCount)
                lastTapTime = now; lastTapPoint = startPoint
            }
        case .dragging:
            poster.mouse(.leftMouseUp, lastPoint, .left)
        case .twoFinger:
            if now - startTime < 0.35 { poster.click(c0, right: true) } // Zwei-Finger-Tap
        case .scrolling:
            poster.scroll(dx: 0, dy: 0, phase: 4)
        default: break
        }
        mode = .idle
        maxFingers = 0
    }

    private func centroid(_ t: [CGPoint]) -> CGPoint {
        let sx = t.reduce(0) { $0 + $1.x }, sy = t.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(t.count), y: sy / CGFloat(t.count))
    }
}

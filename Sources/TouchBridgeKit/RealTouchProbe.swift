import CoreGraphics
import Foundation
import TouchBridgeCore

/// Real-touch experiment: tries to get macOS to deliver *real* touches (NSTouch, ideally `.direct`) instead of
/// mouse events, by attaching an IOHIDEvent digitizer collection (hand + fingers, see HIDDigitizerEvents) to
/// synthetic CGEvents with SLEventSetIOHIDEvent. Each variant plays the same script on the target display:
/// tap, 1-finger drag, 2-finger pinch. A listen-only session event tap records which of our events survive the
/// WindowServer; the Touch Test window (app) counts what AppKit makes of them.
///
///   V1  gesture event (CGS type 29) subtype 11 (digitizer = "touches", calftrail TouchSynthesis
///       kTLInfoSubtypeGesture 0x0B) wrapped in BeginGesture 0x3D / EndGesture 0x3E, payload display-integrated
///   V1b same, payload NOT display-integrated (should at best become indirect/trackpad touches)
///   V2  payload attached to mouse down / dragged / up
///   V3  plain gesture event type 29 subtype 11 without payload (pre-27 fields only, control)
///   V4  CGEvent type 37 (NSEventTypeDirectTouch) with payload
///
/// Undocumented private API; nothing here is used on the normal touch path.
public final class RealTouchProbe {
    public enum Variant: String, CaseIterable {
        case v1 = "V1", v1b = "V1b", v2 = "V2", v3 = "V3", v4 = "V4"
        public var title: String {
            switch self {
            case .v1: return "V1 gesture(29/11) + IOHIDEvent, display-integrated"
            case .v1b: return "V1b gesture(29/11) + IOHIDEvent, not display-integrated"
            case .v2: return "V2 mouse down/drag/up + IOHIDEvent"
            case .v3: return "V3 plain gesture(29/11), no IOHIDEvent"
            case .v4: return "V4 type 37 (directTouch) + IOHIDEvent"
            }
        }
    }

    public let display: CGDirectDisplayID
    /// Global CG rect (top-left origin) in which the gestures are played – the Touch Test window or the display centre
    public let region: CGRect
    public var variants: [Variant] = Variant.allCases
    public var log: (String) -> Void
    /// Current variant label (nil at the end) – lets the Touch Test window attribute its counters
    public var onVariant: ((String?) -> Void)?
    /// Events seen by the session tap per variant: "type 29/11" -> count
    public private(set) var seen: [String: [String: Int]] = [:]

    private var current: String?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let src = CGEventSource(stateID: .hidSystemState)
    private var describedThisVariant = false
    private var running = false

    public init(display: CGDirectDisplayID, region: CGRect? = nil, log: @escaping (String) -> Void) {
        self.display = display
        let b = CGDisplayBounds(display)
        self.region = region ?? b.insetBy(dx: b.width * 0.2, dy: b.height * 0.2)
        self.log = log
    }

    // MARK: script

    private struct Frame {
        var contacts: [HIDDigitizerEvents.Contact]
        var phase: UInt32
        var points: [CGPoint]
    }

    private func norm(_ p: CGPoint) -> (Double, Double) {
        let b = CGDisplayBounds(display)
        return (Double((p.x - b.minX) / max(1, b.width)), Double((p.y - b.minY) / max(1, b.height)))
    }

    private func frame(_ pts: [CGPoint], stage: HIDDigitizerEvents.Contact.Stage) -> Frame {
        let contacts = pts.enumerated().map { i, p -> HIDDigitizerEvents.Contact in
            let (x, y) = norm(p)
            return HIDDigitizerEvents.Contact(id: UInt32(i + 1), x: x, y: y, touching: stage != .ended, stage: stage)
        }
        let phase: UInt32 = stage == .began ? HIDDigitizerEvents.phaseBegan : (stage == .ended ? HIDDigitizerEvents.phaseEnded : HIDDigitizerEvents.phaseChanged)
        return Frame(contacts: contacts, phase: phase, points: pts)
    }

    /// One stroke as frames: began, moved…, ended
    private func stroke(_ positions: [[CGPoint]]) -> [Frame] {
        guard let first = positions.first, let last = positions.last else { return [] }
        var out = [frame(first, stage: .began)]
        for p in positions.dropFirst() { out.append(frame(p, stage: .moved)) }
        out.append(frame(last, stage: .ended))
        return out
    }

    private var script: [(name: String, frames: [Frame])] {
        let c = CGPoint(x: region.midX, y: region.midY)
        let w = region.width
        let tap = stroke(Array(repeating: [c], count: 4))
        let drag = stroke((0...30).map { i in [CGPoint(x: c.x - w * 0.2 + w * 0.4 * CGFloat(i) / 30, y: c.y)] })
        let pinch = stroke((0...30).map { i in
            let d = w * (0.08 + 0.17 * CGFloat(i) / 30)
            return [CGPoint(x: c.x - d, y: c.y), CGPoint(x: c.x + d, y: c.y)]
        })
        return [("tap", tap), ("drag", drag), ("pinch", pinch)]
    }

    // MARK: run

    public func run(completion: @escaping () -> Void) {
        guard !running else { return }
        running = true
        let b = CGDisplayBounds(display)
        log("=== Real touch experiment \(Date()) – macOS \(HIDEventBridge.osMajor) ===")
        log("Target display: \(Displays.name(of: display)) id \(display) \(Int(b.width))×\(Int(b.height)) @ (\(Int(b.minX)),\(Int(b.minY)))")
        log("Region: \(Int(region.minX)),\(Int(region.minY)) \(Int(region.width))×\(Int(region.height))")
        log("Symbols: " + HIDDigitizerEvents.summary)
        if !HIDDigitizerEvents.available { log("⚠️  Digitizer IOHIDEvents cannot be built/attached – only V3 is meaningful") }
        startTap()

        let frameDt = 1.0 / 60
        var t = 0.8
        let start = DispatchTime.now()
        func at(_ time: Double, _ block: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: start + time, execute: block)
        }
        for v in variants {
            at(t) { [weak self] in
                guard let self = self else { return }
                self.current = v.rawValue
                self.describedThisVariant = false
                self.seen[v.rawValue] = self.seen[v.rawValue] ?? [:]
                self.onVariant?(v.rawValue)
                self.log("--- \(v.title)")
            }
            t += 0.3
            for part in script {
                at(t) { [weak self] in self?.log("    \(part.name)") }
                for f in part.frames {
                    at(t) { [weak self] in self?.post(f, v) }
                    t += frameDt
                }
                t += 0.6
            }
            t += 0.6
        }
        at(t) { [weak self] in
            guard let self = self else { return }
            self.current = nil
            self.onVariant?(nil)
            self.stopTap()
            self.log("--- Session event tap (our events that passed the WindowServer):")
            for v in self.variants {
                let s = self.seen[v.rawValue] ?? [:]
                self.log("    \(v.rawValue): " + (s.isEmpty ? "nothing seen" : s.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")))
            }
            self.running = false
            completion()
        }
    }

    // MARK: posting

    private func mark(_ e: CGEvent) { e.setIntegerValueField(.eventSourceUserData, value: SystemPointerFilter.marker) }
    private func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }

    private func gesture(_ subtype: Int64, at p: CGPoint, phase: Int64?) -> CGEvent? {
        guard let e = CGEvent(source: src) else { return nil }
        e.type = CGEventType(rawValue: 29) ?? .null
        e.location = p
        e.flags = CGEventFlags(rawValue: 0x100)       // "magic" non-coalesced flag of real gesture events
        e.setIntegerValueField(field(110), value: subtype)
        e.setIntegerValueField(field(111), value: 0)
        e.setIntegerValueField(field(112), value: 0)
        if let ph = phase { e.setIntegerValueField(field(132), value: ph) }
        return e
    }

    private func centroid(_ pts: [CGPoint]) -> CGPoint {
        let n = CGFloat(max(1, pts.count))
        return CGPoint(x: pts.reduce(CGFloat(0)) { $0 + $1.x } / n, y: pts.reduce(CGFloat(0)) { $0 + $1.y } / n)
    }

    private func send(_ e: CGEvent, hid: CFTypeRef?) {
        if let h = hid { HIDDigitizerEvents.attach(e, h) }
        mark(e)
        if !describedThisVariant {
            describedThisVariant = true
            log("      first event: type \(e.type.rawValue)" + (e.type.rawValue == 29 ? " subtype \(e.getIntegerValueField(field(110)))" : "")
                + " – " + (hid == nil ? "no payload" : HIDDigitizerEvents.describeAttached(e)))
        }
        e.post(tap: .cghidEventTap)
    }

    private func post(_ f: Frame, _ v: Variant) {
        let p = centroid(f.points)
        let began = f.phase == HIDDigitizerEvents.phaseBegan
        let ended = f.phase == HIDDigitizerEvents.phaseEnded
        switch v {
        case .v1, .v1b, .v3:
            let hid = v == .v3 ? nil : HIDDigitizerEvents.makeHand(f.contacts, displayIntegrated: v == .v1, phase: f.phase)
            if v != .v3 && hid == nil { return }
            if began, let b = gesture(0x3D, at: p, phase: nil) {           // BeginGesture, next subtype = touches
                b.setIntegerValueField(field(117), value: 11)
                send(b, hid: nil)
            }
            if let e = gesture(11, at: p, phase: Int64(f.phase)) { send(e, hid: hid) }
            if ended, let e = gesture(0x3E, at: p, phase: nil) {           // EndGesture
                e.setIntegerValueField(field(117), value: 0)
                send(e, hid: nil)
            }
        case .v2:
            guard let hid = HIDDigitizerEvents.makeHand(f.contacts, displayIntegrated: true, phase: f.phase) else { return }
            let first = f.points.first ?? p
            let type: CGEventType = began ? .leftMouseDown : (ended ? .leftMouseUp : .leftMouseDragged)
            if let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: first, mouseButton: .left) {
                e.setIntegerValueField(.mouseEventClickState, value: 1)
                send(e, hid: hid)
            }
        case .v4:
            guard let hid = HIDDigitizerEvents.makeHand(f.contacts, displayIntegrated: true, phase: f.phase),
                  let e = CGEvent(source: src) else { return }
            e.type = CGEventType(rawValue: 37) ?? .null
            e.location = p
            send(e, hid: hid)
        }
    }

    // MARK: session tap (listen only)

    private func record(_ type: CGEventType, _ e: CGEvent) {
        guard let v = current else { return }
        let ours = e.getIntegerValueField(.eventSourceUserData) == SystemPointerFilter.marker
        let raw = type.rawValue
        guard ours || raw == 29 || raw == 37 else { return }
        var key = "type \(raw)"
        if raw == 29 { key += "/\(e.getIntegerValueField(field(110)))" }
        if !ours { key += " (foreign)" }
        seen[v, default: [:]][key, default: 0] += 1
    }

    private func startTap() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        let cb: CGEventTapCallBack = { _, type, event, info in
            if let info = info {
                let probe = Unmanaged<RealTouchProbe>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = probe.tap { CGEvent.tapEnable(tap: t, enable: true) }
                } else {
                    probe.record(type, event)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask.max, callback: cb, userInfo: me) else {
            log("⚠️  Session event tap not available (Input Monitoring / Accessibility?) – WindowServer pass-through not recorded")
            return
        }
        tap = t
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        tapSource = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func stopTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        tapSource = nil
    }

    deinit { stopTap() }

    /// Desktop/TouchBridge-RealTouch-Probe.txt (results are appended)
    public static var resultsURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent("TouchBridge-RealTouch-Probe.txt")
    }

    /// Appends to the results file; returns nil on success, otherwise the error text.
    @discardableResult
    public static func append(_ lines: [String]) -> String? {
        let text = lines.joined(separator: "\n") + "\n\n"
        let url = resultsURL
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                h.closeFile()
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            NSLog("TouchBridge: probe results written to %@", url.path)
            return nil
        } catch {
            NSLog("TouchBridge: could not write %@: %@", url.path, String(describing: error))
            return String(describing: error)
        }
    }
}

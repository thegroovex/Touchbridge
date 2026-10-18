import AppKit
import TouchBridgeCore

/// Randloses, durchklickbares Fenster über dem Touch-Bildschirm, das im MIDI-Modus das Layout
/// (Fader, Pads, XY-Feld, Tasten) und die aufliegenden Finger anzeigt.
final class MIDIOverlay {
    private var window: NSWindow?
    private let view = MIDIOverlayView(frame: .zero)
    private(set) var display: CGDirectDisplayID = 0

    var isVisible: Bool { window?.isVisible ?? false }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    func show(on id: CGDirectDisplayID) {
        guard let screen = MIDIOverlay.screen(for: id) else { hide(); return }
        display = id
        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.contentView = view
            window = w
        }
        w.setFrame(screen.frame, display: true)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.needsDisplay = true
        w.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    func update(layout: MIDILayout, engine: MIDIEngine?) {
        view.layout = layout
        view.fingers = engine?.fingerInfo ?? []
        view.faders = engine?.faderValues ?? [:]
        view.xy = engine?.xyValues ?? [:]
        view.pads = engine?.activePads ?? []
        view.needsDisplay = true
    }
}

final class MIDIOverlayView: NSView {
    var layout = MIDILayout(name: "", zones: [])
    var fingers: [MIDIFingerInfo] = []
    var faders: [Int: Double] = [:]
    var xy: [Int: XYValue] = [:]
    var pads: Set<Int> = []

    override var isFlipped: Bool { true }   // y nach unten, wie die normierten Layout-Koordinaten

    private func rect(_ r: NRect) -> NSRect {
        NSRect(x: r.x * bounds.width, y: r.y * bounds.height, width: r.w * bounds.width, height: r.h * bounds.height)
    }

    private func label(_ s: String, at p: NSPoint, size: CGFloat = 13, alpha: CGFloat = 0.85) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        for (i, z) in layout.zones.enumerated() {
            let r = rect(z.rect)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            switch z.kind {
            case let .fader(cc):
                NSColor.systemTeal.withAlphaComponent(0.14).setFill(); path.fill()
                if let v = faders[i] {
                    let h = r.height * CGFloat(v)
                    let level = NSRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
                    NSColor.systemTeal.withAlphaComponent(0.45).setFill()
                    NSBezierPath(roundedRect: level, xRadius: 8, yRadius: 8).fill()
                }
                NSColor.systemTeal.withAlphaComponent(0.7).setStroke(); path.lineWidth = 2; path.stroke()
                label("\(z.name)\nCC \(cc)", at: NSPoint(x: r.midX, y: r.minY + 28), size: 12)
            case let .pad(note, _):
                let on = pads.contains(i)
                NSColor.systemOrange.withAlphaComponent(on ? 0.55 : 0.14).setFill(); path.fill()
                NSColor.systemOrange.withAlphaComponent(0.75).setStroke(); path.lineWidth = 2; path.stroke()
                label(midiNoteName(note), at: NSPoint(x: r.midX, y: r.midY))
            case let .xy(ccX, ccY):
                NSColor.systemPurple.withAlphaComponent(0.12).setFill(); path.fill()
                NSColor.systemPurple.withAlphaComponent(0.7).setStroke(); path.lineWidth = 2; path.stroke()
                if let v = xy[i] {
                    let p = NSPoint(x: r.minX + r.width * CGFloat(v.x), y: r.maxY - r.height * CGFloat(v.y))
                    let cross = NSBezierPath()
                    cross.move(to: NSPoint(x: r.minX, y: p.y)); cross.line(to: NSPoint(x: r.maxX, y: p.y))
                    cross.move(to: NSPoint(x: p.x, y: r.minY)); cross.line(to: NSPoint(x: p.x, y: r.maxY))
                    NSColor.systemPurple.withAlphaComponent(0.5).setStroke(); cross.lineWidth = 1; cross.stroke()
                }
                label("XY  CC \(ccX) / CC \(ccY)", at: NSPoint(x: r.midX, y: r.minY + 18), size: 12)
            case let .keyboard(kb):
                let kw = r.width / CGFloat(max(1, kb.keys))
                for k in 0..<kb.keys {
                    let note = kb.note(k)
                    let kr = NSRect(x: r.minX + CGFloat(k) * kw, y: r.minY, width: kw, height: r.height).insetBy(dx: 1.5, dy: 0)
                    let black = [1, 3, 6, 8, 10].contains(((note % 12) + 12) % 12)
                    let held = fingers.contains { $0.zone == i && $0.note == note }
                    let base: NSColor = black ? .black : .white
                    base.withAlphaComponent(held ? 0.5 : (black ? 0.35 : 0.12)).setFill()
                    let kp = NSBezierPath(roundedRect: kr, xRadius: 5, yRadius: 5)
                    kp.fill()
                    NSColor.white.withAlphaComponent(0.35).setStroke(); kp.lineWidth = 1; kp.stroke()
                    if note % 12 == 0 || kw > 60 {
                        label(midiNoteName(note), at: NSPoint(x: kr.midX, y: kr.maxY - 16), size: 11, alpha: 0.75)
                    }
                }
                NSColor.systemGreen.withAlphaComponent(0.6).setStroke(); path.lineWidth = 2; path.stroke()
            }
        }
        // Finger
        for f in fingers {
            let p = NSPoint(x: CGFloat(f.x) * bounds.width, y: CGFloat(f.y) * bounds.height)
            let d: CGFloat = 44
            let c = NSBezierPath(ovalIn: NSRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
            (f.zone == nil ? NSColor.systemGray : NSColor.white).withAlphaComponent(0.55).setFill()
            c.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke(); c.lineWidth = 2; c.stroke()
            if let ch = f.channel { label("\(ch + 1)", at: NSPoint(x: p.x, y: p.y - 34), size: 11) }
        }
    }
}

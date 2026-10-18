import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import TouchBridgeCore

// TouchBridge – macht einen USB-C-Touchmonitor (HID-Multitouch-Digitizer) am Mac
// mit Gesten nutzbar: Tap, Drag, Doppeltipp, Long-Press, Zwei-Finger-Scroll,
// Pinch-Zoom und Drei-Finger-Wischen.

// MARK: - Optionen

struct Options {
    var displayIndex: Int? = nil
    var listDisplays = false
    var dump = false
    var seize = true
    var swapXY = false
    var flipX = false
    var flipY = false
    var vid: Int? = nil
    var pid: Int? = nil
    var staleTimeout = 0.5
    var gesture = GestureConfig()
}

func parseInt(_ s: String) -> Int? {
    s.lowercased().hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
}

func printUsage() {
    print("""
    TouchBridge – Multitouch für USB-Touchmonitore am Mac

      --list-displays        Bildschirme auflisten
      --display N            Touch auf Bildschirm N abbilden (Standard: erster externer)
      --dump                 Nur Descriptor + Kontakte ausgeben, keine Events senden
      --no-seize             Gerät nicht exklusiv öffnen
      --swap-xy --flip-x --flip-y   Achsen anpassen (Drehung/Spiegelung)
      --invert-scroll        Scrollrichtung umkehren
      --scroll-gain F        Scroll-Faktor (Standard 1.0)
      --vid 0x1234 --pid 0x5678     Bestimmtes Gerät wählen
    """)
}

var opts = Options()
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    func next() -> String { args.isEmpty ? "" : args.removeFirst() }
    switch a {
    case "--list-displays": opts.listDisplays = true
    case "--display": opts.displayIndex = Int(next())
    case "--dump": opts.dump = true
    case "--no-seize": opts.seize = false
    case "--swap-xy": opts.swapXY = true
    case "--flip-x": opts.flipX = true
    case "--flip-y": opts.flipY = true
    case "--invert-scroll": opts.gesture.invertScroll = true
    case "--scroll-gain": opts.gesture.scrollGain = CGFloat(Double(next()) ?? 1.0)
    case "--vid": opts.vid = parseInt(next())
    case "--pid": opts.pid = parseInt(next())
    case "-h", "--help": printUsage(); exit(0)
    default: print("Unbekannte Option: \(a)"); printUsage(); exit(1)
    }
}

// MARK: - Bildschirme

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func targetDisplay() -> CGDirectDisplayID {
    let list = activeDisplays()
    if let i = opts.displayIndex, i >= 0, i < list.count { return list[i] }
    return list.first(where: { CGDisplayIsBuiltin($0) == 0 && $0 != CGMainDisplayID() })
        ?? list.first(where: { CGDisplayIsBuiltin($0) == 0 })
        ?? CGMainDisplayID()
}

if opts.listDisplays {
    for (i, d) in activeDisplays().enumerated() {
        let b = CGDisplayBounds(d)
        print("[\(i)] id=\(d) \(Int(b.width))x\(Int(b.height)) @ (\(Int(b.minX)),\(Int(b.minY)))"
              + (CGDisplayIsBuiltin(d) != 0 ? " intern" : " extern")
              + (d == CGMainDisplayID() ? " (Hauptbildschirm)" : ""))
    }
    exit(0)
}

// MARK: - Touch-Gerät

final class TouchDevice {
    let device: IOHIDDevice
    let engine: GestureEngine?
    let bufferSize: Int
    let buffer: UnsafeMutablePointer<UInt8>
    private var assembler: TouchFrameAssembler
    var lastReport = 0.0

    init?(device: IOHIDDevice, engine: GestureEngine?) {
        self.device = device
        self.engine = engine
        guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
            print("⚠️  Kein Report-Descriptor lesbar."); return nil
        }
        assembler = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: [UInt8](data)))
        let maxSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 256
        bufferSize = max(maxSize, 64)
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        print("🖐  Gerät: \(name)  (VID " + String(format: "0x%04X", vid) + ", PID " + String(format: "0x%04X", pid) + ")")
        let layouts = assembler.layouts
        if layouts.isEmpty {
            print("⚠️  Keine Multitouch-Finger im Descriptor gefunden. Descriptor (hex):")
            print(data.map { String(format: "%02X", $0) }.joined(separator: " "))
            return nil
        }
        for (rid, l) in layouts.sorted(by: { $0.key < $1.key }) {
            print("   Report \(rid): \(l.fingers.count) Finger-Slots, Contact Count: \(l.contactCount != nil ? "ja" : "nein")")
            if opts.dump {
                for (i, f) in l.fingers.enumerated() {
                    print("     Slot \(i): X[\(f.x?.describe ?? "-")] Y[\(f.y?.describe ?? "-")] Tip:\(f.tip != nil) ID:\(f.contactID != nil)")
                }
                print("   Descriptor (hex): " + data.map { String(format: "%02X", $0) }.joined(separator: " "))
            }
        }
    }

    deinit { buffer.deallocate() }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { ctx, _, _, _, _, report, length in
            guard let ctx = ctx else { return }
            let me = Unmanaged<TouchDevice>.fromOpaque(ctx).takeUnretainedValue()
            me.handle(UnsafeBufferPointer(start: report, count: length))
        }, ctx)
    }

    private func handle(_ r: UnsafeBufferPointer<UInt8>) {
        guard let result = assembler.feed(r) else { return }
        let layout = result.layout, contacts = result.contacts
        lastReport = CFAbsoluteTimeGetCurrent()
        guard let f0 = layout.fingers.first, let xf = f0.x, let yf = f0.y else { return }
        let points = contacts.map { map(x: $0.x, y: $0.y, xf: xf, yf: yf) }
        if opts.dump {
            let s = zip(contacts, points).map { c, p in "#\(c.id) raw(\(c.x),\(c.y)) -> (\(Int(p.x)),\(Int(p.y)))" }
                .joined(separator: "  ")
            print(contacts.isEmpty ? "— keine Kontakte —" : "\(contacts.count) Finger: \(s)")
            return
        }
        engine?.update(points)
    }

    func checkStale() {
        guard let e = engine, e.isActive else { return }
        if CFAbsoluteTimeGetCurrent() - lastReport > opts.staleTimeout {
            assembler.reset()
            e.update([])
        }
    }

    private func map(x: Int64, y: Int64, xf: HIDField, yf: HIDField) -> CGPoint {
        func norm(_ v: Int64, _ f: HIDField) -> CGFloat {
            let span = Double(f.logicalMax - f.logicalMin)
            guard span > 0 else { return 0 }
            return CGFloat(min(1, max(0, Double(v - f.logicalMin) / span)))
        }
        var nx = norm(x, xf), ny = norm(y, yf)
        if opts.swapXY { swap(&nx, &ny) }
        if opts.flipX { nx = 1 - nx }
        if opts.flipY { ny = 1 - ny }
        let b = CGDisplayBounds(targetDisplay())
        return CGPoint(x: b.minX + nx * (b.width - 1), y: b.minY + ny * (b.height - 1))
    }
}

// MARK: - App

final class App {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let poster = EventPoster()
    lazy var engine = GestureEngine(poster: poster, config: opts.gesture)
    var devices: [TouchDevice] = []

    func run() {
        if !opts.dump {
            let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(axOpts) {
                print("⚠️  Bitte unter Systemeinstellungen › Datenschutz & Sicherheit › Bedienungshilfen")
                print("   dem Terminal (bzw. TouchBridge) Zugriff geben und neu starten.")
            }
        }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            print("⚠️  Ggf. unter Datenschutz & Sicherheit › Eingabeüberwachung Zugriff erlauben und neu starten.")
        }

        var match: [String: Any] = [:]
        if let v = opts.vid { match[kIOHIDVendorIDKey] = v }
        if let p = opts.pid { match[kIOHIDProductIDKey] = p }
        if match.isEmpty {
            match[kIOHIDDeviceUsagePageKey] = Int(Usage.pageDigitizer)
            match[kIOHIDDeviceUsageKey] = Int(Usage.touchScreen)
        }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        var rc = IOHIDManagerOpen(manager, IOOptionBits(opts.seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
        if rc != kIOReturnSuccess && opts.seize {
            print(String(format: "⚠️  Exklusiver Zugriff fehlgeschlagen (0x%08X). Versuche ohne – macOS bewegt dann evtl. zusätzlich den Cursor.", rc))
            print("   Tipp: mit sudo starten, damit TouchBridge das Gerät exklusiv übernehmen kann.")
            rc = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if rc != kIOReturnSuccess {
            print(String(format: "❌ Konnte HID-Manager nicht öffnen (0x%08X).", rc)); exit(2)
        }

        let b = CGDisplayBounds(targetDisplay())
        print("🖥  Ziel-Bildschirm: \(Int(b.width))x\(Int(b.height)) @ (\(Int(b.minX)),\(Int(b.minY)))")
        print(opts.dump ? "Dump-Modus – berühre den Bildschirm. Ctrl+C beendet." : "Läuft. Ctrl+C beendet.")

        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for d in self.devices { d.checkStale() }
            if !opts.dump { self.engine.tick() }
        }
        signal(SIGINT) { _ in exit(0) }
        CFRunLoopRun()
    }

    func attach(_ device: IOHIDDevice) {
        guard !devices.contains(where: { $0.device === device }) else { return }
        guard let d = TouchDevice(device: device, engine: opts.dump ? nil : engine) else { return }
        d.start()
        devices.append(d)
    }

    func detach(_ device: IOHIDDevice) {
        devices.removeAll { d in
            if d.device === device { print("🔌 Gerät getrennt."); return true }
            return false
        }
    }
}

let app = App()
app.run()

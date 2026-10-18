import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import TouchBridgeCore

/// Einstellungen, die CLI und Menüleisten-App teilen.
public struct TouchSettings: Codable, Equatable {
    public var enabled = true
    public var displayID: UInt32? = nil       // nil = automatisch (erster externer Bildschirm)
    public var rotation = 0                   // 0, 90, 180, 270
    public var flipX = false
    public var flipY = false
    public var swapXY = false
    public var invertScroll = false
    public var scrollGain = 1.0
    public var seize = true
    public var vid: Int? = nil
    public var pid: Int? = nil
    public init() {}

    public var mapping: TouchMapping { TouchMapping(rotation: rotation, flipX: flipX, flipY: flipY, swapXY: swapXY) }
    public func gestureConfig(base: GestureConfig = GestureConfig()) -> GestureConfig {
        var g = base
        g.invertScroll = invertScroll
        g.scrollGain = CGFloat(scrollGain)
        return g
    }
}

public enum Permissions {
    public static var accessibility: Bool { AXIsProcessTrusted() }
    public static func requestAccessibility() {
        let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(o)
    }
    public static var inputMonitoring: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    public static func requestInputMonitoring() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
}

/// Liest HID-Multitouch-Geräte und speist Gesten als macOS-Events ein. Läuft auf dem Main-Runloop.
public final class TouchService {
    public struct Status: Equatable {
        public var running = false
        public var devices: [String] = []
        public var exclusive = false
        public var lastError: String? = nil
    }

    public var settings: TouchSettings {
        didSet {
            engine.config = settings.gestureConfig(base: gestureBase)
            if settings.enabled != oldValue.enabled || settings.seize != oldValue.seize
                || settings.vid != oldValue.vid || settings.pid != oldValue.pid {
                if running { stop(); start() }
            }
        }
    }
    /// Nur Kontakte protokollieren, keine Events senden (Diagnose / --dump).
    public var dumpMode = false
    public var log: (String) -> Void = { print($0) }
    public var onStatus: ((Status) -> Void)?
    public private(set) var status = Status() { didSet { if status != oldValue { onStatus?(status) } } }

    public let gestureBase: GestureConfig
    private let poster = EventPoster()
    private lazy var engine = GestureEngine(poster: poster, config: settings.gestureConfig(base: gestureBase))
    private var manager: IOHIDManager?
    private var devices: [TouchDevice] = []
    private var timer: Timer?
    private var running = false
    public let staleTimeout = 0.5

    public init(settings: TouchSettings, gestureBase: GestureConfig = GestureConfig()) {
        self.settings = settings
        self.gestureBase = gestureBase
    }

    public var targetDisplay: CGDirectDisplayID { Displays.resolve(settings.displayID) }

    public func start() {
        guard !running else { return }
        running = true
        guard settings.enabled || dumpMode else { status = Status(running: false); return }

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        var match: [String: Any] = [:]
        if let v = settings.vid { match[kIOHIDVendorIDKey] = v }
        if let p = settings.pid { match[kIOHIDProductIDKey] = p }
        if match.isEmpty {
            match[kIOHIDDeviceUsagePageKey] = Int(Usage.pageDigitizer)
            match[kIOHIDDeviceUsageKey] = Int(Usage.touchScreen)
        }
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            Unmanaged<TouchService>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            Unmanaged<TouchService>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        var exclusive = settings.seize
        var rc = IOHIDManagerOpen(m, IOOptionBits(settings.seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
        if rc != kIOReturnSuccess && settings.seize {
            log(String(format: "⚠️  Exklusiver Zugriff fehlgeschlagen (0x%08X) – weiter ohne. macOS bewegt dann evtl. zusätzlich den Cursor.", rc))
            exclusive = false
            rc = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if rc != kIOReturnSuccess {
            let msg = String(format: "Konnte HID-Manager nicht öffnen (0x%08X). Eingabeüberwachung erlaubt?", rc)
            log("❌ " + msg)
            status = Status(running: false, devices: [], exclusive: false, lastError: msg)
            return
        }
        status = Status(running: true, devices: devices.map(\.name), exclusive: exclusive, lastError: nil)

        // commonModes: Touch funktioniert auch, während ein Menü oder Dialog offen ist.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for d in self.devices { d.checkStale(self.staleTimeout) }
            if !self.dumpMode { self.engine.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        guard running else { return }
        running = false
        timer?.invalidate(); timer = nil
        if engine.isActive { engine.update([]) }
        devices.removeAll()
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        status = Status(running: false)
    }

    private func attach(_ device: IOHIDDevice) {
        guard !devices.contains(where: { $0.device === device }) else { return }
        guard let d = TouchDevice(device: device, service: self) else { return }
        d.start()
        devices.append(d)
        status.devices = devices.map(\.name)
    }

    private func detach(_ device: IOHIDDevice) {
        devices.removeAll { d in
            if d.device === device { log("🔌 Gerät getrennt: \(d.name)"); return true }
            return false
        }
        status.devices = devices.map(\.name)
    }

    fileprivate func deliver(_ contacts: [RawContact], layout: TouchLayout) {
        guard let f0 = layout.fingers.first, let xf = f0.x, let yf = f0.y else { return }
        let rect = CGDisplayBounds(targetDisplay)
        let map = settings.mapping
        let points = contacts.map {
            map.screenPoint(TouchMapping.normalize($0.x, min: xf.logicalMin, max: xf.logicalMax),
                            TouchMapping.normalize($0.y, min: yf.logicalMin, max: yf.logicalMax), in: rect)
        }
        if dumpMode {
            let s = zip(contacts, points).map { c, p in "#\(c.id) raw(\(c.x),\(c.y)) -> (\(Int(p.x)),\(Int(p.y)))" }
                .joined(separator: "  ")
            log(contacts.isEmpty ? "— keine Kontakte —" : "\(contacts.count) Finger: \(s)")
            return
        }
        engine.update(points)
    }

    fileprivate func releaseIfActive() {
        if engine.isActive { engine.update([]) }
    }
}

// MARK: - Einzelnes HID-Gerät

final class TouchDevice {
    let device: IOHIDDevice
    let name: String
    unowned let service: TouchService
    let bufferSize: Int
    let buffer: UnsafeMutablePointer<UInt8>
    private var assembler: TouchFrameAssembler
    private var lastReport = 0.0
    private var hadContacts = false

    init?(device: IOHIDDevice, service: TouchService) {
        let log = service.log
        let nm = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Touch-Gerät"
        guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
            log("⚠️  \(nm): kein Report-Descriptor lesbar."); return nil
        }
        let asm = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: [UInt8](data)))
        let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        log("🖐  Gerät: \(nm)  (VID " + String(format: "0x%04X", vid) + ", PID " + String(format: "0x%04X", pid) + ")")
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        if asm.layouts.isEmpty {
            log("⚠️  Keine Multitouch-Finger im Descriptor gefunden. Descriptor (hex):")
            log(hex)
            return nil
        }
        for (rid, l) in asm.layouts.sorted(by: { $0.key < $1.key }) {
            log("   Report \(rid): \(l.fingers.count) Finger-Slots, Contact Count: \(l.contactCount != nil ? "ja" : "nein")")
            if service.dumpMode {
                for (i, f) in l.fingers.enumerated() {
                    log("     Slot \(i): X[\(f.x?.describe ?? "-")] Y[\(f.y?.describe ?? "-")] Tip:\(f.tip != nil) ID:\(f.contactID != nil)")
                }
            }
        }
        if service.dumpMode { log("   Descriptor (hex): " + hex) }
        let maxSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 256
        self.device = device
        self.service = service
        self.name = nm
        self.assembler = asm
        self.bufferSize = max(maxSize, 64)
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(maxSize, 64))
    }

    deinit { buffer.deallocate() }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { ctx, _, _, _, _, report, length in
            guard let ctx = ctx else { return }
            Unmanaged<TouchDevice>.fromOpaque(ctx).takeUnretainedValue()
                .handle(UnsafeBufferPointer(start: report, count: length))
        }, ctx)
    }

    private func handle(_ r: UnsafeBufferPointer<UInt8>) {
        guard let result = assembler.feed(r) else { return }
        lastReport = CFAbsoluteTimeGetCurrent()
        hadContacts = !result.contacts.isEmpty
        service.deliver(result.contacts, layout: result.layout)
    }

    func checkStale(_ timeout: Double) {
        guard hadContacts, CFAbsoluteTimeGetCurrent() - lastReport > timeout else { return }
        assembler.reset()
        hadContacts = false
        service.releaseIfActive()
    }
}

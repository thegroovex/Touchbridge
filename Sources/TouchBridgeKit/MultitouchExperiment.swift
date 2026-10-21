import Foundation
import IOKit
import IOKit.hid
import TouchBridgeCore
import TouchBridgeUSB

// MARK: - Direkte USB-Control-Requests (IOUSBLib)

/// Session auf den USB-Geräte- oder Interface-User-Client. Ohne Entitlement/Root: Control-Requests auf der
/// Default-Pipe; USBDeviceOpen (nötig für Neu-Enumeration) gelingt nur, wenn kein anderer Client das Gerät offen hält.
public final class USBSession {
    private let raw: OpaquePointer
    public let createRC: IOReturn
    public let openRC: IOReturn?
    public let isInterface: Bool

    private init(raw: OpaquePointer, createRC: IOReturn, openRC: IOReturn?, isInterface: Bool) {
        self.raw = raw; self.createRC = createRC; self.openRC = openRC; self.isInterface = isInterface
    }

    deinit { tb_usb_close(raw) }

    public static func deviceCount(vid: Int, pid: Int) -> Int { Int(tb_usb_device_count(UInt16(vid), UInt16(pid))) }

    public static func device(vid: Int, pid: Int, open: Bool) -> (session: USBSession?, createRC: IOReturn, openRC: IOReturn?) {
        var c: Int32 = 0, o: Int32 = -1
        guard let p = tb_usb_open_device(UInt16(vid), UInt16(pid), open ? 1 : 0, &c, &o) else { return (nil, c, nil) }
        let s = USBSession(raw: p, createRC: c, openRC: open ? o : nil, isInterface: false)
        return (s, c, s.openRC)
    }

    public static func interface(vid: Int, pid: Int, number: UInt8) -> (session: USBSession?, createRC: IOReturn) {
        var c: Int32 = 0
        guard let p = tb_usb_open_interface(UInt16(vid), UInt16(pid), number, &c) else { return (nil, c) }
        return (USBSession(raw: p, createRC: c, openRC: nil, isInterface: true), c)
    }

    public var isOpen: Bool { tb_usb_is_open(raw) != 0 }

    public func send(_ r: USBControlRequest, timeoutMs: UInt32 = 500) -> (rc: IOReturn, bytes: [UInt8]) {
        var buf = r.isIn ? [UInt8](repeating: 0, count: Int(r.wLength)) : r.data
        if buf.isEmpty { buf = [0] }
        var done: UInt32 = 0
        let rc = buf.withUnsafeMutableBufferPointer { p in
            tb_usb_request(raw, r.bmRequestType, r.bRequest, r.wValue, r.wIndex, p.baseAddress, r.wLength, timeoutMs, &done)
        }
        return (rc, r.isIn && rc == kIOReturnSuccess ? Array(buf.prefix(Int(done))) : [])
    }

    public func reenumerate() -> IOReturn { tb_usb_reenumerate(raw) }

    /// Request senden und als Logzeile beschreiben
    public func sendLogged(_ r: USBControlRequest, timeoutMs: UInt32 = 500) -> (rc: IOReturn, bytes: [UInt8], line: String) {
        let a = send(r, timeoutMs: timeoutMs)
        let line = "   " + r.summary + ": " + HIDReturn.describe(a.rc)
            + (r.isIn && a.rc == kIOReturnSuccess ? " [\(HIDFeature.hex(a.bytes))] (\(a.bytes.count) bytes)" : "")
        return (a.rc, a.bytes, line)
    }
}

// MARK: - Sequenzen

/// Führt die einzelnen Multitouch-Sequenzen aus (Experiment-Runner und automatische Anwendung beim Verbinden).
enum MultitouchInitializer {
    /// bInterfaceNumber des USB-Interfaces, an dem das IOHIDDevice hängt (Registry-Eltern durchsuchen)
    static func interfaceNumber(_ d: IOHIDDevice) -> UInt8? {
        let s = IOHIDDeviceGetService(d)
        guard s != 0 else { return nil }
        let v = IORegistryEntrySearchCFProperty(s, kIOServicePlane, "bInterfaceNumber" as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        return (v as? NSNumber)?.uint8Value
    }

    /// Interface-Nummern aller Schnittstellen des Monitors; Fallback 0…2 (Anmite hat drei HID-Interfaces)
    static func interfaceNumbers(_ devices: [TouchDevice]) -> [UInt8] {
        let n = Set(devices.compactMap { interfaceNumber($0.device) })
        return n.isEmpty ? [0, 1, 2] : n.sorted()
    }

    static func inputReportSize(_ d: IOHIDDevice) -> Int {
        max(2, (IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64)
    }

    /// a) GetReport INPUT (wie usbhid_init_reports)
    static func hidInputGet(_ d: TouchDevice?, reportID: UInt8, log: (String) -> Void) {
        guard let d = d else { log("   (interface missing)"); return }
        var buf = [UInt8](repeating: 0, count: inputReportSize(d.device))
        buf[0] = reportID
        var len = CFIndex(buf.count)
        let rc = IOHIDDeviceGetReport(d.device, kIOHIDReportTypeInput, CFIndex(reportID), &buf, &len)
        log(String(format: "   IOHIDDeviceGetReport Input %d (%@, buffer %d): ", reportID, d.role.rawValue, buf.count) + HIDReturn.describe(rc)
            + (rc == kIOReturnSuccess ? " [\(HIDFeature.hex(Array(buf.prefix(min(Int(len), 24)))))] (\(len) bytes)" : ""))
    }

    /// b) Feature 0x0A + 0x21 lesen (korrekte Länge), SetReport 0x21 Mode 2 (Device Identifier übernommen, falls plausibel)
    @discardableResult
    static func hidFeature(_ d: TouchDevice, log: (String) -> Void) -> IOReturn? {
        let desc = d.descriptor
        if let c = desc.contactCountMaximumField {
            log(HIDFeature.describeGet(d.device, descriptor: desc, reportID: c.reportID, what: "Contact Count Max"))
        }
        guard let tmpl = desc.inputModeReport(mode: 2) else { log("   no Input Mode feature in descriptor"); return nil }
        let cur = HIDFeature.get(d.device, reportID: tmpl.reportID, size: tmpl.bytes.count)
        log(String(format: "   GetReport Feature 0x%02X Input Mode (buffer %d): ", tmpl.reportID, tmpl.bytes.count) + HIDReturn.describe(cur.rc)
            + (cur.bytes.isEmpty ? "" : " [\(HIDFeature.hex(cur.bytes))]"))
        guard let im = desc.inputModeReport(mode: 2, preserving: cur.rc == kIOReturnSuccess ? cur.bytes : nil) else { return nil }
        let rc = HIDFeature.set(d.device, reportID: im.reportID, bytes: im.bytes)
        log(String(format: "   SetReport Feature 0x%02X [%@]%@: ", im.reportID, HIDFeature.hex(im.bytes),
                   im.preserved ? " (reply reused, Mode=2)" : " (template, reply implausible)") + HIDReturn.describe(rc))
        return rc
    }

    /// e) IOHIDDeviceSetValue auf jedes Feature-Element Digitizer/Device Mode (0x0D/0x52) = 2 – elementbasiert statt
    /// Roh-Report (Ansatz aus Shadowhusky/xeneon-toolbox). Auf allen übergebenen Schnittstellen.
    @discardableResult
    static func hidSetValue(_ devices: [TouchDevice], log: (String) -> Void) -> Int {
        var hits = 0
        for d in devices {
            guard let els = IOHIDDeviceCopyMatchingElements(d.device, nil, 0) as? [IOHIDElement] else { continue }
            for el in els where IOHIDElementGetType(el) == kIOHIDElementTypeFeature
                && IOHIDElementGetUsagePage(el) == 0x0D && IOHIDElementGetUsage(el) == 0x52 {
                hits += 1
                let v = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, el, 0, 2)
                let rc = IOHIDDeviceSetValue(d.device, el, v)
                // Rücklesen direkt vom Gerät (kIOHIDDeviceGetValueWithUpdate = 0x00020000), nicht aus dem Cache
                var back = Unmanaged<IOHIDValue>.passUnretained(v)
                let grc = IOHIDDeviceGetValueWithOptions(d.device, el, &back, 0x0002_0000)
                let readback = grc == kIOReturnSuccess ? String(IOHIDValueGetIntegerValue(back.takeUnretainedValue())) : "–"
                log(String(format: "   IOHIDDeviceSetValue Device Mode=2 (%@, Feature 0x%02X): ", d.role.rawValue, IOHIDElementGetReportID(el))
                    + HIDReturn.describe(rc) + "  readback: " + HIDReturn.describe(grc) + " value \(readback)")
            }
        }
        if hits == 0 { log("   no element 0x0D/0x52 found") }
        return hits
    }

    /// c) Linux-Sequenz als USB-Control-Requests. `viaInterface`: über den Interface-User-Client statt Gerät.
    /// Rückgabe: SET_REPORT Input Mode erfolgreich übertragen
    @discardableResult
    static func usbLinuxInit(vid: Int, pid: Int, interfaces: [UInt8], digitizer: UInt8, descriptor desc: HIDDescriptor,
                             viaInterface: Bool, log: (String) -> Void) -> Bool {
        let session: USBSession?
        if viaInterface {
            let s = USBSession.interface(vid: vid, pid: pid, number: digitizer)
            log("   Interface-User-Client IF \(digitizer): " + HIDReturn.describe(s.createRC) + " (without USBInterfaceOpen)")
            session = s.session
        } else {
            let s = USBSession.device(vid: vid, pid: pid, open: true)
            log("   Device user client: " + HIDReturn.describe(s.createRC)
                + (s.openRC.map { "  USBDeviceOpen: " + HIDReturn.describe($0) + ($0 == kIOReturnSuccess ? "" : " – requests without open") } ?? ""))
            session = s.session
        }
        guard let s = session else { return false }
        return runLinuxSequence(s, interfaces: viaInterface ? [digitizer] : interfaces, digitizer: digitizer, descriptor: desc,
                                retryUntil: nil, log: log)
    }

    /// Sequenz auf einer Session. `retryUntil`: jeden Request bis zu diesem Zeitpunkt wiederholen (direkt nach der
    /// Enumeration ist das Interface evtl. noch nicht konfiguriert).
    private static func send(_ s: USBSession, _ r: USBControlRequest, retryUntil: Date?, log: (String) -> Void) -> (rc: IOReturn, bytes: [UInt8]) {
        var tries = 0
        while true {
            tries += 1
            let a = s.sendLogged(r, timeoutMs: 300)
            if a.rc == kIOReturnSuccess || retryUntil.map({ Date() >= $0 }) ?? true {
                log(a.line + (tries > 1 ? "  (attempt \(tries))" : ""))
                return (a.rc, a.bytes)
            }
            usleep(5_000)
        }
    }

    static func runLinuxSequence(_ s: USBSession, interfaces: [UInt8], digitizer: UInt8, descriptor desc: HIDDescriptor,
                                 retryUntil: Date?, log: (String) -> Void) -> Bool {
        var current: [UInt8]? = nil
        let imID = desc.inputModeReport(mode: 2)?.reportID
        for r in LinuxHIDInit.prelude(interfaces: interfaces, digitizer: digitizer, descriptor: desc) {
            let a = send(s, r, retryUntil: retryUntil, log: log)
            if r.isIn, r.wValue & 0xFF == UInt16(imID ?? 0), a.rc == kIOReturnSuccess {
                current = a.bytes
                let plausible = desc.isPlausibleFeature(a.bytes, reportID: imID ?? 0, length: Int(r.wLength))
                log("   → Input Mode reply via USB " + (plausible ? "plausible (IOHID returned [A1 01 21] – IOHID path suspicious!)"
                                                                  : "implausible as well"))
            }
        }
        guard let set = LinuxHIDInit.inputModeSet(digitizer: digitizer, descriptor: desc, current: current) else { return false }
        let ok = send(s, set, retryUntil: retryUntil, log: log).rc == kIOReturnSuccess
        if let id = imID {
            _ = send(s, .getReport(.feature, id: id, interface: digitizer, length: set.data.count), retryUntil: retryUntil, log: log)   // nachher lesen
        }
        return ok
    }
}

// MARK: - Experiment-Runner

/// Führt die Multitouch-Experimente nacheinander aus; nach jedem Schritt wird `waitSeconds` auf Report 13 vom
/// Digitizer gewartet (der Nutzer tippt währenddessen). Vendor-Schnittstelle wird nur passiv mitgezählt.
public final class MultitouchExperiment {
    public struct Options {
        public var waitSeconds = 3.0
        public var reenumerate = true
        public init() {}
    }

    public private(set) var lines: [String] = []
    public private(set) var success: MultitouchSequence?
    public var isRunning: Bool { completion != nil }

    private let service: TouchService
    private let options: Options
    private let externalLog: (String) -> Void
    private var queue: [MultitouchSequence] = []
    private var completion: ((MultitouchSequence?) -> Void)?
    private var timer: Timer?
    private var snapshot = (mt: 0, ptr: 0, vendor: 0)

    public init(service: TouchService, options: Options = Options(), log: @escaping (String) -> Void) {
        self.service = service; self.options = options; self.externalLog = log
    }

    private func log(_ l: String) { lines.append(l); externalLog(l) }

    private var vid: Int { service.settings.vid ?? HIDProbe.anmiteVID }
    private var pid: Int { service.settings.pid ?? HIDProbe.anmitePID }
    private var digitizer: TouchDevice? { service.devices.first { $0.kind == .multitouch } }
    private var pointer: TouchDevice? { service.devices.first { $0.kind == .pointer } }

    public func run(completion: @escaping (MultitouchSequence?) -> Void) {
        self.completion = completion
        service.experimentActive = true
        service.muted = true
        log("— Multitouch experiments \(Date()) —")
        log("Device VID " + String(format: "0x%04X PID 0x%04X", vid, pid) + "  USB devices in registry: \(USBSession.deviceCount(vid: vid, pid: pid))")
        for d in service.devices {
            log("   Interface \(d.label): IF " + (MultitouchInitializer.interfaceNumber(d.device).map(String.init) ?? "?")
                + "  " + (d.exclusive ? "exclusive" : "non-exclusive"))
        }
        log("Reports so far: \(service.reportSummary)")
        guard digitizer != nil else {
            log("❌ Digitizer interface (report 13) not open – experiments aborted.")
            finish(); return
        }
        queue = [.hidSetValue, .hidInputGet, .hidFeature, .usbLinuxInit, .usbInterfaceLinuxInit] + (options.reenumerate ? [.usbReenumerateInit] : [])
        next()
    }

    private func next() {
        guard success == nil, !queue.isEmpty else { finish(); return }
        let step = queue.removeFirst()
        log("")
        log("▶︎ \(step.title)")
        snapshot = (service.multitouchReports, service.pointerReports, service.vendorReports)
        perform(step) { [weak self] in self?.wait(step) }
    }

    private func perform(_ step: MultitouchSequence, done: @escaping () -> Void) {
        let l: (String) -> Void = { [weak self] in self?.log($0) }
        switch step {
        case .hidInputGet:
            MultitouchInitializer.hidInputGet(digitizer, reportID: 13, log: l)
            MultitouchInitializer.hidInputGet(pointer, reportID: 7, log: l)
            done()
        case .hidFeature:
            if let d = digitizer {
                MultitouchInitializer.hidFeature(d, log: l)
                MultitouchInitializer.hidInputGet(d, reportID: 13, log: l)
            }
            done()
        case .usbLinuxInit, .usbInterfaceLinuxInit:
            guard let d = digitizer, let ifn = MultitouchInitializer.interfaceNumber(d.device) else {
                log("   bInterfaceNumber of the digitizer not found – skipped"); done(); return
            }
            MultitouchInitializer.usbLinuxInit(vid: vid, pid: pid, interfaces: MultitouchInitializer.interfaceNumbers(service.devices),
                                               digitizer: ifn, descriptor: d.descriptor, viaInterface: step == .usbInterfaceLinuxInit, log: l)
            done()
        case .usbReenumerateInit:
            reenumerate(done: done)
        case .hidSetValue:
            MultitouchInitializer.hidSetValue(service.devices, log: l)
            done()
        }
    }

    /// d) USBDeviceReEnumerate, auf das neue Gerät warten (Hintergrund-Thread, Polling 5 ms) und sofort die
    /// Linux-Sequenz senden; danach – sobald der Digitizer wieder als HID-Gerät erscheint – Input Mode per IOHID.
    private func reenumerate(done: @escaping () -> Void) {
        guard let d = digitizer, let ifn = MultitouchInitializer.interfaceNumber(d.device) else {
            log("   bInterfaceNumber of the digitizer not found – skipped"); done(); return
        }
        let desc = d.descriptor
        let ifaces = MultitouchInitializer.interfaceNumbers(service.devices)
        let (vid, pid) = (self.vid, self.pid)
        let s = USBSession.device(vid: vid, pid: pid, open: true)
        log("   Device user client: " + HIDReturn.describe(s.createRC) + (s.openRC.map { "  USBDeviceOpen: " + HIDReturn.describe($0) } ?? ""))
        guard let session = s.session, session.isOpen else {
            log("   ✗ Re-enumeration needs USBDeviceOpen – another client (composite/HID driver) holds the device. Skipped.")
            done(); return
        }
        var reattached = false
        service.onDigitizerAttached = { [weak self] dev in
            guard let self = self, !reattached else { return }
            reattached = true
            self.log("   HID digitizer back (\(dev.label)) – immediately Device Mode via SetValue + Input Mode via IOHID:")
            MultitouchInitializer.hidSetValue([dev]) { self.log($0) }
            MultitouchInitializer.hidFeature(dev) { self.log($0) }
            done()
        }
        let rc = session.reenumerate()
        log("   USBDeviceReEnumerate: " + HIDReturn.describe(rc))
        guard rc == kIOReturnSuccess else { service.onDigitizerAttached = nil; done(); return }
        TouchService.lastOwnReenumeration = Date()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var out: [String] = []
            let t0 = Date()
            func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
            withExtendedLifetime(session) {}
            // altes Gerät verschwindet, neues erscheint
            while USBSession.deviceCount(vid: vid, pid: pid) > 0 && ms() < 3000 { usleep(2_000) }
            out.append("   old USB device gone after \(ms()) ms")
            var fresh: USBSession?
            while ms() < 10_000 {
                if USBSession.deviceCount(vid: vid, pid: pid) > 0, let s2 = USBSession.device(vid: vid, pid: pid, open: false).session {
                    fresh = s2; break
                }
                usleep(5_000)
            }
            if let s2 = fresh {
                out.append("   new USB device after \(ms()) ms – sending the Linux sequence right away:")
                _ = MultitouchInitializer.runLinuxSequence(s2, interfaces: ifaces, digitizer: ifn, descriptor: desc,
                                                           retryUntil: Date().addingTimeInterval(3)) { out.append($0) }
                out.append("   Linux sequence done after \(ms()) ms")
            } else {
                out.append("   ✗ device did not reappear within 10 s")
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for l in out { self.log(l) }
                // Falls der HID-Digitizer nicht wieder erscheint: nach 8 s trotzdem weiter
                let t = Timer(timeInterval: 8, repeats: false) { [weak self] _ in
                    guard let self = self, !reattached else { return }
                    reattached = true
                    self.log("   ✗ HID digitizer did not reappear within 8 s")
                    done()
                }
                RunLoop.main.add(t, forMode: .common)
            }
        }
    }

    private func wait(_ step: MultitouchSequence) {
        log(String(format: "   … waiting %.0f s – please tap/swipe on the Anmite with 2 fingers now", options.waitSeconds))
        let t = Timer(timeInterval: options.waitSeconds, repeats: false) { [weak self] _ in self?.evaluate(step) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func evaluate(_ step: MultitouchSequence) {
        let mt = service.multitouchReports - snapshot.mt
        let ptr = service.pointerReports - snapshot.ptr
        let ven = service.vendorReports - snapshot.vendor
        let v = MultitouchVerdict.evaluate(digitizerReports: mt, pointerReports: ptr)
        log("   Reports during the wait: digitizer (13) \(mt), mouse (7) \(ptr), vendor (0x50, read only) \(ven)")
        log("   " + v.text)
        if v == .multitouch { success = step }
        next()
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        service.onDigitizerAttached = nil
        service.experimentActive = false
        service.muted = false
        log("")
        if let s = success {
            log("✅ Result: multitouch with \"\(s.title)\" – saved and applied automatically on every connect from now on.")
        } else {
            log("✗ Result: no step produced report 13 – single-touch via the mouse interface stays active.")
        }
        log("Total reports: \(service.reportSummary)")
        let c = completion
        completion = nil
        c?(success)
    }
}

// MARK: - Gemerkte Sequenz beim Verbinden anwenden

extension TouchService {
    /// Zeitpunkt der letzten eigenen Neu-Enumeration (verhindert eine Schleife beim automatischen Anwenden)
    static var lastOwnReenumeration: Date?

    /// Beim Verbinden des Digitizers die gespeicherte Sequenz anwenden.
    func applyRemembered(_ seq: MultitouchSequence, to d: TouchDevice) {
        let l: (String) -> Void = { [weak self] in self?.log($0) }
        let vid = settings.vid ?? HIDProbe.anmiteVID, pid = settings.pid ?? HIDProbe.anmitePID
        log("🔧 Saved multitouch sequence: \(seq.title)")
        switch seq {
        case .hidInputGet:
            MultitouchInitializer.hidInputGet(d, reportID: 13, log: l)
            MultitouchInitializer.hidInputGet(devices.first { $0.kind == .pointer }, reportID: 7, log: l)
        case .hidFeature:
            MultitouchInitializer.hidFeature(d, log: l)
        case .hidSetValue:
            MultitouchInitializer.hidSetValue(devices, log: l)
        case .usbLinuxInit, .usbInterfaceLinuxInit:
            guard let ifn = MultitouchInitializer.interfaceNumber(d.device) else { log("   bInterfaceNumber missing"); return }
            MultitouchInitializer.usbLinuxInit(vid: vid, pid: pid, interfaces: MultitouchInitializer.interfaceNumbers(devices),
                                               digitizer: ifn, descriptor: d.descriptor, viaInterface: seq == .usbInterfaceLinuxInit, log: l)
        case .usbReenumerateInit:
            // Eigene Neu-Enumeration gerade passiert: nur noch Input Mode setzen (sonst Endlosschleife)
            if let t = TouchService.lastOwnReenumeration, Date().timeIntervalSince(t) < 20 {
                MultitouchInitializer.hidFeature(d, log: l); return
            }
            guard let ifn = MultitouchInitializer.interfaceNumber(d.device) else { return }
            let s = USBSession.device(vid: vid, pid: pid, open: true)
            guard let session = s.session, session.isOpen else {
                log("   USBDeviceOpen: " + (s.openRC.map(HIDReturn.describe) ?? "–") + " – re-enumeration not possible, Input Mode only")
                MultitouchInitializer.hidFeature(d, log: l); return
            }
            let desc = d.descriptor, ifaces = MultitouchInitializer.interfaceNumbers(devices)
            TouchService.lastOwnReenumeration = Date()
            log("   USBDeviceReEnumerate: " + HIDReturn.describe(session.reenumerate()))
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                var out: [String] = []
                let t0 = Date()
                while USBSession.deviceCount(vid: vid, pid: pid) > 0 && Date().timeIntervalSince(t0) < 3 { usleep(2_000) }
                while Date().timeIntervalSince(t0) < 10 {
                    if let s2 = USBSession.device(vid: vid, pid: pid, open: false).session {
                        _ = MultitouchInitializer.runLinuxSequence(s2, interfaces: ifaces, digitizer: ifn, descriptor: desc,
                                                                   retryUntil: Date().addingTimeInterval(3)) { out.append($0) }
                        break
                    }
                    usleep(5_000)
                }
                withExtendedLifetime(session) {}
                DispatchQueue.main.async { for o in out { self?.log(o) } }
            }
        }
    }
}

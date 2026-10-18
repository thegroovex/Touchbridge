import Foundation
import IOKit
import IOKit.hid
import TouchBridgeCore

// MARK: - IOReturn lesbar machen

public enum HIDReturn {
    // iokit_common_err(...) – die Makros sind in Swift nicht verfügbar
    public static let notPermitted = IOReturn(bitPattern: 0xE000_02E2)
    public static let notPrivileged = IOReturn(bitPattern: 0xE000_02C1)
    public static let exclusiveAccess = IOReturn(bitPattern: 0xE000_02C5)
    public static let unsupported = IOReturn(bitPattern: 0xE000_02C7)
    public static let noDevice = IOReturn(bitPattern: 0xE000_02C0)
    public static let notOpen = IOReturn(bitPattern: 0xE000_02CD)
    public static let timeout = IOReturn(bitPattern: 0xE000_02D6)
    public static let badArgument = IOReturn(bitPattern: 0xE000_02C2)
    public static let error = IOReturn(bitPattern: 0xE000_02BC)
    public static let noResources = IOReturn(bitPattern: 0xE000_02BE)
    public static let overrun = IOReturn(bitPattern: 0xE000_02E8)

    public static func describe(_ rc: IOReturn) -> String {
        let hex = String(format: "0x%08X", UInt32(bitPattern: rc))
        let name: String
        switch rc {
        case kIOReturnSuccess: name = "OK"
        case notPermitted: name = "kIOReturnNotPermitted – keine Berechtigung (Eingabeüberwachung?)"
        case notPrivileged: name = "kIOReturnNotPrivileged – Root/Berechtigung nötig"
        case exclusiveAccess: name = "kIOReturnExclusiveAccess – Gerät von anderem Prozess/Treiber exklusiv belegt"
        case unsupported: name = "kIOReturnUnsupported – vom Gerät nicht unterstützt"
        case noDevice: name = "kIOReturnNoDevice"
        case notOpen: name = "kIOReturnNotOpen"
        case timeout: name = "kIOReturnTimeout – Gerät antwortet nicht"
        case badArgument: name = "kIOReturnBadArgument"
        case error: name = "kIOReturnError"
        case noResources: name = "kIOReturnNoResources"
        case overrun: name = "kIOReturnOverrun"
        default: name = "unbekannt"
        }
        return "\(hex) (\(name))"
    }
}

// MARK: - Feature-Reports

public enum HIDFeature {
    /// GetReport(Feature) – liefert Return-Code und gelesene Bytes.
    public static func get(_ device: IOHIDDevice, reportID: UInt8, size: Int) -> (rc: IOReturn, bytes: [UInt8]) {
        var buf = [UInt8](repeating: 0, count: max(2, size))
        buf[0] = reportID
        var len = CFIndex(buf.count)
        let rc = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), &buf, &len)
        return (rc, rc == kIOReturnSuccess ? Array(buf.prefix(max(0, min(buf.count, Int(len))))) : [])
    }

    public static func set(_ device: IOHIDDevice, reportID: UInt8, bytes: [UInt8]) -> IOReturn {
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), bytes, CFIndex(bytes.count))
    }

    public static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// Input Mode laut Descriptor setzen (Multi-Touch = 2) und Vorher/Nachher protokollieren.
    @discardableResult
    public static func applyInputMode(_ device: IOHIDDevice, descriptor d: HIDDescriptor, name: String,
                                      log: (String) -> Void) -> IOReturn? {
        guard let im = d.inputModeReport(mode: 2) else {
            log("   Input Mode: kein Feature 0x0D/0x52 im Descriptor – nichts zu setzen")
            return nil
        }
        let size = max(im.bytes.count, 8)
        let ccm = d.contactCountMaximumField?.reportID
        func dumpFeatures(_ when: String) {
            let a = get(device, reportID: im.reportID, size: size)
            log(String(format: "   GetReport Feature 0x%02X (%@): ", im.reportID, when) + HIDReturn.describe(a.rc)
                + (a.bytes.isEmpty ? "" : " [\(hex(a.bytes))]"))
            if let c = ccm {
                let b = get(device, reportID: c, size: 8)
                log(String(format: "   GetReport Feature 0x%02X Contact Count Max (%@): ", c, when) + HIDReturn.describe(b.rc)
                    + (b.bytes.isEmpty ? "" : " [\(hex(b.bytes))]"))
            }
        }
        dumpFeatures("vorher")
        let rc = set(device, reportID: im.reportID, bytes: im.bytes)
        log(String(format: "   SetReport Feature 0x%02X [%@] (Input Mode 2 = Multi-Touch, Device Index 0): ", im.reportID, hex(im.bytes))
            + HIDReturn.describe(rc))
        dumpFeatures("nachher")
        return rc
    }
}

// MARK: - Diagnose aller HID-Interfaces eines Geräts

/// Öffnet alle HID-Interfaces (VID/PID) NICHT exklusiv, listet ihre Eigenschaften, setzt den Input Mode,
/// registriert für jedes Interface einen Input-Report-Callback und protokolliert Rohreports.
public final class HIDProbe {
    public static let anmiteVID = 0x27C0
    public static let anmitePID = 0x0859

    public struct Summary {
        public var interfaces = 0
        public var reports = 0
        public var lines: [String] = []
    }

    final class Interface {
        let index: Int
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let size: Int
        var count = 0
        var logged = 0
        var frames = 0
        var values = 0
        var valuesLogged = 0
        var assembler: TouchFrameAssembler?
        var openRC: IOReturn = kIOReturnSuccess
        var inputModeRC: IOReturn?
        weak var probe: HIDProbe?
        init(index: Int, device: IOHIDDevice, size: Int) {
            self.index = index; self.device = device; self.size = size
            buffer = .allocate(capacity: size)
        }
        deinit { buffer.deallocate() }
    }

    public let vid: Int?
    public let pid: Int?
    public var maxLinesPerInterface = 30
    private let log: (String) -> Void
    private var manager: IOHIDManager?
    private var interfaces: [Interface] = []

    public init(vid: Int? = HIDProbe.anmiteVID, pid: Int? = HIDProbe.anmitePID, log: @escaping (String) -> Void) {
        self.vid = vid; self.pid = pid; self.log = log
    }

    private static func prop(_ d: IOHIDDevice, _ key: String) -> Any? { IOHIDDeviceGetProperty(d, key as CFString) }

    private func copyDevices(_ match: [String: Any]) -> [IOHIDDevice] {
        guard let m = manager else { return [] }
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return [] }
        return set.sorted {
            (Self.prop($0, kIOHIDLocationIDKey) as? Int ?? 0, Self.prop($0, kIOHIDPrimaryUsagePageKey) as? Int ?? 0,
             Self.prop($0, kIOHIDPrimaryUsageKey) as? Int ?? 0)
                < (Self.prop($1, kIOHIDLocationIDKey) as? Int ?? 0, Self.prop($1, kIOHIDPrimaryUsagePageKey) as? Int ?? 0,
                   Self.prop($1, kIOHIDPrimaryUsageKey) as? Int ?? 0)
        }
    }

    /// Startet die Diagnose; nach `seconds` wird `completion` auf dem Main-Thread aufgerufen und alles geschlossen.
    public func run(seconds: Double = 10, completion: @escaping (Summary) -> Void) {
        log("— HID-Diagnose (nicht exklusiv, nur Lesen) —")
        log("Eingabeüberwachung: \(Permissions.inputMonitoringState)")
        // Manager nur zum Aufzählen; jedes Interface wird einzeln ohne Seize geöffnet und eingeplant.
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m

        var match: [String: Any] = [:]
        if let v = vid { match[kIOHIDVendorIDKey] = v }
        if let p = pid { match[kIOHIDProductIDKey] = p }
        var devs = copyDevices(match)
        if devs.isEmpty {
            log(String(format: "Keine HID-Interfaces mit VID 0x%04X / PID 0x%04X gefunden – suche alle Digitizer (Page 0x0D).",
                       vid ?? 0, pid ?? 0))
            devs = copyDevices([kIOHIDDeviceUsagePageKey: Int(Usage.pageDigitizer)])
        }
        log("Gefundene HID-Interfaces: \(devs.count)")

        for (i, d) in devs.enumerated() {
            let maxIn = Self.prop(d, kIOHIDMaxInputReportSizeKey) as? Int ?? 0
            let maxFeat = Self.prop(d, kIOHIDMaxFeatureReportSizeKey) as? Int ?? 0
            let loc = Self.prop(d, kIOHIDLocationIDKey) as? Int ?? 0
            let pairs = (Self.prop(d, kIOHIDDeviceUsagePairsKey) as? [[String: Any]] ?? []).map {
                String(format: "0x%02X/0x%02X", $0[kIOHIDDeviceUsagePageKey] as? Int ?? 0, $0[kIOHIDDeviceUsageKey] as? Int ?? 0)
            }
            log(String(format: "[IF %d] %@ – %@  VID 0x%04X PID 0x%04X", i,
                       (Self.prop(d, kIOHIDManufacturerKey) as? String ?? "?"), (Self.prop(d, kIOHIDProductKey) as? String ?? "?"),
                       Self.prop(d, kIOHIDVendorIDKey) as? Int ?? 0, Self.prop(d, kIOHIDProductIDKey) as? Int ?? 0))
            log(String(format: "   PrimaryUsagePage/Usage 0x%02X/0x%02X  DeviceUsagePairs [%@]",
                       Self.prop(d, kIOHIDPrimaryUsagePageKey) as? Int ?? 0, Self.prop(d, kIOHIDPrimaryUsageKey) as? Int ?? 0,
                       pairs.joined(separator: ", ")))
            log(String(format: "   MaxInputReportSize %d  MaxFeatureReportSize %d  Transport %@  LocationID 0x%08X",
                       maxIn, maxFeat, (Self.prop(d, kIOHIDTransportKey) as? String ?? "?"), loc))

            let iface = Interface(index: i, device: d, size: max(maxIn, 256))
            iface.probe = self
            iface.openRC = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
            log("   IOHIDDeviceOpen (ohne Seize): " + HIDReturn.describe(iface.openRC))

            if let data = Self.prop(d, kIOHIDReportDescriptorKey) as? Data {
                let desc = HIDDescriptor(bytes: [UInt8](data))
                log("   Descriptor \(data.count) Bytes: " + HIDFeature.hex([UInt8](data)))
                let asm = TouchFrameAssembler(descriptor: desc)
                for (rid, l) in asm.layouts.sorted(by: { $0.key < $1.key }) {
                    log("   Touch-Report \(rid): \(l.fingers.count) Finger-Slots, Contact Count: \(l.contactCount != nil ? "ja" : "nein")")
                }
                if !asm.layouts.isEmpty { iface.assembler = asm }
                iface.inputModeRC = HIDFeature.applyInputMode(d, descriptor: desc, name: "IF \(i)") { [weak self] in self?.log($0) }
            } else {
                log("   (kein Report-Descriptor lesbar)")
            }

            IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            let ctx = Unmanaged.passUnretained(iface).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(d, iface.buffer, iface.size, { ctx, result, _, _, rid, report, length in
                guard let ctx = ctx else { return }
                let f = Unmanaged<Interface>.fromOpaque(ctx).takeUnretainedValue()
                f.probe?.received(f, result: result, reportID: rid, UnsafeBufferPointer(start: report, count: length))
            }, ctx)
            // Zusätzlich Werte-Callback (falls Reports nicht als Ganzes ankommen)
            IOHIDDeviceRegisterInputValueCallback(d, { ctx, _, _, value in
                guard let ctx = ctx else { return }
                let f = Unmanaged<Interface>.fromOpaque(ctx).takeUnretainedValue()
                f.probe?.receivedValue(f, value)
            }, ctx)
            interfaces.append(iface)
        }
        log("Warte \(Int(seconds)) s auf Reports – bitte den Bildschirm mit mehreren Fingern berühren …")

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            completion(finish())
        }
    }

    private func receivedValue(_ f: Interface, _ v: IOHIDValue) {
        f.values += 1
        guard f.valuesLogged < maxLinesPerInterface else { return }
        f.valuesLogged += 1
        let e = IOHIDValueGetElement(v)
        log(String(format: "[IF %d] Wert #%d page 0x%02X usage 0x%02X = %ld", f.index, f.values,
                   IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e), IOHIDValueGetIntegerValue(v)))
    }

    private func received(_ f: Interface, result: IOReturn, reportID: UInt32, _ r: UnsafeBufferPointer<UInt8>) {
        f.count += 1
        var frameText = ""
        if var a = f.assembler {
            let fr = a.feed(r)
            f.assembler = a
            if let fr = fr {
                f.frames += 1
                frameText = fr.contacts.isEmpty ? "  -> 0 Finger"
                    : "  -> " + fr.contacts.map { "#\($0.id)(\($0.x),\($0.y))" }.joined(separator: " ")
            }
        }
        guard f.logged < maxLinesPerInterface else { return }
        f.logged += 1
        let head = Array(r.prefix(16))
        log(String(format: "[IF %d] Report #%d rid=%d len=%d%@: ", f.index, f.count, reportID, r.count,
                   result == kIOReturnSuccess ? "" : " rc=" + HIDReturn.describe(result)) + HIDFeature.hex(head) + frameText)
    }

    private func finish() -> Summary {
        var s = Summary()
        s.interfaces = interfaces.count
        s.reports = interfaces.reduce(0) { $0 + $1.count }
        s.lines.append("— Ergebnis HID-Diagnose —")
        s.lines.append("Eingabeüberwachung: \(Permissions.inputMonitoringState)")
        for f in interfaces {
            s.lines.append("[IF \(f.index)] Open: " + HIDReturn.describe(f.openRC)
                           + "  SetReport Input Mode: " + (f.inputModeRC.map(HIDReturn.describe) ?? "–")
                           + "  Reports: \(f.count)  Werte: \(f.values)  Touch-Frames: \(f.frames)")
        }
        s.lines.append("Empfangene Reports gesamt: \(s.reports)")
        if s.interfaces == 0 {
            s.lines.append("⚠️  KEIN passendes HID-Interface gefunden (Kabel/USB-C-Port prüfen, Touch-USB muss verbunden sein).")
        } else if s.reports == 0 {
            s.lines.append("⚠️  KEINE Reports in der Messzeit empfangen – Touch-Daten kommen bei TouchBridge nicht an.")
            if !Permissions.inputMonitoring {
                s.lines.append("   → Eingabeüberwachung fehlt: Systemeinstellungen › Datenschutz & Sicherheit › Eingabeüberwachung, TouchBridge erlauben, App neu starten.")
            } else {
                s.lines.append("   → Berechtigung ist erteilt. Mögliche Ursachen: Controller sendet erst nach passendem Input Mode,")
                s.lines.append("     ein anderer Treiber/Prozess belegt das Gerät exklusiv, oder die Daten laufen über ein anderes Interface.")
            }
        }
        for l in s.lines { log(l) }
        close()
        return s
    }

    public func close() {
        for f in interfaces {
            IOHIDDeviceRegisterInputReportCallback(f.device, f.buffer, f.size, nil, nil)
            IOHIDDeviceRegisterInputValueCallback(f.device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(f.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            if f.openRC == kIOReturnSuccess { IOHIDDeviceClose(f.device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        }
        manager = nil
        // Interfaces erst nach dem Runloop-Durchlauf freigeben (Callbacks sind abgemeldet)
        let keep = interfaces
        interfaces = []
        DispatchQueue.main.async { _ = keep }
    }
}

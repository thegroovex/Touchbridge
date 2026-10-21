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
        case notPermitted: name = "kIOReturnNotPermitted – no permission (Input Monitoring?)"
        case notPrivileged: name = "kIOReturnNotPrivileged – root/permission required"
        case exclusiveAccess: name = "kIOReturnExclusiveAccess – device held exclusively by another process/driver"
        case unsupported: name = "kIOReturnUnsupported – not supported by the device"
        case noDevice: name = "kIOReturnNoDevice"
        case notOpen: name = "kIOReturnNotOpen"
        case timeout: name = "kIOReturnTimeout – device not responding"
        case badArgument: name = "kIOReturnBadArgument"
        case error: name = "kIOReturnError"
        case noResources: name = "kIOReturnNoResources"
        case overrun: name = "kIOReturnOverrun"
        default: name = "unknown"
        }
        return "\(hex) (\(name))"
    }
}

// MARK: - Feature-Reports

public enum HIDFeature {
    /// GetReport(Feature) – liefert Return-Code und gelesene Bytes (genau `len` Bytes, wie von IOKit gemeldet).
    /// `size` = Feature-Report-Länge INKLUSIVE Report-ID-Byte laut Descriptor (Anmite 0x21: 3, 0x0A: 2).
    /// Ein zu großer Puffer lieferte am Anmite unsinnige Daten ([A1 01 21 03 …] statt [21 mode idx]).
    public static func get(_ device: IOHIDDevice, reportID: UInt8, size: Int) -> (rc: IOReturn, bytes: [UInt8]) {
        var buf = [UInt8](repeating: 0, count: max(1, size))
        buf[0] = reportID
        var len = CFIndex(buf.count)
        let rc = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), &buf, &len)
        return (rc, rc == kIOReturnSuccess ? Array(buf.prefix(max(0, min(buf.count, Int(len))))) : [])
    }

    /// GetReport mit Descriptor-Länge, als Logzeile
    public static func describeGet(_ device: IOHIDDevice, descriptor d: HIDDescriptor, reportID: UInt8, what: String) -> String {
        let size = d.featureReportLength(reportID)
        let a = get(device, reportID: reportID, size: size)
        return String(format: "   GetReport Feature 0x%02X %@ (buffer %d): ", reportID, what, size) + HIDReturn.describe(a.rc)
            + (a.bytes.isEmpty ? "" : " [\(hex(a.bytes))] (\(a.bytes.count) bytes)")
    }

    /// Einen Multitouch-Aktivierungsversuch ausführen (GetReports vorher, SetReport, Input Mode nachher lesen).
    @discardableResult
    public static func apply(_ step: MultitouchActivationStep, device: IOHIDDevice, descriptor d: HIDDescriptor,
                             log: (String) -> Void) -> IOReturn {
        for r in step.readFirst { log(describeGet(device, descriptor: d, reportID: r, what: "before")) }
        let rc = set(device, reportID: step.reportID, bytes: step.bytes)
        log(String(format: "   SetReport Feature 0x%02X [%@]: ", step.reportID, step.hex) + HIDReturn.describe(rc))
        log(describeGet(device, descriptor: d, reportID: step.reportID, what: "after"))
        return rc
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
            log("   Input Mode: no feature 0x0D/0x52 in descriptor – nothing to set")
            return nil
        }
        let ccm = d.contactCountMaximumField?.reportID
        func dumpFeatures(_ when: String) {
            // Contact Count Maximum zuerst lesen (Reihenfolge wie Linux hid-multitouch)
            if let c = ccm { log(describeGet(device, descriptor: d, reportID: c, what: "Contact Count Max (\(when))")) }
            log(describeGet(device, descriptor: d, reportID: im.reportID, what: "Input Mode (\(when))"))
        }
        dumpFeatures("before")
        let rc = set(device, reportID: im.reportID, bytes: im.bytes)
        log(String(format: "   SetReport Feature 0x%02X [%@] (Input Mode 2 = Multi-Touch, Device Index 0): ", im.reportID, hex(im.bytes))
            + HIDReturn.describe(rc))
        dumpFeatures("after")
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
        var count = 0
        var logged = 0
        var frames = 0
        var values = 0
        var valuesLogged = 0
        var assembler: TouchFrameAssembler?
        var openRC: IOReturn = kIOReturnSuccess
        var inputModeRC: IOReturn?
        /// vom Touch-Dienst bereits geöffnet – Diagnose hängt sich nur als Beobachter an
        var sharedWithService = false
        var observation: HIDInputHub.Observation?
        weak var probe: HIDProbe?
        init(index: Int, device: IOHIDDevice) {
            self.index = index; self.device = device
        }
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
        log("— HID diagnostics (non-exclusive, read-only) —")
        log("Input Monitoring: \(Permissions.inputMonitoringState)")
        // Manager nur zum Aufzählen; jedes Interface wird einzeln ohne Seize geöffnet und eingeplant.
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m

        var match: [String: Any] = [:]
        if let v = vid { match[kIOHIDVendorIDKey] = v }
        if let p = pid { match[kIOHIDProductIDKey] = p }
        var devs = copyDevices(match)
        if devs.isEmpty {
            log(String(format: "No HID interfaces with VID 0x%04X / PID 0x%04X found – searching all digitizers (page 0x0D).",
                       vid ?? 0, pid ?? 0))
            devs = copyDevices([kIOHIDDeviceUsagePageKey: Int(Usage.pageDigitizer)])
        }
        log("HID interfaces found: \(devs.count)")

        // ein IOHIDDevice-Objekt pro Interface (prozessweit), doppelte Treffer verwerfen
        var seen = Set<UInt64>()
        devs = devs.map { HIDOpenRegistry.shared.canonical($0) }.filter { c in
            guard let id = c.id else { return true }
            return seen.insert(id).inserted
        }.map { $0.device }
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
            log(String(format: "   MaxInputReportSize %d  MaxFeatureReportSize %d  Transport %@  LocationID 0x%08X  RegistryID 0x%llX",
                       maxIn, maxFeat, (Self.prop(d, kIOHIDTransportKey) as? String ?? "?"), loc,
                       HIDOpenRegistry.registryID(d) ?? 0))

            let iface = Interface(index: i, device: d)
            iface.probe = self
            if HIDOpenRegistry.shared.isOpen(d) {
                // Touch-Dienst hält das Interface: nicht neu öffnen, nur zusätzlich beobachten
                iface.sharedWithService = true
                iface.openRC = kIOReturnSuccess
                log("   already opened by the touch service (" + (HIDOpenRegistry.shared.tracker.isExclusive(HIDOpenRegistry.registryID(d) ?? 0) ? "exclusive" : "non-exclusive")
                    + ") – diagnostics observes alongside")
            } else {
                iface.openRC = HIDOpenRegistry.shared.open(d, seize: false)
                log("   IOHIDDeviceOpen (without seize): " + HIDReturn.describe(iface.openRC))
            }

            if let data = Self.prop(d, kIOHIDReportDescriptorKey) as? Data {
                let desc = HIDDescriptor(bytes: [UInt8](data))
                log("   Descriptor \(data.count) bytes: " + HIDFeature.hex([UInt8](data)))
                let asm = TouchFrameAssembler(descriptor: desc, pointerFallback: true)
                for (rid, l) in asm.layouts.sorted(by: { $0.key < $1.key }) {
                    log(l.isPointer ? "   Report \(rid): absolute mouse (X/Y absolute, button 1) – single-touch source"
                        : "   Touch report \(rid): \(l.fingers.count) finger slots, contact count: \(l.contactCount != nil ? "yes" : "no")")
                }
                if !asm.layouts.isEmpty { iface.assembler = asm }
                if iface.sharedWithService {
                    // Input Mode steuert der Touch-Dienst (Multitouch-Versuche); hier nur lesen
                    if let im = desc.inputModeReport() {
                        log(HIDFeature.describeGet(d, descriptor: desc, reportID: im.reportID, what: "Input Mode"))
                    }
                } else {
                    iface.inputModeRC = HIDFeature.applyInputMode(d, descriptor: desc, name: "IF \(i)") { [weak self] in self?.log($0) }
                }
            } else {
                log("   (no readable report descriptor)")
            }

            // Reports + Werte über den prozessweiten Hub (eine IOKit-Registrierung je Gerät, gemeinsam mit dem Touch-Dienst)
            iface.observation = HIDInputHub.shared.observe(d, owner: iface, values: true) { f, event in
                switch event {
                case let .report(rid, bytes, result): f.probe?.received(f, result: result, reportID: rid, bytes)
                case let .value(v): f.probe?.receivedValue(f, v)
                }
            }
            interfaces.append(iface)
        }
        log("Waiting \(Int(seconds)) s for reports – please touch the screen with several fingers …")

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            completion(finish())
        }
    }

    private func receivedValue(_ f: Interface, _ v: IOHIDValue) {
        f.values += 1
        guard f.valuesLogged < maxLinesPerInterface else { return }
        f.valuesLogged += 1
        let e = IOHIDValueGetElement(v)
        log(String(format: "[IF %d] value #%d page 0x%02X usage 0x%02X = %ld", f.index, f.values,
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
                frameText = fr.contacts.isEmpty ? "  -> 0 fingers"
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
        s.lines.append("— HID diagnostics result —")
        s.lines.append("Input Monitoring: \(Permissions.inputMonitoringState)")
        for f in interfaces {
            s.lines.append("[IF \(f.index)] Open: " + HIDReturn.describe(f.openRC)
                           + "  SetReport Input Mode: " + (f.inputModeRC.map(HIDReturn.describe) ?? "–")
                           + "  Reports: \(f.count)  values: \(f.values)  touch frames: \(f.frames)")
        }
        s.lines.append("Total reports received: \(s.reports)")
        if s.interfaces == 0 {
            s.lines.append("⚠️  NO matching HID interface found (check cable/USB-C port; the touch USB must be connected).")
        } else if s.reports == 0 {
            s.lines.append("⚠️  NO reports received during the measurement – touch data is not reaching TouchBridge.")
            if !Permissions.inputMonitoring {
                s.lines.append("   → Input Monitoring missing: System Settings › Privacy & Security › Input Monitoring, allow TouchBridge, restart the app.")
            } else {
                s.lines.append("   → Permission is granted. Possible causes: the controller only sends after the right Input Mode,")
                s.lines.append("     another driver/process holds the device exclusively, or the data arrives on a different interface.")
            }
        }
        for l in s.lines { log(l) }
        close()
        return s
    }

    public func close() {
        for f in interfaces {
            f.observation?.cancel()
            f.observation = nil
            // nur schließen, was die Diagnose selbst geöffnet hat
            if f.openRC == kIOReturnSuccess && !f.sharedWithService { HIDOpenRegistry.shared.close(f.device) }
        }
        manager = nil
        interfaces = []
    }
}

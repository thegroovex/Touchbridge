import CoreGraphics
import Foundation
import IOKit
import TouchBridgeCore

/// Bildsteuerung: Helligkeit, Kontrast, Lautstärke per DDC/CI (Apple Silicon, über IOAVService),
/// sonst Helligkeit per Software-Dimmen (Gamma-Tabelle).
public final class DisplayControl {
    public enum Feature: CaseIterable {
        case brightness, contrast, volume
        var vcp: UInt8 {
            switch self {
            case .brightness: return DDC.VCP.brightness.rawValue
            case .contrast: return DDC.VCP.contrast.rawValue
            case .volume: return DDC.VCP.volume.rawValue
            }
        }
        public var title: String {
            switch self {
            case .brightness: return L("Brightness", "Helligkeit")
            case .contrast: return L("Contrast", "Kontrast")
            case .volume: return L("Volume", "Lautstärke")
            }
        }
    }

    public let display: CGDirectDisplayID
    /// DDC nutzbar: aktuelle Probe erfolgreich ODER für diesen Monitor schon einmal erfolgreich gewesen.
    public var hasDDC: Bool { av != nil && (probeOK || DisplayControl.rememberedDDC(display)) }
    /// Letzte Probe hat geantwortet
    public private(set) var probeOK = false
    public private(set) var probing = false
    /// Anzahl gefundener DCPAVServiceProxy-Dienste mit Location = External
    public private(set) var serviceCount = 0
    /// Details der letzten Probe (Return-Codes, Rohantwort) für die Diagnose
    public private(set) var probeDetails: [String] = []
    /// Software-Helligkeit 0.2…1.0 (Gamma), wirkt zusätzlich zur Hardware-Helligkeit.
    public private(set) var softwareBrightness: Double = 1.0
    private var maxValues: [Feature: UInt16] = [:]
    private let av: AVService?
    private let queue = DispatchQueue(label: "touchbridge.ddc")
    private var pending: [Feature: Int] = [:]

    /// Sucht den DDC-Dienst und probt sofort (blockierend, bis ~5 Versuche – nicht auf dem Main-Thread aufrufen).
    /// Der Dienst wird auch bei fehlgeschlagener Probe behalten, damit später erneut geprobt werden kann.
    public init(display: CGDirectDisplayID, probeNow: Bool = true) {
        self.display = display
        let found = AVService.forDisplay(display)
        av = found.service
        serviceCount = found.count
        if probeNow { runProbe() }
    }

    private static func memoryKey(_ id: CGDirectDisplayID) -> String {
        "ddcOK-\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }
    public static func rememberedDDC(_ id: CGDirectDisplayID) -> Bool { UserDefaults.standard.bool(forKey: memoryKey(id)) }
    public static func forgetDDC(_ id: CGDirectDisplayID) { UserDefaults.standard.removeObject(forKey: memoryKey(id)) }

    private func runProbe() {
        var lines = [String(format: "DDC: Bildschirm %u (Vendor 0x%04X, Modell 0x%04X), DCPAVServiceProxy External: %d, Dienst zugeordnet: %@",
                            display, CGDisplayVendorNumber(display), CGDisplayModelNumber(display), serviceCount,
                            av == nil ? "nein" : "ja")]
        if CGDisplayIsBuiltin(display) != 0 { lines.append("DDC: interner Bildschirm – kein DDC") }
        var ok = false
        if let av = av {
            let r = av.readVCPTraced(DDC.VCP.brightness.rawValue, attempts: 5)
            lines += r.trace
            if let v = r.value {
                ok = true
                maxValues[.brightness] = v.max
                UserDefaults.standard.set(true, forKey: DisplayControl.memoryKey(display))
            }
        }
        lines.append("DDC-Probe: " + (ok ? "OK" : "keine Antwort") + (DisplayControl.rememberedDDC(display) ? " (früher schon erfolgreich – Regler bleiben)" : ""))
        probeOK = ok
        probeDetails = lines
    }

    /// Erneut asynchron proben (z. B. beim Öffnen des Menüs oder nach Bildschirmwechsel). completion auf dem Main-Thread.
    public func probe(completion: @escaping (Bool) -> Void) {
        guard !probing else { return }
        probing = true
        queue.async {
            self.runProbe()
            let ok = self.probeOK
            DispatchQueue.main.async { self.probing = false; completion(ok) }
        }
    }

    /// Liest den aktuellen Wert (0…100) asynchron; Ergebnis auf dem Main-Thread. nil = nicht unterstützt.
    public func read(_ f: Feature, completion: @escaping (Int?) -> Void) {
        guard let av = av else { DispatchQueue.main.async { completion(nil) }; return }
        queue.async {
            var result: Int? = nil
            for _ in 0..<3 {
                if let r = av.readVCP(f.vcp), r.max > 0 {
                    self.maxValues[f] = r.max
                    result = Int((Double(r.current) / Double(r.max) * 100).rounded())
                    break
                }
                usleep(30_000)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Setzt einen Wert (0…100). Schnelle Folgen (Slider) werden zusammengefasst.
    public func set(_ f: Feature, percent: Int) {
        guard let av = av else { return }
        let p = max(0, min(100, percent))
        queue.async {
            let isFirst = self.pending[f] == nil
            self.pending[f] = p
            guard isFirst else { return }
            self.queue.asyncAfter(deadline: .now() + 0.05) {
                guard let v = self.pending.removeValue(forKey: f) else { return }
                let mx = Double(self.maxValues[f] ?? 100)
                _ = av.writeVCP(f.vcp, value: UInt16((Double(v) / 100 * mx).rounded()))
            }
        }
    }

    /// Software-Dimmen über die Gamma-Tabelle (funktioniert mit jedem Bildschirm).
    public func setSoftwareBrightness(_ v: Double) {
        softwareBrightness = max(0.2, min(1.0, v))
        if softwareBrightness >= 0.999 {
            CGDisplayRestoreColorSyncSettings()
            return
        }
        let m = CGGammaValue(softwareBrightness)
        CGSetDisplayTransferByFormula(display, 0, m, 1, 0, m, 1, 0, m, 1)
    }

    public static func restoreAllGamma() { CGDisplayRestoreColorSyncSettings() }
}

// MARK: - IOAVService (private API, nur Apple Silicon) – zur Laufzeit per dlsym geladen

final class AVService {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let create: CreateFn? = sym("IOAVServiceCreateWithService")
    private static let readI2C: I2CFn? = sym("IOAVServiceReadI2C")
    private static let writeI2C: I2CFn? = sym("IOAVServiceWriteI2C")

    private static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private let ref: CFTypeRef

    private init(ref: CFTypeRef) { self.ref = ref }

    /// Externe DCP-AV-Dienste in Registry-Reihenfolge.
    static func externalServices() -> [AVService] {
        guard let create = create else { return [] }
        var out: [AVService] = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var s = IOIteratorNext(iter)
        while s != 0 {
            defer { IOObjectRelease(s); s = IOIteratorNext(iter) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard loc == "External", let r = create(kCFAllocatorDefault, s)?.takeRetainedValue() else { continue }
            out.append(AVService(ref: r))
        }
        return out
    }

    /// Ordnet externe Bildschirme den Diensten der Reihe nach zu (bei einem externen Monitor eindeutig).
    /// Ohne Probe – ob der Monitor antwortet, entscheidet DisplayControl (mit Wiederholungen).
    static func forDisplay(_ id: CGDirectDisplayID) -> (service: AVService?, count: Int) {
        let services = externalServices()
        guard CGDisplayIsBuiltin(id) == 0, !services.isEmpty else { return (nil, services.count) }
        let ext = Displays.externalIDs()
        let idx = ext.firstIndex(of: id) ?? 0
        return (services[min(idx, services.count - 1)], services.count)
    }

    /// Wie readVCP, mit Protokoll (Write-/Read-Return-Codes, Rohantwort) und längeren Pausen.
    func readVCPTraced(_ vcp: UInt8, attempts: Int) -> (value: (current: UInt16, max: UInt16)?, trace: [String]) {
        guard let w = AVService.writeI2C, let r = AVService.readI2C else {
            return (nil, ["DDC: IOAVServiceWriteI2C/ReadI2C nicht verfügbar (Intel-Mac?)"])
        }
        var trace: [String] = []
        var req = DDC.getPacket(vcp: vcp)
        for i in 1...max(1, attempts) {
            let wr = req.withUnsafeMutableBytes { w(ref, DDC.chipAddress, DDC.dataAddress, $0.baseAddress!, UInt32($0.count)) }
            guard wr == kIOReturnSuccess else {
                trace.append("DDC Versuch \(i): Write " + HIDReturn.describe(wr))
                usleep(100_000); continue
            }
            usleep(80_000)
            var buf = [UInt8](repeating: 0, count: 12)
            let rr = buf.withUnsafeMutableBytes { r(ref, DDC.chipAddress, DDC.dataAddress, $0.baseAddress!, UInt32($0.count)) }
            let v = rr == kIOReturnSuccess ? DDC.parseReply(buf, vcp: vcp) : nil
            trace.append("DDC Versuch \(i): Write OK, Read " + HIDReturn.describe(rr) + " Antwort [" + HIDFeature.hex(buf) + "]"
                         + (v.map { " -> \($0.current)/\($0.max)" } ?? " (ungültig)"))
            if let v = v { return (v, trace) }
            usleep(100_000)
        }
        return (nil, trace)
    }

    func writeVCP(_ vcp: UInt8, value: UInt16) -> Bool {
        guard let w = AVService.writeI2C else { return false }
        var p = DDC.setPacket(vcp: vcp, value: value)
        var ok = false
        for _ in 0..<2 {
            ok = p.withUnsafeMutableBytes { w(ref, DDC.chipAddress, DDC.dataAddress, $0.baseAddress!, UInt32($0.count)) } == kIOReturnSuccess
            usleep(10_000)
        }
        return ok
    }

    func readVCP(_ vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let w = AVService.writeI2C, let r = AVService.readI2C else { return nil }
        var req = DDC.getPacket(vcp: vcp)
        for _ in 0..<3 {
            let wr = req.withUnsafeMutableBytes { w(ref, DDC.chipAddress, DDC.dataAddress, $0.baseAddress!, UInt32($0.count)) }
            guard wr == kIOReturnSuccess else { usleep(20_000); continue }
            usleep(40_000)
            var buf = [UInt8](repeating: 0, count: 12)
            let rr = buf.withUnsafeMutableBytes { r(ref, DDC.chipAddress, DDC.dataAddress, $0.baseAddress!, UInt32($0.count)) }
            if rr == kIOReturnSuccess, let v = DDC.parseReply(buf, vcp: vcp) { return v }
            usleep(20_000)
        }
        return nil
    }
}

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
            case .brightness: return "Helligkeit"
            case .contrast: return "Kontrast"
            case .volume: return "Lautstärke"
            }
        }
    }

    public let display: CGDirectDisplayID
    public private(set) var hasDDC = false
    /// Software-Helligkeit 0.2…1.0 (Gamma), wirkt zusätzlich zur Hardware-Helligkeit.
    public private(set) var softwareBrightness: Double = 1.0
    private var maxValues: [Feature: UInt16] = [:]
    private let av: AVService?
    private let queue = DispatchQueue(label: "touchbridge.ddc")
    private var pending: [Feature: Int] = [:]

    public init(display: CGDirectDisplayID) {
        self.display = display
        av = AVService.forDisplay(display)
        hasDDC = av != nil
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
    static func forDisplay(_ id: CGDirectDisplayID) -> AVService? {
        guard CGDisplayIsBuiltin(id) == 0 else { return nil }
        let services = externalServices()
        guard !services.isEmpty else { return nil }
        let ext = Displays.externalIDs()
        let idx = ext.firstIndex(of: id) ?? 0
        let candidate = services[min(idx, services.count - 1)]
        // Nur behalten, wenn der Monitor tatsächlich auf DDC antwortet.
        return candidate.readVCP(DDC.VCP.brightness.rawValue) != nil ? candidate : nil
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

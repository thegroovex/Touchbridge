import Foundation

// MARK: - Minimal HID report descriptor parser
// Liest den Report-Descriptor des Touch-Controllers und berechnet für jedes
// Input-Feld (X, Y, Tip Switch, Contact ID, Contact Count ...) die Bit-Position
// im Report. Damit sind wir unabhängig davon, welcher Chip (ILITEK, Goodix,
// EETI, ...) im Monitor steckt, solange er ein Standard-HID-Multitouch-Digitizer ist.

public struct HIDField {
    public let reportID: UInt8
    public let bitOffset: Int        // Offset im Report-Payload (ohne Report-ID-Byte)
    public let bitSize: Int
    public let usagePage: UInt32
    public let usage: UInt32
    public let logicalMin: Int64
    public let logicalMax: Int64
    public let isVariable: Bool
    public let isConstant: Bool
    public let collectionPath: [Int] // Collection-IDs, außen -> innen

    public func read(_ report: UnsafeBufferPointer<UInt8>, base: Int) -> Int64 {
        guard bitSize > 0, bitSize <= 63 else { return 0 }
        var v: UInt64 = 0
        for b in 0..<bitSize {
            let bit = bitOffset + b
            let idx = base + bit / 8
            if idx >= report.count { break }
            if (report[idx] >> UInt8(bit % 8)) & 1 == 1 { v |= (UInt64(1) << UInt64(b)) }
        }
        if logicalMin < 0, (v >> UInt64(bitSize - 1)) & 1 == 1 {
            v |= ~((UInt64(1) << UInt64(bitSize)) - 1) // Vorzeichen erweitern
        }
        return Int64(bitPattern: v)
    }

    public var describe: String {
        String(format: "rid=%d off=%d size=%d page=0x%02X usage=0x%02X range=%lld..%lld",
               reportID, bitOffset, bitSize, usagePage, usage, logicalMin, logicalMax)
    }
}

public struct HIDCollection {
    public let id: Int
    public let usagePage: UInt32
    public let usage: UInt32
    public let type: UInt32
}

public struct HIDDescriptor {
    public private(set) var fields: [HIDField] = []
    public private(set) var collections: [HIDCollection] = []
    public private(set) var usesReportIDs = false

    public init(bytes: [UInt8]) {
        struct Globals {
            var usagePage: UInt32 = 0
            var logMin: Int64 = 0
            var logMaxSigned: Int64 = 0
            var logMaxUnsigned: Int64 = 0
            var reportSize = 0
            var reportCount = 0
            var reportID: UInt8 = 0
        }
        var g = Globals()
        var globalStack: [Globals] = []
        var usages: [(UInt32, Int)] = []
        var usageMin: (UInt32, Int)? = nil
        var usageMax: (UInt32, Int)? = nil
        var collStack: [Int] = []
        var inputOffsets: [UInt8: Int] = [:]

        func resolve(_ u: (UInt32, Int)) -> UInt32 {
            u.1 == 4 ? u.0 : ((g.usagePage << 16) | (u.0 & 0xFFFF))
        }
        func resolvedUsages() -> [UInt32] {
            var list = usages.map(resolve)
            if let mn = usageMin, let mx = usageMax {
                let a = resolve(mn), b = resolve(mx)
                if b >= a, b - a < 1024 { for u in a...b { list.append(u) } }
            }
            return list
        }
        func clearLocals() { usages = []; usageMin = nil; usageMax = nil }

        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]; i += 1
            if prefix == 0xFE { // Long Item
                guard i < bytes.count else { break }
                i += 2 + Int(bytes[i]); continue
            }
            var size = Int(prefix & 0x03); if size == 3 { size = 4 }
            let type = (prefix >> 2) & 0x03
            let tag = (prefix >> 4) & 0x0F
            guard i + size <= bytes.count else { break }
            var u: UInt32 = 0
            for k in 0..<size { u |= UInt32(bytes[i + k]) << UInt32(8 * k) }
            i += size
            let s: Int64
            switch size {
            case 1: s = Int64(Int8(truncatingIfNeeded: u))
            case 2: s = Int64(Int16(truncatingIfNeeded: u))
            case 4: s = Int64(Int32(truncatingIfNeeded: u))
            default: s = 0
            }

            switch type {
            case 0: // Main
                switch tag {
                case 0x8: // Input
                    let isConst = (u & 0x1) != 0
                    let isVar = (u & 0x2) != 0
                    let list = resolvedUsages()
                    var off = inputOffsets[g.reportID] ?? 0
                    let lmin = g.logMin
                    let lmax = g.logMaxSigned < lmin ? g.logMaxUnsigned : g.logMaxSigned
                    for n in 0..<max(0, g.reportCount) {
                        let usage: UInt32 = list.isEmpty ? 0 : (isVar ? list[min(n, list.count - 1)] : list[0])
                        fields.append(HIDField(reportID: g.reportID, bitOffset: off, bitSize: g.reportSize,
                                               usagePage: usage >> 16, usage: usage & 0xFFFF,
                                               logicalMin: lmin, logicalMax: lmax,
                                               isVariable: isVar, isConstant: isConst,
                                               collectionPath: collStack))
                        off += g.reportSize
                    }
                    inputOffsets[g.reportID] = off
                case 0xA: // Collection
                    let list = resolvedUsages()
                    let usage = list.first ?? 0
                    let c = HIDCollection(id: collections.count, usagePage: usage >> 16, usage: usage & 0xFFFF, type: u)
                    collections.append(c)
                    collStack.append(c.id)
                case 0xC: // End Collection
                    _ = collStack.popLast()
                default: break // Output / Feature: für Input-Offsets irrelevant
                }
                clearLocals()
            case 1: // Global
                switch tag {
                case 0x0: g.usagePage = u
                case 0x1: g.logMin = s
                case 0x2: g.logMaxSigned = s; g.logMaxUnsigned = Int64(u)
                case 0x7: g.reportSize = Int(u)
                case 0x8: g.reportID = UInt8(truncatingIfNeeded: u); usesReportIDs = true
                case 0x9: g.reportCount = Int(u)
                case 0xA: globalStack.append(g)
                case 0xB: if let p = globalStack.popLast() { g = p }
                default: break
                }
            case 2: // Local
                switch tag {
                case 0x0: usages.append((u, size))
                case 0x1: usageMin = (u, size)
                case 0x2: usageMax = (u, size)
                default: break
                }
            default: break
            }
        }
    }
}

// MARK: - Touch layout (Finger-Slots pro Report)

public enum Usage {
    public static let pageGenericDesktop: UInt32 = 0x01
    public static let pageDigitizer: UInt32 = 0x0D
    public static let x: UInt32 = 0x30
    public static let y: UInt32 = 0x31
    public static let touchScreen: UInt32 = 0x04
    public static let finger: UInt32 = 0x22
    public static let tipSwitch: UInt32 = 0x42
    public static let confidence: UInt32 = 0x47
    public static let contactID: UInt32 = 0x51
    public static let contactCount: UInt32 = 0x54
}

public struct FingerSlot {
    public var tip: HIDField?
    public var contactID: HIDField?
    public var x: HIDField?
    public var y: HIDField?
    public var confidence: HIDField?
}

public struct TouchLayout {
    public let reportID: UInt8
    public var fingers: [FingerSlot]
    public var contactCount: HIDField?

    public static func build(from d: HIDDescriptor) -> [UInt8: TouchLayout] {
        let colls = d.collections
        func isFinger(_ id: Int) -> Bool {
            colls[id].usagePage == Usage.pageDigitizer && colls[id].usage == Usage.finger
        }
        func isTouchScreen(_ path: [Int]) -> Bool {
            path.contains { colls[$0].usagePage == Usage.pageDigitizer && colls[$0].usage == Usage.touchScreen }
        }
        let hasTouchScreen = d.fields.contains { isTouchScreen($0.collectionPath) }

        var slots: [UInt8: [Int: FingerSlot]] = [:]
        var counts: [UInt8: HIDField] = [:]
        for f in d.fields where !f.isConstant && f.isVariable {
            if hasTouchScreen && !isTouchScreen(f.collectionPath) { continue }
            if f.usagePage == Usage.pageDigitizer && f.usage == Usage.contactCount {
                counts[f.reportID] = f; continue
            }
            guard let fingerColl = f.collectionPath.last(where: isFinger) else { continue }
            var slot = slots[f.reportID, default: [:]][fingerColl] ?? FingerSlot()
            switch (f.usagePage, f.usage) {
            case (Usage.pageDigitizer, Usage.tipSwitch): slot.tip = slot.tip ?? f
            case (Usage.pageDigitizer, Usage.contactID): slot.contactID = slot.contactID ?? f
            case (Usage.pageDigitizer, Usage.confidence): slot.confidence = slot.confidence ?? f
            case (Usage.pageGenericDesktop, Usage.x): slot.x = slot.x ?? f
            case (Usage.pageGenericDesktop, Usage.y): slot.y = slot.y ?? f
            default: break
            }
            slots[f.reportID, default: [:]][fingerColl] = slot
        }
        var result: [UInt8: TouchLayout] = [:]
        for (rid, dict) in slots {
            let fingers = dict.keys.sorted().compactMap { dict[$0] }.filter { $0.x != nil && $0.y != nil }
            if fingers.isEmpty { continue }
            result[rid] = TouchLayout(reportID: rid, fingers: fingers, contactCount: counts[rid])
        }
        return result
    }
}

// MARK: - Frame-Zusammenbau (inkl. Hybrid-Modus)

/// Ein Kontakt in logischen Digitizer-Koordinaten.
public struct RawContact: Equatable {
    public let id: Int
    public let x: Int64
    public let y: Int64
    public init(id: Int, x: Int64, y: Int64) { self.id = id; self.x = x; self.y = y }
}

/// Setzt HID-Input-Reports zu vollständigen Touch-Frames zusammen.
/// Hybrid-Modus: Contact Count > 0 startet einen neuen Frame, Folge-Reports
/// mit Count 0 liefern weitere Finger desselben Frames.
public struct TouchFrameAssembler {
    public let layouts: [UInt8: TouchLayout]
    public let usesReportIDs: Bool
    private var frame: [Int: RawContact] = [:]
    private var expected = 0
    private var collected = 0

    public init(descriptor: HIDDescriptor) {
        layouts = TouchLayout.build(from: descriptor)
        usesReportIDs = descriptor.usesReportIDs
    }

    public mutating func reset() { frame = [:]; expected = 0; collected = 0 }

    /// Liefert einen fertigen Frame (aktive Kontakte nach ID sortiert) oder nil, solange er unvollständig ist.
    public mutating func feed(_ r: UnsafeBufferPointer<UInt8>) -> (layout: TouchLayout, contacts: [RawContact])? {
        guard r.count > 0 else { return nil }
        let rid: UInt8 = usesReportIDs ? r[0] : 0
        guard let layout = layouts[rid] else { return nil }
        let base = usesReportIDs ? 1 : 0

        if let cc = layout.contactCount {
            let count = Int(cc.read(r, base: base))
            if count > 0 {
                expected = count; collected = 0; frame = [:]
            } else if collected >= expected {
                reset()
                return (layout, [])
            }
        } else {
            expected = layout.fingers.count; collected = 0; frame = [:]
        }

        for (i, slot) in layout.fingers.enumerated() {
            if collected >= expected { break }
            collected += 1
            let tip = slot.tip.map { $0.read(r, base: base) != 0 } ?? true
            if let conf = slot.confidence, layout.contactCount == nil, conf.read(r, base: base) == 0 { continue }
            guard tip, let xf = slot.x, let yf = slot.y else { continue }
            let id = slot.contactID.map { Int($0.read(r, base: base)) } ?? i
            frame[id] = RawContact(id: id, x: xf.read(r, base: base), y: yf.read(r, base: base))
        }
        guard collected >= expected else { return nil }
        return (layout, frame.keys.sorted().map { frame[$0]! })
    }

    public mutating func feed(_ bytes: [UInt8]) -> (layout: TouchLayout, contacts: [RawContact])? {
        bytes.withUnsafeBufferPointer { feed($0) }
    }
}

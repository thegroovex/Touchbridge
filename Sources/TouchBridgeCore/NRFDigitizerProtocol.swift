import CoreGraphics
import Foundation

// MARK: - nRF52840 digitizer dongle: serial protocol (firmware/nrf-digitizer/PROTOCOL.md)
// TouchBridge forwards finger frames over USB CDC ACM to the dongle, which reports them to macOS as a
// real USB HID touch screen. Pure encoding/decoding here; the serial port lives in TouchBridgeKit.

public enum NRFDigitizer {
    public static let vendorID = 0x2FE3
    public static let productID = 0x0010
    public static let productName = "TouchBridge Digitizer"
    public static let protocolVersion: UInt8 = 1
    public static let maxContacts = 10
    public static let coordinateMax = 32767
    public static let sync: UInt8 = 0xA5
    public static let maxPayload = 64
    /// The dongle lifts all contacts after this long without a frame; the host repeats frames faster.
    public static let releaseTimeout = 0.2
    public static let keepAliveInterval = 0.1
    /// Fastest frame rate the host sends
    public static let maxRate = 120.0

    public enum MessageType: UInt8 {
        case touch = 0x01, hello = 0x02, releaseAll = 0x03, bootloader = 0x04
        case helloReply = 0x82, error = 0x8F
    }

    public enum Flag {
        public static let tip: UInt8 = 0x01
        public static let confidence: UInt8 = 0x02
    }

    /// HID report descriptor of the dongle – identical to firmware/nrf-digitizer/src/hid_report_desc.inc
    /// (checked by the tests). Touch screen, 10 contacts in one 64-byte report (ID 1), feature report 2 =
    /// Contact Count Maximum.
    public static let reportDescriptor: [UInt8] = {
        var d: [UInt8] = [0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01]
        let finger: [UInt8] = [
            0x05, 0x0D, 0x09, 0x22, 0xA1, 0x02,
            0x09, 0x42, 0x09, 0x47, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x02, 0x81, 0x02,
            0x95, 0x06, 0x81, 0x03,
            0x09, 0x51, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
            0xA4, 0x05, 0x01, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x55, 0x0E, 0x65, 0x11, 0x35, 0x00,
            0x46, 0xC8, 0x0B, 0x09, 0x30, 0x81, 0x02,
            0x46, 0x5D, 0x07, 0x09, 0x31, 0x81, 0x02,
            0xB4, 0xC0,
        ]
        for _ in 0..<maxContacts { d += finger }
        d += [
            0xA4, 0x55, 0x0C, 0x66, 0x01, 0x10, 0x47, 0xFF, 0xFF, 0x00, 0x00, 0x27, 0xFF, 0xFF, 0x00, 0x00,
            0x75, 0x10, 0x95, 0x01, 0x09, 0x56, 0x81, 0x02, 0xB4,
            0x09, 0x54, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
            0x85, 0x02, 0x09, 0x55, 0x25, 0x0A, 0xB1, 0x02,
            0xC0,
        ]
        return d
    }()

    /// CRC-8/SMBUS: polynomial 0x07, init 0x00, no reflection
    public static func crc8<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        var crc: UInt8 = 0
        for b in bytes {
            crc ^= b
            for _ in 0..<8 { crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    /// sync, LEN, payload, CRC over LEN + payload
    public static func frame(_ payload: [UInt8]) -> [UInt8] {
        precondition(!payload.isEmpty && payload.count <= maxPayload)
        let len = UInt8(payload.count)
        return [sync, len] + payload + [crc8([len] + payload)]
    }

    public static func helloFrame() -> [UInt8] { frame([MessageType.hello.rawValue]) }
    public static func releaseAllFrame() -> [UInt8] { frame([MessageType.releaseAll.rawValue]) }
    public static func bootloaderFrame() -> [UInt8] { frame([MessageType.bootloader.rawValue]) }

    /// TOUCH frame; at most `maxContacts` contacts (extra ones are dropped).
    public static func touchFrame(_ contacts: [DigitizerContact]) -> [UInt8] {
        let list = Array(contacts.prefix(maxContacts))
        var p: [UInt8] = [MessageType.touch.rawValue, protocolVersion, UInt8(list.count)]
        for c in list {
            let x = UInt16(min(coordinateMax, Int(c.x))), y = UInt16(min(coordinateMax, Int(c.y)))
            p += [c.id & 0x7F, (c.tip ? Flag.tip : 0) | Flag.confidence,
                  UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)]
        }
        return frame(p)
    }

    /// Normalized 0…1 → 0…32767 (clamped)
    public static func coordinate(_ v: CGFloat) -> UInt16 {
        guard v.isFinite else { return 0 }
        return UInt16((min(1, max(0, v)) * CGFloat(coordinateMax)).rounded())
    }
}

public struct DigitizerContact: Equatable {
    public var id: UInt8
    public var tip: Bool
    public var x: UInt16
    public var y: UInt16
    public init(id: UInt8, tip: Bool, x: UInt16, y: UInt16) {
        self.id = id; self.tip = tip; self.x = x; self.y = y
    }
}

/// Firmware identity from HELLO_REPLY
public struct DigitizerHello: Equatable {
    public let protocolVersion: UInt8
    public let major: UInt8
    public let minor: UInt8
    public let patch: UInt8
    public let maxContacts: UInt8
    public let variant: UInt8
    public let flags: UInt8
    public let loadAddress: UInt32

    public var version: String { "\(major).\(minor).\(patch)" }
    public var variantName: String {
        switch variant {
        case 1: return "s140v6"
        case 2: return "s140v7"
        case 3: return "nosd"
        default: return "unknown"
        }
    }

    /// payload incl. type byte 0x82
    public init?(payload p: [UInt8]) {
        guard p.count >= 16, p[0] == NRFDigitizer.MessageType.helloReply.rawValue,
              Array(p[12..<16]) == Array("TBDG".utf8) else { return nil }
        protocolVersion = p[1]; major = p[2]; minor = p[3]; patch = p[4]
        maxContacts = p[5]; variant = p[6]; flags = p[7]
        loadAddress = UInt32(p[8]) | UInt32(p[9]) << 8 | UInt32(p[10]) << 16 | UInt32(p[11]) << 24
    }
}

/// Stream parser for frames coming back from the dongle (same framing in both directions).
public struct DigitizerFrameParser {
    private enum State { case sync, len, payload, crc }
    private var state = State.sync
    private var len = 0
    private var buf: [UInt8] = []
    public private(set) var crcErrors = 0

    public init() {}

    public mutating func reset() { state = .sync; buf = [] }

    /// Returns complete payloads (type byte first) with a valid CRC.
    public mutating func feed<S: Sequence>(_ bytes: S) -> [[UInt8]] where S.Element == UInt8 {
        var out: [[UInt8]] = []
        for b in bytes {
            switch state {
            case .sync:
                if b == NRFDigitizer.sync { state = .len }
            case .len:
                if b == 0 || Int(b) > NRFDigitizer.maxPayload {
                    state = b == NRFDigitizer.sync ? .len : .sync
                } else {
                    len = Int(b); buf = []; state = .payload
                }
            case .payload:
                buf.append(b)
                if buf.count >= len { state = .crc }
            case .crc:
                state = .sync
                if NRFDigitizer.crc8([UInt8(len)] + buf) == b { out.append(buf) } else { crcErrors += 1 }
            }
        }
        return out
    }
}

/// Assigns stable small contact IDs (0…9) to TouchBridge contact IDs and converts normalized points into
/// dongle frames. Lifted fingers are left out of the next frame – the dongle reports their lift.
public struct DigitizerContactTracker {
    private var slots: [Int: UInt8] = [:]
    public init() {}

    public var activeCount: Int { slots.count }

    public mutating func reset() { slots = [:] }

    /// points: (TouchBridge contact id, normalized 0…1 position in the dongle's coordinate space)
    public mutating func contacts(for points: [(id: Int, x: CGFloat, y: CGFloat)]) -> [DigitizerContact] {
        let ids = Set(points.map(\.id))
        slots = slots.filter { ids.contains($0.key) }
        var result: [DigitizerContact] = []
        for p in points {
            let slot: UInt8
            if let s = slots[p.id] {
                slot = s
            } else {
                let used = Set(slots.values)
                guard let free = (0..<UInt8(NRFDigitizer.maxContacts)).first(where: { !used.contains($0) }) else { continue }
                slots[p.id] = free
                slot = free
            }
            result.append(DigitizerContact(id: slot, tip: true, x: NRFDigitizer.coordinate(p.x), y: NRFDigitizer.coordinate(p.y)))
        }
        return result.sorted { $0.id < $1.id }
    }
}

/// Which screen area the dongle's 0…32767 range stands for. macOS decides which display a USB touch screen
/// belongs to; TouchBridge converts the Anmite position into the space chosen here.
public enum DigitizerSpace: String, Codable, CaseIterable {
    /// the touch display itself (expected: macOS maps the digitizer onto the Anmite)
    case touchDisplay
    /// the main display (menu bar screen)
    case mainDisplay
    /// bounding box of all displays
    case allDisplays

    public var title: String {
        switch self {
        case .touchDisplay: return L("Touch display", "Touch-Bildschirm")
        case .mainDisplay: return L("Main display", "Hauptbildschirm")
        case .allDisplays: return L("All displays", "Alle Bildschirme")
        }
    }

    /// Global screen point → normalized 0…1 within `rect` (clamped)
    public static func normalize(_ p: CGPoint, in rect: CGRect) -> (x: CGFloat, y: CGFloat) {
        guard rect.width > 1, rect.height > 1 else { return (0, 0) }
        let x = (p.x - rect.minX) / (rect.width - 1), y = (p.y - rect.minY) / (rect.height - 1)
        return (min(1, max(0, x)), min(1, max(0, y)))
    }
}

/// Where touch goes: synthetic events (gesture engine) or the digitizer dongle (macOS handles touch).
public enum TouchOutput: String, Codable, CaseIterable {
    case gestures, digitizer
    public var title: String {
        self == .gestures ? L("Gestures (synthetic events)", "Gesten (synthetische Events)")
                          : L("Digitizer dongle (macOS handles touch)", "Digitizer-Dongle (macOS verarbeitet Touch)")
    }
}

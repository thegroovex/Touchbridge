import Foundation

/// Typische HID-Report-Descriptoren von USB-Touchmonitoren (Windows-8-Multitouch-Format).
enum Fixtures {
    /// Ein Finger: Tip Switch (1 bit) + 7 bit Padding, Contact ID (8 bit), X/Y (16 bit, 0...4095).
    static let finger: [UInt8] = [
        0x05, 0x0D, 0x09, 0x22, 0xA1, 0x02,             // Usage Page Digitizer, Usage Finger, Collection (Logical)
        0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02, // Tip Switch
        0x95, 0x07, 0x81, 0x03,                          // Padding
        0x75, 0x08, 0x09, 0x51, 0x95, 0x01, 0x81, 0x02, // Contact ID
        0x05, 0x01, 0x26, 0xFF, 0x0F, 0x75, 0x10, 0x55, 0x0E, 0x65, 0x33,
        0x09, 0x30, 0x35, 0x00, 0x46, 0xB5, 0x04, 0x81, 0x02, // X
        0x46, 0x8A, 0x03, 0x09, 0x31, 0x81, 0x02,       // Y
        0xC0,
    ]

    /// Touchscreen mit Report-ID 1, `fingers` Slots und Contact Count (Hybrid-fähig).
    static func touchScreen(fingers: Int, contactCount: Bool = true, reportID: UInt8? = 1,
                            mouseFirst: Bool = false) -> [UInt8] {
        var d: [UInt8] = []
        if mouseFirst {
            // Maus-Collection (Report 2), die ignoriert werden muss
            d += [0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xA1, 0x00,
                  0x05, 0x09, 0x19, 0x01, 0x29, 0x02, 0x15, 0x00, 0x25, 0x01, 0x95, 0x02, 0x75, 0x01, 0x81, 0x02,
                  0x95, 0x06, 0x81, 0x03,
                  0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x16, 0x00, 0x00, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
                  0xC0, 0xC0]
        }
        d += [0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01]
        if let rid = reportID { d += [0x85, rid] }
        for _ in 0..<fingers { d += finger; d += [0x05, 0x0D] }
        if contactCount { d += [0x09, 0x54, 0x95, 0x01, 0x75, 0x08, 0x15, 0x00, 0x25, 0x0A, 0x81, 0x02] }
        d += [0xC0]
        return d
    }

    /// Ein Finger-Slot im Report: 6 Bytes (tip, id, x lo/hi, y lo/hi)
    static func slot(tip: Bool, id: UInt8, x: UInt16, y: UInt16) -> [UInt8] {
        [tip ? 1 : 0, id, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)]
    }

    static func report(id: UInt8? = 1, slots: [[UInt8]], count: UInt8?) -> [UInt8] {
        var r: [UInt8] = []
        if let id = id { r.append(id) }
        for s in slots { r += s }
        if let c = count { r.append(c) }
        return r
    }
}

extension Fixtures {
    static func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    /// Anmite A140W05T (VID 0x27C0, PID 0x0859), aus der Diagnose des Users (macOS 27.0.1):
    /// Report 13 mit 10 Fingern (Tip, 3 bit Padding, 4 bit Contact ID, X 0…16383, Y 0…9599), Scan Time,
    /// Contact Count; Feature 0x0A Contact Count Maximum; Device Configuration mit Feature 0x21 (Input Mode, Device Index).
    static let anmite: [UInt8] = {
        let fingerColl = "09 22 A1 02 09 42 15 00 25 01 75 01 95 01 81 02 95 03 81 01 09 51 75 04 25 0F 95 01 81 02 05 01 26 FF 3F 75 10 55 0E 65 11 09 30 35 00 46 79 08 81 02 26 7F 25 46 8A 03 09 31 81 02 05 0D C0"
        var d = hex("05 0D 09 04 A1 01 85 0D")
        for _ in 0..<10 { d += hex(fingerColl) }
        d += hex("27 FF FF 00 00 75 10 95 01 09 56 81 02 09 54 15 00 25 7F 95 01 75 08 81 02 85 0A 09 55 95 01 25 0F B1 02 C0")
        d += hex("05 0D 09 0E A1 01 85 21 09 22 A1 00 09 52 09 53 15 00 25 0A 75 08 95 02 B1 02 C0 C0")
        return d
    }()

    /// Ein Anmite-Finger-Slot (5 Bytes): Tip (bit 0), Contact ID (bits 4–7), X, Y je 16 bit
    static func anmiteSlot(tip: Bool, id: UInt8, x: UInt16, y: UInt16) -> [UInt8] {
        [(tip ? 1 : 0) | (id << 4), UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)]
    }
}

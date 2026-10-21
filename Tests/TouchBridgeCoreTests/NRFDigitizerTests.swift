import CoreGraphics
import Foundation
import XCTest
@testable import TouchBridgeCore

/// Protocol encoder / parser for the nRF52840 digitizer dongle and its HID report descriptor
/// (firmware/nrf-digitizer). Same test vectors as firmware/nrf-digitizer/tests/proto_test.c.
final class NRFDigitizerTests: XCTestCase {

    func testCRC8CheckValue() {
        XCTAssertEqual(NRFDigitizer.crc8(Array("123456789".utf8)), 0xF4)
    }

    func testHelloFrame() {
        let f = NRFDigitizer.helloFrame()
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual(Array(f[0..<3]), [0xA5, 0x01, 0x02])
        XCTAssertEqual(f[3], NRFDigitizer.crc8([0x01, 0x02]))
    }

    func testTouchFrameLayout() {
        let f = NRFDigitizer.touchFrame([
            DigitizerContact(id: 0, tip: true, x: 0x4000, y: 0x7FFF),
            DigitizerContact(id: 1, tip: true, x: 0x1234, y: 0),
        ])
        // sync, len, type, version, count, 2 x 6, crc
        XCTAssertEqual(f.count, 2 + 3 + 12 + 1)
        XCTAssertEqual(f[0], 0xA5)
        XCTAssertEqual(Int(f[1]), 15)
        XCTAssertEqual(Array(f[2..<5]), [0x01, 0x01, 0x02])
        XCTAssertEqual(Array(f[5..<11]), [0x00, 0x03, 0x00, 0x40, 0xFF, 0x7F])
        XCTAssertEqual(Array(f[11..<17]), [0x01, 0x03, 0x34, 0x12, 0x00, 0x00])
        XCTAssertEqual(f[17], NRFDigitizer.crc8(f[1..<17]))
    }

    func testTouchFrameClampsAndLimits() {
        let many = (0..<14).map { DigitizerContact(id: UInt8($0), tip: true, x: 40000, y: 1) }
        let f = NRFDigitizer.touchFrame(many)
        XCTAssertEqual(Int(f[4]), NRFDigitizer.maxContacts)
        XCTAssertEqual(f.count, 2 + 3 + 6 * NRFDigitizer.maxContacts + 1)
        XCTAssertEqual(Array(f[7..<9]), [0xFF, 0x7F]) // x clamped to 32767
        let empty = NRFDigitizer.touchFrame([])
        XCTAssertEqual(Array(empty[0..<5]), [0xA5, 0x03, 0x01, 0x01, 0x00])
    }

    func testCoordinateMapping() {
        XCTAssertEqual(NRFDigitizer.coordinate(0), 0)
        XCTAssertEqual(NRFDigitizer.coordinate(1), 32767)
        XCTAssertEqual(NRFDigitizer.coordinate(0.5), 16384)
        XCTAssertEqual(NRFDigitizer.coordinate(-0.2), 0)
        XCTAssertEqual(NRFDigitizer.coordinate(3), 32767)
        XCTAssertEqual(NRFDigitizer.coordinate(.nan), 0)
    }

    func testParserRoundTripWithGarbageAndBadCRC() {
        var reply: [UInt8] = [0x82, 1, 0, 1, 0, 10, 1, 3, 0x00, 0x60, 0x02, 0x00]
        reply += Array("TBDG".utf8)
        let good = NRFDigitizer.frame(reply)
        var bad = good
        bad[6] ^= 0x01
        var p = DigitizerFrameParser()
        let out = p.feed([0x00, 0x13, 0xA5] + bad + good)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(p.crcErrors, 1)
        let h = DigitizerHello(payload: out[0])
        XCTAssertEqual(h?.version, "0.1.0")
        XCTAssertEqual(h?.variantName, "s140v6")
        XCTAssertEqual(h?.loadAddress, 0x26000)
        XCTAssertEqual(h?.maxContacts, 10)
        // split across reads
        var q = DigitizerFrameParser()
        XCTAssertTrue(q.feed(good.prefix(5)).isEmpty)
        XCTAssertEqual(q.feed(good.dropFirst(5)).count, 1)
    }

    func testHelloRejectsForeignPayload() {
        XCTAssertNil(DigitizerHello(payload: [0x82, 1, 0, 1]))
        XCTAssertNil(DigitizerHello(payload: [0x82] + [UInt8](repeating: 0, count: 15)))
    }

    func testTrackerAssignsStableSlots() {
        var t = DigitizerContactTracker()
        var c = t.contacts(for: [(id: 57, x: 0, y: 0), (id: 3, x: 1, y: 1)])
        XCTAssertEqual(c.map(\.id), [0, 1])
        XCTAssertEqual(c.first { $0.id == 1 }?.x, 32767)
        // finger 57 lifted: finger 3 keeps slot 1, a new finger takes the free slot 0
        c = t.contacts(for: [(id: 3, x: 0.5, y: 0.5), (id: 99, x: 0, y: 0)])
        XCTAssertEqual(c.map(\.id), [0, 1])
        XCTAssertEqual(c.first { $0.id == 1 }?.x, 16384)
        XCTAssertEqual(t.activeCount, 2)
        XCTAssertTrue(t.contacts(for: []).isEmpty)
        XCTAssertEqual(t.activeCount, 0)
        // more than 10 fingers: the extra ones are dropped
        let many = (0..<12).map { (id: $0, x: CGFloat(0), y: CGFloat(0)) }
        XCTAssertEqual(t.contacts(for: many).count, 10)
    }

    func testSpaceNormalize() {
        let r = CGRect(x: 1920, y: 0, width: 1001, height: 501)
        let a = DigitizerSpace.normalize(CGPoint(x: 1920, y: 0), in: r)
        let b = DigitizerSpace.normalize(CGPoint(x: 2920, y: 500), in: r)
        let c = DigitizerSpace.normalize(CGPoint(x: 0, y: 900), in: r)
        XCTAssertEqual(a.x, 0); XCTAssertEqual(a.y, 0)
        XCTAssertEqual(b.x, 1); XCTAssertEqual(b.y, 1)
        XCTAssertEqual(c.x, 0); XCTAssertEqual(c.y, 1)
    }

    // MARK: HID report descriptor

    /// The Swift copy and the firmware's descriptor must be byte-identical.
    func testDescriptorMatchesFirmware() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("firmware/nrf-digitizer/src/hid_report_desc.inc")
        let text = try String(contentsOf: file, encoding: .utf8)
        let code = text.split(separator: "\n").map { line -> Substring in
            if let r = line.range(of: "//") { return line[..<r.lowerBound] }
            return line
        }.joined(separator: " ")
        let rx = try NSRegularExpression(pattern: "0x([0-9A-Fa-f]{2})")
        let ns = code as NSString
        let bytes = rx.matches(in: code, range: NSRange(location: 0, length: ns.length)).map {
            UInt8(ns.substring(with: $0.range(at: 1)), radix: 16)!
        }
        XCTAssertEqual(bytes.count, NRFDigitizer.reportDescriptor.count)
        XCTAssertEqual(bytes, NRFDigitizer.reportDescriptor)
    }

    func testDescriptorParsesAsTenFingerTouchScreen() throws {
        let d = HIDDescriptor(bytes: NRFDigitizer.reportDescriptor)
        XCTAssertTrue(d.usesReportIDs)
        XCTAssertTrue(d.collections.contains { $0.usagePage == Usage.pageDigitizer && $0.usage == Usage.touchScreen })
        let layouts = TouchLayout.build(from: d)
        let layout = try XCTUnwrap(layouts[1])
        XCTAssertEqual(layout.fingers.count, 10)
        XCTAssertNotNil(layout.contactCount)
        for f in layout.fingers {
            XCTAssertNotNil(f.tip); XCTAssertNotNil(f.contactID); XCTAssertNotNil(f.confidence)
            XCTAssertEqual(f.x?.logicalMax, 32767); XCTAssertEqual(f.y?.logicalMax, 32767)
            XCTAssertEqual(f.x?.bitSize, 16)
        }
        // 64-byte input report incl. report ID: 10 x 48 bit + scan time 16 + count 8 = 504 bit = 63 bytes
        let inputBits = d.fields.filter { $0.reportID == 1 }.map { $0.bitOffset + $0.bitSize }.max() ?? 0
        XCTAssertEqual(inputBits, 63 * 8)
        XCTAssertTrue(d.featureFields.contains { $0.reportID == 2 && $0.usage == Usage.contactCountMax && $0.logicalMax == 10 })
    }

    /// A report as the firmware builds it (tb_report.c) is read back by TouchBridge's own frame assembler.
    func testFirmwareReportReadsBack() {
        var r = [UInt8](repeating: 0, count: 64)
        r[0] = 1
        func put(_ slot: Int, id: UInt8, tip: Bool, x: UInt16, y: UInt16) {
            let o = 1 + slot * 6
            r[o] = (tip ? 1 : 0) | 2
            r[o + 1] = id
            r[o + 2] = UInt8(x & 0xFF); r[o + 3] = UInt8(x >> 8)
            r[o + 4] = UInt8(y & 0xFF); r[o + 5] = UInt8(y >> 8)
        }
        put(0, id: 0, tip: true, x: 100, y: 32767)
        put(1, id: 4, tip: true, x: 32767, y: 5)
        put(2, id: 7, tip: false, x: 9, y: 9)
        r[61] = 0x34; r[62] = 0x12; r[63] = 3
        var asm = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: NRFDigitizer.reportDescriptor))
        let out = asm.feed(r)
        XCTAssertEqual(out?.contacts.map(\.id), [0, 4])
        XCTAssertEqual(out?.contacts.first?.x, 100)
        XCTAssertEqual(out?.contacts.first?.y, 32767)
        XCTAssertEqual(out?.contacts.last?.x, 32767)
    }
}

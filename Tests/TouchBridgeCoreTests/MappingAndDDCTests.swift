import CoreGraphics
import XCTest
@testable import TouchBridgeCore

final class MappingTests: XCTestCase {
    func p(_ m: TouchMapping, _ x: CGFloat, _ y: CGFloat) -> CGPoint { m.apply(x, y) }

    func testIdentity() {
        XCTAssertEqual(p(TouchMapping(), 0.25, 0.75), CGPoint(x: 0.25, y: 0.75))
    }

    func testRotationCorners() {
        // Ecke oben links des Panels landet nach Drehung im Uhrzeigersinn …
        XCTAssertEqual(p(TouchMapping(rotation: 90), 0, 0), CGPoint(x: 1, y: 0))   // oben rechts
        XCTAssertEqual(p(TouchMapping(rotation: 180), 0, 0), CGPoint(x: 1, y: 1))  // unten rechts
        XCTAssertEqual(p(TouchMapping(rotation: 270), 0, 0), CGPoint(x: 0, y: 1))  // unten links
        XCTAssertEqual(p(TouchMapping(rotation: -90), 0, 0), CGPoint(x: 0, y: 1))
    }

    func testRotationIsReversibleIn4Steps() {
        var x: CGFloat = 0.2, y: CGFloat = 0.7
        for _ in 0..<4 { let q = TouchMapping(rotation: 90).apply(x, y); x = q.x; y = q.y }
        XCTAssertEqual(x, 0.2, accuracy: 1e-9); XCTAssertEqual(y, 0.7, accuracy: 1e-9)
    }

    func testFlipAndSwap() {
        XCTAssertEqual(p(TouchMapping(flipX: true), 0.1, 0.2), CGPoint(x: 0.9, y: 0.2))
        XCTAssertEqual(p(TouchMapping(flipY: true), 0.1, 0.2), CGPoint(x: 0.1, y: 0.8))
        XCTAssertEqual(p(TouchMapping(swapXY: true), 0.1, 0.2), CGPoint(x: 0.2, y: 0.1))
    }

    func testNormalizeAndScreen() {
        XCTAssertEqual(TouchMapping.normalize(2048, min: 0, max: 4096), 0.5)
        XCTAssertEqual(TouchMapping.normalize(-5, min: 0, max: 100), 0)
        XCTAssertEqual(TouchMapping.normalize(500, min: 0, max: 100), 1)
        XCTAssertEqual(TouchMapping.normalize(5, min: 3, max: 3), 0)
        let r = CGRect(x: 1440, y: 0, width: 1921, height: 1081)
        XCTAssertEqual(TouchMapping().screenPoint(1, 1, in: r), CGPoint(x: 3360, y: 1080))
        XCTAssertEqual(TouchMapping().screenPoint(0, 0, in: r), CGPoint(x: 1440, y: 0))
    }
}

final class DDCTests: XCTestCase {
    func testSetPacketBrightness50() {
        // bekannte Referenz (m1ddc): 84 03 10 00 32 + Prüfsumme 6E^51^84^03^10^00^32
        let p = DDC.setPacket(vcp: DDC.VCP.brightness.rawValue, value: 50)
        XCTAssertEqual(Array(p.prefix(5)), [0x84, 0x03, 0x10, 0x00, 0x32])
        XCTAssertEqual(p[5], 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32)
    }

    func testGetPacket() {
        XCTAssertEqual(DDC.getPacket(vcp: 0x62), [0x82, 0x01, 0x62, 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x62])
    }

    func testReplyRoundTrip() {
        let r = DDC.makeReply(vcp: 0x12, current: 75, max: 100)
        let v = DDC.parseReply(r, vcp: 0x12)
        XCTAssertEqual(v?.current, 75); XCTAssertEqual(v?.max, 100)
    }

    func testReplyWithoutSourceByte() {
        let r = Array(DDC.makeReply(vcp: 0x10, current: 42, max: 100).dropFirst()) + [0, 0]
        XCTAssertEqual(DDC.parseReply(r, vcp: 0x10)?.current, 42)
    }

    func testReplyRejectsGarbage() {
        var r = DDC.makeReply(vcp: 0x10, current: 30, max: 100)
        XCTAssertNil(DDC.parseReply(r, vcp: 0x12))            // falscher VCP
        r[9] ^= 0xFF
        XCTAssertNil(DDC.parseReply(r, vcp: 0x10))            // Prüfsumme kaputt
        XCTAssertNil(DDC.parseReply([0x6E, 0x80], vcp: 0x10)) // zu kurz
        var unsupported = DDC.makeReply(vcp: 0x10, current: 0, max: 0)
        unsupported[3] = 0x01
        XCTAssertNil(DDC.parseReply(unsupported, vcp: 0x10))  // "nicht unterstützt"
    }
}

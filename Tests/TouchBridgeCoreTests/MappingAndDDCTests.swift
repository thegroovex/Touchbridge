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
        XCTAssertEqual(DDC.getPacket(vcp: 0x62), [0x82, 0x01, 0x62, UInt8(0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x62)])
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

final class DisplayTargetTests: XCTestCase {
    let mac = DisplayCandidate(id: 1, name: "Integrierter Retina-Bildschirm", isBuiltin: true, isMain: true)
    let anmite = DisplayCandidate(id: 5, name: "ANMITE", isBuiltin: false, isMain: false)
    let other = DisplayCandidate(id: 7, name: "DELL U2720Q", isBuiltin: false, isMain: false)

    func testChoosesMatchingExternalDisplay() {
        XCTAssertEqual(DisplayChoice.choose([mac, other, anmite], preferred: nil, deviceHints: ["TouchScreen", "ANMITE"]), 5)
        XCTAssertEqual(DisplayChoice.choose([mac, anmite], preferred: nil, deviceHints: []), 5)      // einziger externer
        // Anmite gewinnt auch gegen eine gespeicherte Wahl
        XCTAssertEqual(DisplayChoice.choose([mac, anmite, other], preferred: 7, deviceHints: ["ANMITE"]), 5)
        XCTAssertEqual(DisplayChoice.choose([mac, anmite, other], preferred: 7, deviceHints: []), 5)
        // gespeicherte Wahl gilt, wenn kein Anmite erkannt wird – aber nie der integrierte Bildschirm
        XCTAssertEqual(DisplayChoice.choose([mac, other], preferred: 7, deviceHints: []), 7)
        XCTAssertEqual(DisplayChoice.choose([mac, other], preferred: 1, deviceHints: []), 7)
        XCTAssertEqual(DisplayChoice.choose([mac, DisplayCandidate(id: 9, name: "A140W05T", isBuiltin: false, isMain: false), other],
                                            preferred: nil, deviceHints: []), 9)
        XCTAssertEqual(DisplayChoice.choose([mac, anmite], preferred: 99, deviceHints: []), 5)      // gewählter weg
        XCTAssertNil(DisplayChoice.choose([mac], preferred: nil, deviceHints: ["ANMITE"]))   // nur integriert: kein Ziel
        XCTAssertNil(DisplayChoice.choose([mac], preferred: 1, deviceHints: []))
        // generische Wörter („Touch“, „Screen“) dürfen nicht auf irgendeinen Bildschirm passen
        let generic = DisplayCandidate(id: 8, name: "Touch Screen Pro", isBuiltin: false, isMain: false)
        XCTAssertEqual(DisplayChoice.choose([mac, other, generic], preferred: nil, deviceHints: ["Touch Screen"]), 7)
    }

    func testAbsoluteMappingOnNegativeOrigin() {
        // Anmite links vom MacBook: CGDisplayBounds (-1920, -218) 1920×1200
        let r = CGRect(x: -1920, y: -218, width: 1920, height: 1200)
        XCTAssertEqual(TouchMapping().screenPoint(0, 0, in: r), CGPoint(x: -1920, y: -218))
        XCTAssertEqual(TouchMapping().screenPoint(1, 1, in: r), CGPoint(x: -1, y: 981))
        let mid = TouchMapping().screenPoint(0.5, 0.5, in: r)
        XCTAssertEqual(mid.x, -960.5, accuracy: 1e-9); XCTAssertEqual(mid.y, 381.5, accuracy: 1e-9)
        XCTAssertTrue(r.contains(TouchMapping(rotation: 90).screenPoint(0.3, 0.9, in: r)))
        // Anmite-Rohkoordinaten (X 0…16383, Y 0…9599) landen auf dem Anmite-Rect, nicht auf dem Hauptbildschirm
        let p = TouchMapping().screenPoint(TouchMapping.normalize(16383, min: 0, max: 16383),
                                           TouchMapping.normalize(0, min: 0, max: 9599), in: r)
        XCTAssertEqual(p, CGPoint(x: -1, y: -218))
    }

    func testOneFingerUsesAbsolutePositions() {
        // 1 Finger: Tap = Klick an der absoluten Position, Ziehen = Down/Dragged an absoluten Positionen (keine Deltas)
        let sink = RecordingSink()
        let e = GestureEngine(poster: sink, config: GestureConfig())
        var now = 0.0
        e.clock = { now }
        e.update([CGPoint(x: -1500, y: 100)])
        now += 0.1
        e.update([])
        XCTAssertEqual(sink.events, ["move -1500,100", "click -1500,100"])
        sink.events = []
        now += 1
        e.update([CGPoint(x: -1000, y: 500)])
        e.update([CGPoint(x: -900, y: 520)])
        e.update([CGPoint(x: -800, y: 540)])
        e.update([])
        XCTAssertEqual(sink.events, ["move -1000,500", "down -1000,500", "drag -900,520", "drag -800,540", "up -800,540"])
    }
}

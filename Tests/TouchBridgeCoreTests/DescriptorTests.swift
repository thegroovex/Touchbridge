import XCTest
@testable import TouchBridgeCore

final class DescriptorTests: XCTestCase {
    func testFieldOffsetsTwoFingers() {
        let d = HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 2))
        XCTAssertTrue(d.usesReportIDs)
        let live = d.fields.filter { !$0.isConstant }
        XCTAssertEqual(live.map { $0.bitOffset }, [0, 8, 16, 32, 48, 56, 64, 80, 96])
        XCTAssertEqual(live.map { $0.bitSize }, [1, 8, 16, 16, 1, 8, 16, 16, 8])
        let x = live[2]
        XCTAssertEqual(x.usagePage, Usage.pageGenericDesktop)
        XCTAssertEqual(x.usage, Usage.x)
        XCTAssertEqual(x.logicalMin, 0)
        XCTAssertEqual(x.logicalMax, 4095)
    }

    func testLayoutFindsFingersAndContactCount() {
        let layouts = TouchLayout.build(from: HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 5)))
        XCTAssertEqual(layouts.count, 1)
        let l = try! XCTUnwrap(layouts[1])
        XCTAssertEqual(l.fingers.count, 5)
        XCTAssertNotNil(l.contactCount)
        XCTAssertTrue(l.fingers.allSatisfy { $0.tip != nil && $0.contactID != nil && $0.x != nil && $0.y != nil })
    }

    func testMouseCollectionIsIgnored() {
        let layouts = TouchLayout.build(from: HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 2, mouseFirst: true)))
        XCTAssertEqual(Array(layouts.keys), [1])
    }

    func testWithoutReportID() {
        let d = HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 1, contactCount: false, reportID: nil))
        XCTAssertFalse(d.usesReportIDs)
        XCTAssertEqual(TouchLayout.build(from: d)[0]?.fingers.count, 1)
    }

    func testUnsignedOneByteLogicalMax() {
        // Logical Max 0xFF als 1 Byte: Treiber interpretieren das als 255, nicht -1
        let desc: [UInt8] = [0x05, 0x01, 0x09, 0x30, 0x15, 0x00, 0x25, 0xFF, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02]
        let f = HIDDescriptor(bytes: desc).fields[0]
        XCTAssertEqual(f.logicalMax, 255)
    }

    func testSignedRead() {
        let desc: [UInt8] = [0x05, 0x01, 0x09, 0x30, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06]
        let f = HIDDescriptor(bytes: desc).fields[0]
        let v = [UInt8(0xFE)].withUnsafeBufferPointer { f.read($0, base: 0) }
        XCTAssertEqual(v, -2)
    }

    func testLongItemAndTruncatedDescriptorDoNotCrash() {
        _ = HIDDescriptor(bytes: [0xFE, 0x02, 0x00, 0xAA, 0xBB, 0x05])
        _ = HIDDescriptor(bytes: [0x27, 0xFF])
        _ = HIDDescriptor(bytes: [])
    }
}

final class FrameAssemblerTests: XCTestCase {
    func testSingleReportFrame() {
        var a = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 2)))
        let r = Fixtures.report(slots: [Fixtures.slot(tip: true, id: 3, x: 100, y: 200),
                                        Fixtures.slot(tip: true, id: 7, x: 4000, y: 10)], count: 2)
        let f = a.feed(r)
        XCTAssertEqual(f?.contacts, [RawContact(id: 3, x: 100, y: 200), RawContact(id: 7, x: 4000, y: 10)])
    }

    func testHybridModeSpansTwoReports() {
        var a = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 2)))
        let first = Fixtures.report(slots: [Fixtures.slot(tip: true, id: 0, x: 1, y: 1),
                                            Fixtures.slot(tip: true, id: 1, x: 2, y: 2)], count: 3)
        XCTAssertNil(a.feed(first))
        let second = Fixtures.report(slots: [Fixtures.slot(tip: true, id: 2, x: 3, y: 3),
                                             Fixtures.slot(tip: false, id: 0, x: 0, y: 0)], count: 0)
        XCTAssertEqual(a.feed(second)?.contacts.map { $0.id }, [0, 1, 2])
    }

    func testLiftAndEmptyFrame() {
        var a = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 2)))
        let lift = Fixtures.report(slots: [Fixtures.slot(tip: false, id: 0, x: 5, y: 5),
                                           Fixtures.slot(tip: false, id: 0, x: 0, y: 0)], count: 1)
        XCTAssertEqual(a.feed(lift)?.contacts, [])
        let empty = Fixtures.report(slots: [Fixtures.slot(tip: false, id: 0, x: 0, y: 0),
                                            Fixtures.slot(tip: false, id: 0, x: 0, y: 0)], count: 0)
        XCTAssertEqual(a.feed(empty)?.contacts, [])
    }

    func testUnknownReportIDIsIgnored() {
        var a = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 2, mouseFirst: true)))
        XCTAssertNil(a.feed([0x02, 0x01, 0x10, 0x00, 0x10, 0x00]))
    }

    func testNoContactCountUsesTipSwitch() {
        var a = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 2, contactCount: false, reportID: nil)))
        let r = Fixtures.report(id: nil, slots: [Fixtures.slot(tip: false, id: 0, x: 9, y: 9),
                                                 Fixtures.slot(tip: true, id: 4, x: 50, y: 60)], count: nil)
        XCTAssertEqual(a.feed(r)?.contacts, [RawContact(id: 4, x: 50, y: 60)])
    }
}

final class PressureDescriptorTests: XCTestCase {
    /// Finger-Slot mit zusätzlich Tip Pressure (8 bit, 0…255) und Width (8 bit, 0…200).
    func testPressureAndWidthAreRead() {
        var finger = Array(Fixtures.finger.dropLast()) // ohne End Collection
        finger += [0x05, 0x0D, 0x09, 0x30, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
                   0x09, 0x48, 0x26, 0xC8, 0x00, 0x81, 0x02, 0xC0]
        let d: [UInt8] = [0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01] + finger
            + [0x05, 0x0D, 0x09, 0x54, 0x95, 0x01, 0x75, 0x08, 0x15, 0x00, 0x25, 0x0A, 0x81, 0x02, 0xC0]
        var a = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: d))
        XCTAssertNotNil(a.layouts[1]?.fingers.first?.pressure)
        let r: [UInt8] = [1] + Fixtures.slot(tip: true, id: 2, x: 10, y: 20) + [255, 100] + [1]
        let c = a.feed(r)?.contacts.first
        XCTAssertEqual(c?.pressure ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(c?.size ?? -1, 0.5, accuracy: 1e-9)
    }
}

final class AnmiteDescriptorTests: XCTestCase {
    let d = HIDDescriptor(bytes: Fixtures.anmite)

    func testTouchLayout() {
        let layouts = TouchLayout.build(from: d)
        XCTAssertEqual(Array(layouts.keys), [13])
        let l = layouts[13]!
        XCTAssertEqual(l.fingers.count, 10)
        XCTAssertNotNil(l.contactCount)
        XCTAssertEqual(l.fingers[0].x?.logicalMax, 16383)
        XCTAssertEqual(l.fingers[0].y?.logicalMax, 9599)
        XCTAssertEqual(l.fingers[0].contactID?.bitSize, 4)
        XCTAssertEqual(l.fingers[1].x?.bitOffset, 5 * 8 + 8)
        XCTAssertEqual(l.contactCount?.bitOffset, 10 * 40 + 16)
    }

    func testFeatureFieldsAndInputModeReport() {
        XCTAssertEqual(d.contactCountMaximumField?.reportID, 0x0A)
        let im = d.featureFields.first { $0.usage == Usage.inputMode }
        XCTAssertEqual(im?.reportID, 0x21)
        XCTAssertEqual(im?.bitOffset, 0)
        XCTAssertEqual(d.featureFields.first { $0.usage == Usage.deviceIndex }?.bitOffset, 8)
        XCTAssertEqual(d.featureReportBits[0x21], 16)
        let r = d.inputModeReport()
        XCTAssertEqual(r?.reportID, 0x21)
        XCTAssertEqual(r?.bytes, [0x21, 0x02, 0x00])
        XCTAssertNil(HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 2)).inputModeReport())
    }

    func testFrame() {
        var a = TouchFrameAssembler(descriptor: d)
        var r: [UInt8] = [13] + Fixtures.anmiteSlot(tip: true, id: 3, x: 8000, y: 4000)
            + Fixtures.anmiteSlot(tip: true, id: 12, x: 16383, y: 9599)
        for _ in 2..<10 { r += Fixtures.anmiteSlot(tip: false, id: 0, x: 0, y: 0) }
        r += [0x34, 0x12, 2]   // Scan Time, Contact Count
        XCTAssertEqual(a.feed(r)?.contacts, [RawContact(id: 3, x: 8000, y: 4000), RawContact(id: 12, x: 16383, y: 9599)])
    }
}

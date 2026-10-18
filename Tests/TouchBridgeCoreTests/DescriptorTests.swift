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

import CoreGraphics
import XCTest
@testable import TouchBridgeCore

private final class Owner {
    var got: [Int] = []
}

/// Callback-Lebensdauer: eine native Registrierung je Gerät, Beobachter schwach, unbekannte Schlüssel ignoriert.
final class HIDObserverTableTests: XCTestCase {
    func testOnlyFirstObserverRegistersNatively() {
        let t = HIDObserverTable<Int>()
        let a = Owner(), b = Owner()
        let r1 = t.add(key: 0x1_0009_8EB1, owner: a) { o, e in o.got.append(e) }
        let r2 = t.add(key: 0x1_0009_8EB1, owner: b) { o, e in o.got.append(e) }
        XCTAssertTrue(r1.needsNativeRegistration)
        XCTAssertFalse(r2.needsNativeRegistration, "Diagnose hängt sich nur als Beobachter an")
        XCTAssertEqual(t.dispatch(key: 0x1_0009_8EB1, 7), 2)
        XCTAssertEqual(a.got, [7]); XCTAssertEqual(b.got, [7])
        // anderes Gerät: eigene Registrierung
        XCTAssertTrue(t.add(key: 0x1_0009_8EB5, owner: a) { _, _ in }.needsNativeRegistration)
    }

    func testRemovedObserverKeepsNativeRegistration() {
        let t = HIDObserverTable<Int>()
        let a = Owner()
        let r = t.add(key: 42, owner: a) { o, e in o.got.append(e) }
        t.remove(r.token)
        XCTAssertEqual(t.dispatch(key: 42, 1), 0)
        XCTAssertTrue(t.isRegistered(key: 42), "Puffer/Callback bleiben bis zum Abstecken registriert")
        // neuer Beobachter nach stop()/start(): keine zweite native Registrierung
        XCTAssertFalse(t.add(key: 42, owner: a) { _, _ in }.needsNativeRegistration)
    }

    func testDeadOwnerIsIgnoredNotCalled() {
        let t = HIDObserverTable<Int>()
        var calls = 0
        do {
            let tmp = Owner()
            _ = t.add(key: 5, owner: tmp) { _, _ in calls += 1 }
        }
        // Owner freigegeben (früher: dangling Unmanaged-Context -> EXC_BAD_ACCESS)
        XCTAssertEqual(t.dispatch(key: 5, 1), 0)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(t.observerCount(key: 5), 0)
    }

    func testUnknownKeyIgnored() {
        let t = HIDObserverTable<Int>()
        XCTAssertEqual(t.dispatch(key: 999, 1), 0)
    }

    func testDeviceGoneDropsObserversAndRegistration() {
        let t = HIDObserverTable<Int>()
        let a = Owner()
        _ = t.add(key: 9, owner: a) { o, e in o.got.append(e) }
        XCTAssertTrue(t.deviceGone(key: 9))
        XCTAssertFalse(t.deviceGone(key: 9))
        XCTAssertEqual(t.dispatch(key: 9, 1), 0)
        XCTAssertFalse(t.isRegistered(key: 9))
        XCTAssertTrue(t.add(key: 9, owner: a) { _, _ in }.needsNativeRegistration)
    }

    func testContextRoundTripIsStableInteger() {
        let key: UInt64 = 0x1_0009_8EB5
        let c = HIDObserverTable<Int>.context(for: key)
        XCTAssertNotNil(c)
        XCTAssertEqual(HIDObserverTable<Int>.key(from: c), key)
        XCTAssertEqual(HIDObserverTable<Int>.context(for: key), c, "gleicher Context für Registrieren und Abmelden")
        XCTAssertNil(HIDObserverTable<Int>.key(from: nil))
    }

    func testWeakRegistry() {
        let r = WeakRegistry<Owner>()
        var o: Owner? = Owner()
        let k = r.register(o!)
        XCTAssertTrue(r.lookup(WeakRegistry<Owner>.key(WeakRegistry<Owner>.context(k))!) === o)
        o = nil
        XCTAssertNil(r.lookup(k))
    }
}

/// Anmite-Maus-Schnittstelle (Registry 0x100098EB1, Usage 0x01/0x02): Report 7, 3 Buttons, X/Y absolut, Rad relativ.
final class AbsolutePointerTests: XCTestCase {
    static let mouseDescriptor = Fixtures.hex("05 01 09 02 A1 01 85 07 09 01 A1 00 05 09 19 01 29 03 15 00 25 01 75 01 95 03 81 02 75 01 95 05 81 03 05 01 09 30 75 10 95 01 55 0E 65 11 35 00 46 79 08 26 FF 3F 81 02 09 31 46 8A 03 26 7F 25 81 02 09 38 15 81 25 7F 75 08 95 01 81 06 C0 C0")

    func testParsesAbsoluteXYAndRelativeWheel() {
        let d = HIDDescriptor(bytes: Self.mouseDescriptor)
        let x = d.fields.first { $0.usagePage == 0x01 && $0.usage == 0x30 }!
        let y = d.fields.first { $0.usagePage == 0x01 && $0.usage == 0x31 }!
        let wheel = d.fields.first { $0.usagePage == 0x01 && $0.usage == 0x38 }!
        XCTAssertFalse(x.isRelative); XCTAssertFalse(y.isRelative); XCTAssertTrue(wheel.isRelative)
        XCTAssertEqual(x.logicalMax, 16383); XCTAssertEqual(y.logicalMax, 9599)
        XCTAssertEqual(x.bitOffset, 8); XCTAssertEqual(y.bitOffset, 24)
        XCTAssertTrue(TouchLayout.build(from: d).isEmpty, "keine Multitouch-Finger")
        let p = TouchLayout.absolutePointer(from: d)
        XCTAssertEqual(Array(p.keys), [7])
        XCTAssertTrue(p[7]!.isPointer)
    }

    func testNoPointerWithoutFallbackFlag() {
        let a = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: Self.mouseDescriptor))
        XCTAssertTrue(a.layouts.isEmpty)
    }

    func testSingleTouchFromUserReports() {
        var a = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: Self.mouseDescriptor), pointerFallback: true)
        XCTAssertTrue(a.isPointer)
        // Beispiel vom Gerät: Button 1 down, X 8000, Y 5000
        let down = a.feed(Fixtures.hex("07 01 40 1F 88 13 00"))
        XCTAssertEqual(down?.contacts, [RawContact(id: 0, x: 8000, y: 5000)])
        let move = a.feed(Fixtures.hex("07 01 FF 3F 7F 25 00"))
        XCTAssertEqual(move?.contacts, [RawContact(id: 0, x: 16383, y: 9599)])
        let up = a.feed(Fixtures.hex("07 00 FF 3F 7F 25 00"))
        XCTAssertEqual(up?.contacts, [])
        XCTAssertNil(a.feed(Fixtures.hex("08 01 40 1F 88 13 00")), "fremde Report-ID")
    }

    func testPointerMapsToAnmiteFrameWithNegativeOrigin() {
        var a = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: Self.mouseDescriptor), pointerFallback: true)
        let r = a.feed(Fixtures.hex("07 01 40 1F 88 13 00"))!
        let f = r.layout.fingers[0]
        let rect = CGRect(x: -1920, y: -218, width: 1920, height: 1200)   // Anmite-Bildschirm links vom Hauptbildschirm
        let p = TouchMapping().screenPoint(TouchMapping.normalize(r.contacts[0].x, min: f.x!.logicalMin, max: f.x!.logicalMax),
                                           TouchMapping.normalize(r.contacts[0].y, min: f.y!.logicalMin, max: f.y!.logicalMax), in: rect)
        XCTAssertEqual(p.x, -1920 + 1920 * 8000 / 16383, accuracy: 1)
        XCTAssertEqual(p.y, -218 + 1200 * 5000 / 9599, accuracy: 1)
        XCTAssertTrue(rect.contains(p))
    }

    func testMultitouchDescriptorIsNotPointer() {
        let a = TouchFrameAssembler(descriptor: HIDDescriptor(bytes: Fixtures.anmite), pointerFallback: true)
        XCTAssertFalse(a.isPointer)
        XCTAssertEqual(a.layouts[13]?.fingers.count, 10)
    }

    func testOneFingerDragClicksAndLongPress() {
        // Single-Touch über die GestureEngine: Tippen = Klick, Ziehen = Drag, Halten = Rechtsklick
        let sink = RecordingSink()
        let e = GestureEngine(poster: sink, config: GestureConfig())
        var now = 10.0
        e.clock = { now }
        e.update([CGPoint(x: -1000, y: 100)]); now += 0.05
        e.update([CGPoint(x: -950, y: 100)]); now += 0.05
        e.update([])
        XCTAssertEqual(sink.events, ["move -1000,100", "down -1000,100", "drag -950,100", "up -950,100"])
        sink.events = []
        now += 1
        e.update([CGPoint(x: -500, y: 300)])
        now += 0.8
        e.tick()
        e.update([])
        XCTAssertEqual(sink.events, ["move -500,300", "rclick -500,300"])
    }

    func testOneFingerScrollSetting() {
        let sink = RecordingSink()
        var cfg = GestureConfig()
        cfg.oneFingerScroll = true
        let e = GestureEngine(poster: sink, config: cfg)
        var now = 10.0
        e.clock = { now }
        e.update([CGPoint(x: 100, y: 100)]); now += 0.05
        e.update([CGPoint(x: 100, y: 130)]); now += 0.05
        e.update([CGPoint(x: 100, y: 140)]); now += 0.05
        e.update([])
        XCTAssertEqual(sink.events, ["move 100,100", "scroll 0,0 p1", "scroll 0,30 p2", "scroll 0,10 p2", "scroll 0,0 p4"])
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("down") })
    }
}

final class MultitouchActivationTests: XCTestCase {
    func testFeatureReportLengthIncludesReportID() {
        let d = HIDDescriptor(bytes: Fixtures.anmite)
        XCTAssertEqual(d.featureReportLength(0x21), 3, "[21 mode idx]")
        XCTAssertEqual(d.featureReportLength(0x0A), 2, "[0A max]")
    }

    func testActivationPlanForAnmite() {
        let plan = HIDDescriptor(bytes: Fixtures.anmite).multitouchActivationPlan()
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan[0].readFirst, [0x0A])
        XCTAssertEqual(plan[0].bytes, [0x21, 0x02, 0x00])
        XCTAssertEqual(plan[1].bytes, [0x02, 0x00])
        XCTAssertEqual(plan[1].reportID, 0x21)
        XCTAssertEqual(plan[2].bytes, [0x21, 0x03, 0x00])
        XCTAssertEqual(plan[0].hex, "21 02 00")
    }

    func testNoPlanWithoutInputMode() {
        XCTAssertTrue(HIDDescriptor(bytes: AbsolutePointerTests.mouseDescriptor).multitouchActivationPlan().isEmpty)
    }

    func testReportSummaryAndSource() {
        XCTAssertEqual(InterfaceStatus.reportSummary([(role: .vendor, reports: 0), (role: .mouse, reports: 120), (role: .touch, reports: 0)]),
                       "Touch: 0 Reports, Maus: 120 Reports, Vendor: 0 Reports")
        XCTAssertEqual(InterfaceStatus.reportSummary([(role: .touch, reports: 1)]), "Touch: 1 Report")
        XCTAssertEqual(TouchSource.evaluate(multitouchReports: 0, pointerInterfaces: 1, multitouchInterfaces: 1), .singleTouchPointer)
        XCTAssertEqual(TouchSource.evaluate(multitouchReports: 3, pointerInterfaces: 1, multitouchInterfaces: 1), .multitouch)
        XCTAssertEqual(TouchSource.evaluate(multitouchReports: 0, pointerInterfaces: 0, multitouchInterfaces: 0), .none)
        XCTAssertEqual(TouchSource.singleTouchPointer.title, "Single-Touch (Gerät im Mausmodus)")
    }

    func testAccessibilityTextUsesMacOS27Name() {
        XCTAssertTrue(PermissionTexts.accessibility(trusted: false, asked: false)!.contains("Gerätesteuerung und Datenzugriff"))
        XCTAssertTrue(PermissionTexts.accessibilityName.contains("(Bedienungshilfen)"))
    }
}

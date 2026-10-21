import CoreGraphics
import XCTest
@testable import TouchBridgeCore

/// Gesture editor model, remappable slots, smart target and touch context menu (0.4 phase 2)
final class GestureEditorModelTests: XCTestCase {
    override func setUp() { L10n.language = .english }

    func testKeyComboRoundTripAndDisplay() {
        let flags = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        let k = KeyCombo(keyCode: 40, modifiers: flags | 0x1, label: "k")
        XCTAssertEqual(k.modifiers, flags, "non-modifier bits are dropped")
        XCTAssertEqual(k.displayString, "⌃⌥⇧⌘K")
        XCTAssertEqual(KeyCombo(encoded: k.encoded), k)
        // label containing the separator
        let colon = KeyCombo(keyCode: 41, modifiers: CGEventFlags.maskShift.rawValue, label: ":")
        XCTAssertEqual(KeyCombo(encoded: colon.encoded), colon)
        XCTAssertNil(KeyCombo(encoded: "x:y"))
    }

    func testKeyComboArrowHasNoFnAndUsesSymbol() {
        let mods = CGEventFlags.maskControl.rawValue | CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskNumericPad.rawValue
        let k = KeyCombo(keyCode: 123, modifiers: mods, label: "\u{F702}")
        XCTAssertNil(k.label, "private-use characters of arrow keys are dropped")
        XCTAssertEqual(k.displayString, "⌃←")
        XCTAssertTrue(k.flags.contains(.maskNumericPad))
    }

    func testKeyComboFallbackName() {
        XCTAssertEqual(KeyCombo(keyCode: 0, modifiers: CGEventFlags.maskCommand.rawValue).displayString, "⌘A")
        XCTAssertEqual(KeyCombo(keyCode: 96, modifiers: 0).displayString, "F5")
        XCTAssertEqual(KeyCombo.unset.displayString, "")
        XCTAssertFalse(KeyCombo.unset.isSet)
    }

    func testActionRawValuesRoundTrip() {
        for kind in GestureAction.Kind.allCases {
            let a = GestureAction.make(kind)
            XCTAssertEqual(a.kind, kind)
            XCTAssertEqual(GestureAction(rawValue: a.rawValue), a, kind.rawValue)
        }
        let sc = GestureAction.shortcut(KeyCombo(keyCode: 6, modifiers: CGEventFlags.maskCommand.rawValue, label: "z"))
        XCTAssertEqual(GestureAction(rawValue: sc.rawValue), sc)
        let app = GestureAction.openApp("/Applications/My: App.app")
        XCTAssertEqual(GestureAction(rawValue: app.rawValue), app)
        // phase-1 strings stay valid
        XCTAssertEqual(GestureAction(rawValue: "missionControl"), .missionControl)
        XCTAssertEqual(GestureAction(rawValue: "smartZoom"), .smartZoom)
        XCTAssertNil(GestureAction(rawValue: "shortcut"))
        XCTAssertNil(GestureAction(rawValue: "bogus"))
    }

    func testMakeKeepsPayloadOfSameKind() {
        let sc = GestureAction.shortcut(KeyCombo(keyCode: 1, modifiers: 0))
        XCTAssertEqual(GestureAction.make(.shortcut, keeping: sc), sc)
        XCTAssertEqual(GestureAction.make(.shortcut, keeping: .launchpad), .shortcut(.unset))
        XCTAssertEqual(GestureAction.make(.openApp), .openApp(""))
    }

    func testGestureMapWithPayloadsCodable() throws {
        var m = GestureMap.defaults
        m[.threeFingerSwipeUp] = .shortcut(KeyCombo(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue))
        m[.fourFingerSpread] = .openApp("/Applications/Safari.app")
        m[.longPress] = .middleClick
        let back = try JSONDecoder().decode(GestureMap.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        XCTAssertFalse(back.isDefault)
        XCTAssertTrue(GestureMap.defaults.isDefault)
    }

    func testPhase1MapGetsNewSlotDefaults() throws {
        let old = Data(#"{"threeFingerSwipeUp":"launchpad","twoFingerDoubleTap":"none"}"#.utf8)
        let m = try JSONDecoder().decode(GestureMap.self, from: old)
        XCTAssertEqual(m[.threeFingerSwipeUp], .launchpad)
        XCTAssertEqual(m[.twoFingerTap], .rightClick)
        XCTAssertEqual(m[.longPress], .contextMenu)
        XCTAssertEqual(m[.rotate], .rotate)
    }

    func testAllowedKinds() {
        XCTAssertTrue(GestureTrigger.longPress.allowedKinds.contains(.contextMenu))
        XCTAssertFalse(GestureTrigger.threeFingerSwipeUp.allowedKinds.contains(.contextMenu))
        XCTAssertTrue(GestureTrigger.rotate.allowedKinds.contains(.rotate))
        XCTAssertFalse(GestureTrigger.twoFingerTap.allowedKinds.contains(.rotate))
        for t in GestureTrigger.allCases {
            XCTAssertTrue(t.allowedKinds.contains(GestureMap.defaults[t].kind), "default of \(t) is selectable")
            XCTAssertTrue(t.allowedKinds.contains(.shortcut))
            XCTAssertTrue(t.allowedKinds.contains(.openApp))
        }
    }

    func testRunnerNewActions() {
        let sink = RecordingSink()
        GestureActionRunner.run(.shortcut(KeyCombo(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue)), on: sink, at: .zero)
        GestureActionRunner.run(.shortcut(.unset), on: sink, at: .zero)
        GestureActionRunner.run(.openApp("/Applications/Safari.app"), on: sink, at: .zero)
        GestureActionRunner.run(.openApp(""), on: sink, at: .zero)
        GestureActionRunner.run(.rightClick, on: sink, at: CGPoint(x: 5, y: 6))
        GestureActionRunner.run(.leftClick, on: sink, at: CGPoint(x: 5, y: 6))
        GestureActionRunner.run(.middleClick, on: sink, at: CGPoint(x: 7, y: 8))
        GestureActionRunner.run(.rotate, on: sink, at: .zero)
        XCTAssertEqual(sink.events, ["key cmd+8", "open Safari.app", "rclick 5,6", "click 5,6",
                                     "mouse\(CGEventType.otherMouseDown.rawValue) 7,8",
                                     "mouse\(CGEventType.otherMouseUp.rawValue) 7,8"])
    }

    func testTitles() {
        XCTAssertEqual(GestureAction.openApp("/Applications/Safari.app").title, "Open Safari")
        XCTAssertEqual(GestureAction.openApp("").title, "Open app")
        XCTAssertEqual(GestureAction.shortcut(.unset).title, "Keyboard shortcut")
        XCTAssertEqual(GestureTrigger.longPress.title, "Long press")
    }
}

final class TapTargetSpy: GestureEngineDelegate {
    var longPresses = 0
    var offset = CGPoint(x: 5, y: -3)
    func onLongPress(at point: CGPoint) -> Bool { longPresses += 1; return true }
    func tapTarget(for point: CGPoint) -> CGPoint { CGPoint(x: point.x + offset.x, y: point.y + offset.y) }
}

final class RemappedSlotTests: XCTestCase {
    var sink: RecordingSink!
    var engine: GestureEngine!
    var now = 0.0

    override func setUp() { sink = RecordingSink(); make { _ in } }

    private func make(_ change: (inout GestureConfig) -> Void) {
        var cfg = GestureConfig()
        change(&cfg)
        engine = GestureEngine(poster: sink, config: cfg)
        now = 100
        engine.clock = { [unowned self] in self.now }
    }

    private func frame(_ pts: [(CGFloat, CGFloat)], after dt: Double = 0.01) {
        now += dt
        engine.update(pts.map { CGPoint(x: $0.0, y: $0.1) })
    }

    private func rotated(_ deg: CGFloat) -> [(CGFloat, CGFloat)] {
        let a = deg * .pi / 180
        return [(150 - 50 * cos(a), 100 - 50 * sin(a)), (150 + 50 * cos(a), 100 + 50 * sin(a))]
    }

    func testTwoFingerTapRemappedToMiddleClick() {
        make { $0.gestures[.twoFingerDoubleTap] = GestureAction.none; $0.gestures[.twoFingerTap] = .middleClick }
        frame([(100, 100), (200, 100)])
        frame([])
        XCTAssertEqual(sink.events, ["move 150,100", "mouse\(CGEventType.otherMouseDown.rawValue) 150,100",
                                     "mouse\(CGEventType.otherMouseUp.rawValue) 150,100"])
    }

    func testTwoFingerTapHeldBackWhileDoubleTapMapped() {
        make { $0.gestures[.twoFingerTap] = .shortcut(KeyCombo(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue)) }
        frame([(100, 100), (200, 100)])
        frame([])
        XCTAssertEqual(sink.events, ["move 150,100"])
        for _ in 0..<60 { now += 1.0 / 120; engine.tick() }
        XCTAssertEqual(sink.events, ["move 150,100", "key cmd+8"])
    }

    func testTwoFingerTapUnmappedDoesNothing() {
        make { $0.gestures[.twoFingerDoubleTap] = GestureAction.none; $0.gestures[.twoFingerTap] = GestureAction.none }
        frame([(100, 100), (200, 100)])
        frame([])
        XCTAssertEqual(sink.events, ["move 150,100"])
    }

    func testLongPressRemappedSkipsDelegate() {
        make { $0.gestures[.longPress] = .shortcut(KeyCombo(keyCode: 9, modifiers: CGEventFlags.maskCommand.rawValue)) }
        let spy = TapTargetSpy()
        engine.delegate = spy
        frame([(50, 60)])
        now += 0.55
        engine.tick()
        frame([])
        XCTAssertEqual(spy.longPresses, 0)
        XCTAssertEqual(sink.events, ["move 50,60", "key cmd+9"])
    }

    func testLongPressNoneSwallowsTap() {
        make { $0.gestures[.longPress] = GestureAction.none }
        frame([(50, 60)])
        now += 0.55
        engine.tick()
        frame([])
        XCTAssertEqual(sink.events, ["move 50,60"])
    }

    func testLongPressDurationFromConfig() {
        make { $0.longPress = 1.0 }
        frame([(50, 60)])
        now += 0.6
        engine.tick()
        XCTAssertEqual(sink.events, ["move 50,60"])
        now += 0.5
        engine.tick()
        XCTAssertEqual(sink.events.last, "rclick 50,60")
    }

    func testRotateRemappedFiresOnce() {
        make { $0.gestures[.rotate] = .missionControl }
        frame(rotated(0))
        frame(rotated(15))
        frame(rotated(30))
        frame(rotated(45))
        frame([])
        XCTAssertEqual(sink.events.filter { $0.hasPrefix("key") }, ["key ctrl+\(Key.up)"])
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("rot") || $0.hasPrefix("rclick") })
    }

    func testRotateUnmappedNoRotation() {
        make { $0.gestures[.rotate] = GestureAction.none }
        frame(rotated(0))
        frame(rotated(15))
        frame(rotated(30))
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("rot") })
    }

    func testTapUsesDelegateTarget() {
        let spy = TapTargetSpy()
        engine.delegate = spy
        frame([(50, 60)])
        frame([], after: 0.05)
        XCTAssertEqual(sink.events, ["move 50,60", "click 55,57"])
    }
}

// MARK: - Smart target

final class FakeProbe: AccessibilityProbe {
    var elements: [AXElementInfo] = []
    var background = AXElementInfo(role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    var calls: [CGPoint] = []
    func element(at p: CGPoint) -> AXElementInfo? {
        calls.append(p)
        return elements.first { $0.frame?.contains(p) == true } ?? background
    }
}

/// Fixed clock in the selection tests: the 5 ms budget must not depend on runner speed (cold start on CI took 2 s)
final class SmartTargetTests: XCTestCase {
    let cfg = SmartTargetConfig(radius: 10)

    func testSamplePointsOrderedAndCapped() {
        let pts = SmartTarget.samplePoints(around: .zero, radius: 10, maxSamples: 12)
        XCTAssertEqual(pts.count, 12)
        let d = pts.map { (hypot($0.x, $0.y) * 100).rounded() / 100 }
        XCTAssertEqual(d[0], 5, accuracy: 0.01)
        XCTAssertEqual(d[7], 5, accuracy: 0.01)
        XCTAssertEqual(d[8], 10, accuracy: 0.01)
        XCTAssertEqual(d, d.sorted(), "nearest first")
        XCTAssertEqual(SmartTarget.samplePoints(around: .zero, radius: 10, maxSamples: 99).count, 16)
        XCTAssertTrue(SmartTarget.samplePoints(around: .zero, radius: 0, maxSamples: 12).isEmpty)
    }

    func testDistanceToRect() {
        let r = CGRect(x: 10, y: 10, width: 20, height: 10)
        XCTAssertEqual(SmartTarget.distance(from: CGPoint(x: 15, y: 15), to: r), 0)
        XCTAssertEqual(SmartTarget.distance(from: CGPoint(x: 5, y: 15), to: r), 5)
        XCTAssertEqual(SmartTarget.distance(from: CGPoint(x: 33, y: 24), to: r), 5, accuracy: 0.001)
    }

    func testSnapPointCentreForSmallInsideForLarge() {
        let small = CGRect(x: 100, y: 100, width: 20, height: 20)
        XCTAssertEqual(SmartTarget.snapPoint(for: small, from: CGPoint(x: 95, y: 95), config: cfg), CGPoint(x: 110, y: 110))
        let field = CGRect(x: 100, y: 100, width: 300, height: 24)
        XCTAssertEqual(SmartTarget.snapPoint(for: field, from: CGPoint(x: 250, y: 92), config: cfg), CGPoint(x: 250, y: 103))
    }

    func testActionability() {
        XCTAssertTrue(SmartTarget.isActionable(AXElementInfo(role: "AXButton")))
        XCTAssertTrue(SmartTarget.isActionable(AXElementInfo(role: "AXStaticText", ancestorRoles: ["AXLink"])))
        XCTAssertTrue(SmartTarget.isActionable(AXElementInfo(role: "AXImage", actions: ["AXPress"])))
        XCTAssertFalse(SmartTarget.isActionable(AXElementInfo(role: "AXGroup", actions: ["AXPress"])))
        XCTAssertFalse(SmartTarget.isActionable(AXElementInfo(role: "AXStaticText")))
        XCTAssertTrue(SmartTarget.keepsTap(AXElementInfo(role: "AXStaticText", ancestorRoles: ["AXCell", "AXRow"])))
        XCTAssertTrue(SmartTarget.keepsTap(AXElementInfo(role: "AXTextArea")))
        XCTAssertFalse(SmartTarget.keepsTap(AXElementInfo(role: "AXWindow")))
    }

    func testTapOnButtonStaysWithOneProbe() {
        let probe = FakeProbe()
        probe.elements = [AXElementInfo(role: "AXButton", frame: CGRect(x: 90, y: 90, width: 20, height: 20))]
        let r = SmartTarget.resolve(CGPoint(x: 95, y: 95), probe: probe, config: cfg, clock: { 0 })
        XCTAssertEqual(r.point, CGPoint(x: 95, y: 95))
        XCTAssertFalse(r.snapped)
        XCTAssertEqual(probe.calls.count, 1)
    }

    func testTapNextToCheckboxSnapsToCentre() {
        let probe = FakeProbe()
        probe.elements = [AXElementInfo(role: "AXCheckBox", frame: CGRect(x: 104, y: 92, width: 16, height: 16))]
        let r = SmartTarget.resolve(CGPoint(x: 100, y: 100), probe: probe, config: cfg, clock: { 0 })
        XCTAssertEqual(r.point, CGPoint(x: 112, y: 100))
        XCTAssertEqual(r.role, "AXCheckBox")
        XCTAssertLessThanOrEqual(r.probes, 13)
    }

    func testNearestOfTwoWins() {
        let probe = FakeProbe()
        probe.elements = [
            AXElementInfo(role: "AXButton", frame: CGRect(x: 108, y: 90, width: 20, height: 20)),   // 8 pt right
            AXElementInfo(role: "AXLink", frame: CGRect(x: 80, y: 90, width: 16, height: 20)),      // 4 pt left
        ]
        let r = SmartTarget.resolve(CGPoint(x: 100, y: 100), probe: probe, config: cfg, clock: { 0 })
        XCTAssertEqual(r.role, "AXLink")
        XCTAssertEqual(r.point, CGPoint(x: 88, y: 100))
    }

    func testNothingInRadiusKeepsTap() {
        let probe = FakeProbe()
        probe.elements = [AXElementInfo(role: "AXButton", frame: CGRect(x: 130, y: 90, width: 20, height: 20))]
        let r = SmartTarget.resolve(CGPoint(x: 100, y: 100), probe: probe, config: cfg, clock: { 0 })
        XCTAssertEqual(r.point, CGPoint(x: 100, y: 100))
        XCTAssertFalse(r.snapped)
        XCTAssertLessThanOrEqual(probe.calls.count, 1 + cfg.maxSamples)
    }

    func testContentUnderFingerIsNeverMoved() {
        let probe = FakeProbe()
        probe.elements = [
            AXElementInfo(role: "AXStaticText", frame: CGRect(x: 0, y: 95, width: 200, height: 10), ancestorRoles: ["AXCell"]),
            AXElementInfo(role: "AXButton", frame: CGRect(x: 0, y: 106, width: 200, height: 20)),
        ]
        let r = SmartTarget.resolve(CGPoint(x: 100, y: 100), probe: probe, config: cfg, clock: { 0 })
        XCTAssertFalse(r.snapped)
        XCTAssertEqual(probe.calls.count, 1)
    }

    func testLabelSamplesSkippedInsideKnownLeafFrame() {
        let probe = FakeProbe()
        // label under the finger covers the inner ring horizontally; checkbox further left
        probe.elements = [
            AXElementInfo(role: "AXStaticText", frame: CGRect(x: 93, y: 96, width: 60, height: 8)),
            AXElementInfo(role: "AXCheckBox", frame: CGRect(x: 78, y: 92, width: 14, height: 16)),
        ]
        let r = SmartTarget.resolve(CGPoint(x: 100, y: 100), probe: probe, config: cfg, clock: { 0 })
        XCTAssertEqual(r.role, "AXCheckBox")
        XCTAssertEqual(r.point, CGPoint(x: 85, y: 100))
        XCTAssertFalse(probe.calls.dropFirst().contains { CGRect(x: 93, y: 96, width: 60, height: 8).contains($0) })
    }

    func testBudgetStopsSampling() {
        let probe = FakeProbe()
        var t = 0.0
        let r = SmartTarget.resolve(CGPoint(x: 100, y: 100), probe: probe, config: cfg, clock: { t += 0.002; return t })
        XCTAssertFalse(r.snapped)
        XCTAssertLessThan(probe.calls.count, 5)
    }

    func testNoElementKeepsTap() {
        final class Empty: AccessibilityProbe { func element(at point: CGPoint) -> AXElementInfo? { nil } }
        let r = SmartTarget.resolve(CGPoint(x: 1, y: 2), probe: Empty(), config: cfg, clock: { 0 })
        XCTAssertEqual(r, SmartTarget.Result(point: CGPoint(x: 1, y: 2), role: nil, probes: 1))
    }
}

final class TouchContextMenuModelTests: XCTestCase {
    override func setUp() { L10n.language = .english }

    func testShowMenuPreferred() {
        XCTAssertTrue(TouchContextMenuModel.prefersShowMenu(["AXPress", "AXShowMenu"]))
        XCTAssertFalse(TouchContextMenuModel.prefersShowMenu(["AXPress"]))
    }

    func testEntriesOrderAndFallbacks() {
        let e = TouchContextMenuModel.entries(actions: ["AXDecrement", "AXShowMenu", "AXIncrement", "AXPress", "AXScrollToVisible"])
        XCTAssertEqual(e, [.axAction("AXPress"), .axAction("AXIncrement"), .axAction("AXDecrement"), .copy, .paste, .rightClick])
        XCTAssertEqual(TouchContextMenuModel.entries(actions: []), [.copy, .paste, .rightClick])
        XCTAssertEqual(e.map(\.title), ["Press", "Increase", "Decrease", "Copy", "Paste", "Right click"])
    }

    func testTitleFallback() {
        XCTAssertEqual(TouchContextMenuModel.title(for: "AXFooBar"), "FooBar")
        L10n.language = .german
        XCTAssertEqual(TouchContextMenuModel.title(for: "AXPress"), "Drücken")
        L10n.language = .english
    }
}

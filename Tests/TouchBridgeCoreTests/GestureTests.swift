import CoreGraphics
import XCTest
@testable import TouchBridgeCore

/// Zeichnet die erzeugten Events als Text auf.
final class RecordingSink: EventSink {
    var events: [String] = []
    func move(_ p: CGPoint) { events.append("move \(Int(p.x)),\(Int(p.y))") }
    func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clicks: Int64) {
        let name: String
        switch type {
        case .leftMouseDown: name = "down"
        case .leftMouseUp: name = "up"
        case .leftMouseDragged: name = "drag"
        case .mouseMoved: name = "move"
        default: name = "mouse\(type.rawValue)"
        }
        events.append("\(name) \(Int(p.x)),\(Int(p.y))")
    }
    func click(_ p: CGPoint, right: Bool, clicks: Int64) {
        events.append("\(right ? "rclick" : "click")\(clicks > 1 ? "x\(clicks)" : "") \(Int(p.x)),\(Int(p.y))")
    }
    func scroll(dx: Int32, dy: Int32, phase: Int64) { events.append("scroll \(dx),\(dy) p\(phase)") }
    func key(_ code: CGKeyCode, flags: CGEventFlags) {
        let mod = flags.contains(.maskControl) ? "ctrl+" : (flags.contains(.maskCommand) ? "cmd+" : "")
        events.append("key \(mod)\(code)")
    }
    func magnify(_ amount: Double, phase: Int64) { events.append(String(format: "mag %.2f p%lld", amount, phase)) }
    func momentum(dx: Int32, dy: Int32, phase: Int64) { events.append("mom \(dx),\(dy) p\(phase)") }
    func rotate(_ degrees: Double, phase: Int64) { events.append(String(format: "rot %.1f p%lld", degrees, phase)) }
    func smartZoom(at p: CGPoint) { events.append("smartzoom \(Int(p.x)),\(Int(p.y))") }
    func openApp(_ candidates: [String]) {
        events.append("open " + (candidates.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""))
    }
}

final class LongPressSpy: GestureEngineDelegate {
    var points: [CGPoint] = []
    var handled = true
    func onLongPress(at point: CGPoint) -> Bool { points.append(point); return handled }
}

final class GestureTests: XCTestCase {
    var sink: RecordingSink!
    var engine: GestureEngine!
    var now = 0.0

    override func setUp() {
        sink = RecordingSink()
        engine = GestureEngine(poster: sink, config: GestureConfig())
        now = 100
        engine.clock = { [unowned self] in self.now }
    }

    private func frame(_ pts: [(CGFloat, CGFloat)], after dt: Double = 0.01) {
        now += dt
        engine.update(pts.map { CGPoint(x: $0.0, y: $0.1) })
    }

    /// Keeps the finger still for `seconds` with the engine's regular 50 ms tick
    private func hold(_ seconds: Double) {
        let steps = Int((seconds / 0.05).rounded())
        for _ in 0..<steps { now += 0.05; engine.tick() }
    }

    func testTapClicks() {
        frame([(100, 100)])
        frame([(101, 100)])
        frame([])
        XCTAssertEqual(sink.events, ["move 100,100", "click 100,100"])
        XCTAssertEqual(engine.mode, .idle)
    }

    func testDoubleTap() {
        frame([(100, 100)]); frame([])
        frame([(103, 102)], after: 0.15); frame([])
        XCTAssertEqual(sink.events.last, "clickx2 103,102")
    }

    func testDragProducesDownDragUp() {
        frame([(100, 100)])
        frame([(150, 100)])
        frame([(200, 120)])
        frame([])
        XCTAssertEqual(sink.events, ["move 100,100", "down 100,100", "drag 150,100", "drag 200,120", "up 200,120"])
    }

    func testLongPressRightClicks() {
        frame([(50, 60)])
        hold(0.7)
        frame([])
        XCTAssertEqual(sink.events, ["move 50,60", "rclick 50,60"])
    }

    func testSlowStillTouchDoesNotClickAfterTapWindow() {
        frame([(50, 60)])
        frame([], after: 0.5)  // länger als tapMaxDuration, aber vor dem Long-Press-Tick
        XCTAssertEqual(sink.events, ["move 50,60"])
    }

    func testTwoFingerTapRightClicks() {
        frame([(100, 100), (200, 100)])
        frame([])
        // 0.4: right click is held back for the 2-finger double-tap window (smart zoom)
        now += 0.35
        engine.tick()
        XCTAssertEqual(sink.events, ["move 150,100", "rclick 150,100"])
    }

    func testTwoFingerScroll() {
        frame([(100, 100), (200, 100)])
        frame([(100, 120), (200, 120)])   // Schwelle überschritten -> Scroll beginnt
        frame([(100, 150), (200, 150)])
        frame([])
        XCTAssertEqual(sink.events, ["move 150,100", "scroll 0,0 p1", "scroll 0,30 p2", "scroll 0,0 p4"])
    }

    func testInvertScroll() {
        var cfg = GestureConfig(); cfg.invertScroll = true
        engine = GestureEngine(poster: sink, config: cfg)
        engine.clock = { [unowned self] in self.now }
        frame([(100, 100), (200, 100)])
        frame([(100, 120), (200, 120)])
        frame([(100, 150), (200, 150)])
        XCTAssertTrue(sink.events.contains("scroll 0,-30 p2"))
    }

    func testPinchZoomIn() {
        var cfg = GestureConfig(); cfg.nativeZoom = false
        engine = GestureEngine(poster: sink, config: cfg)
        engine.clock = { [unowned self] in self.now }
        frame([(140, 100), (160, 100)])
        frame([(100, 100), (200, 100)])   // Abstand 20 -> 100: Pinch erkannt
        frame([(50, 100), (250, 100)])    // 100 -> 200: Cmd +
        XCTAssertEqual(sink.events.last, "key cmd+\(Key.zoomIn)")
    }

    func testAsymmetricPinchIsNotScroll() {
        var cfg = GestureConfig(); cfg.nativeZoom = false
        engine = GestureEngine(poster: sink, config: cfg)
        engine.clock = { [unowned self] in self.now }
        // ein Finger bleibt stehen, der andere wandert nach außen: Mittelpunkt bewegt sich, trotzdem Pinch
        frame([(100, 100), (200, 100)])
        frame([(100, 100), (230, 100)])
        frame([(100, 100), (300, 100)])
        frame([(100, 100), (360, 100)])
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("scroll") })
        XCTAssertEqual(sink.events.last, "key cmd+\(Key.zoomIn)")
    }

    func testPinchZoomOut() {
        var cfg = GestureConfig(); cfg.nativeZoom = false
        engine = GestureEngine(poster: sink, config: cfg)
        engine.clock = { [unowned self] in self.now }
        frame([(50, 100), (250, 100)])
        frame([(90, 100), (210, 100)])
        frame([(120, 100), (180, 100)])
        XCTAssertEqual(sink.events.last, "key cmd+\(Key.zoomOut)")
    }

    func testNativePinchSendsMagnifyPhases() {
        frame([(100, 100), (200, 100)])
        frame([(60, 100), (240, 100)])    // 100 -> 180: Pinch erkannt, Beginn
        frame([(30, 100), (300, 100)])    // 180 -> 270: +0.50
        frame([])
        let mags = sink.events.filter { $0.hasPrefix("mag") }
        XCTAssertEqual(mags, ["mag 0.00 p1", "mag 0.50 p2", "mag 0.00 p4"])
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("key") })
    }

    func testThreeFingerSwipeLeftSwitchesSpace() {
        frame([(300, 100), (350, 100), (400, 100)])
        frame([(250, 100), (300, 100), (350, 100)])
        frame([(150, 100), (200, 100), (250, 100)])
        frame([])
        XCTAssertEqual(sink.events, ["key ctrl+\(Key.right)"])
    }

    func testThreeFingerSwipeUpOpensMissionControl() {
        frame([(300, 400), (350, 400), (400, 400)])
        frame([(300, 250), (350, 250), (400, 250)])
        XCTAssertEqual(sink.events, ["key ctrl+\(Key.up)"])
    }

    func testDragIgnoresSecondFinger() {
        frame([(100, 100)])
        frame([(150, 100)])
        frame([(160, 100), (300, 300)])
        frame([])
        XCTAssertEqual(sink.events.last, "up 160,100")
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("scroll") })
    }

    // MARK: 0.4 phase 1

    private func makeEngine(_ change: (inout GestureConfig) -> Void) {
        var cfg = GestureConfig()
        change(&cfg)
        engine = GestureEngine(poster: sink, config: cfg)
        engine.clock = { [unowned self] in self.now }
    }

    private func flick() {
        frame([(100, 100), (200, 100)])
        frame([(100, 120), (200, 120)])
        frame([(100, 150), (200, 150)])
        frame([(100, 180), (200, 180)])
        frame([(100, 210), (200, 210)])
        frame([])
    }

    private func ticks(_ n: Int) {
        for _ in 0..<n { now += 1.0 / 120; engine.tick() }
    }

    func testMomentumAfterFlick() {
        flick()
        XCTAssertEqual(sink.events.last, "scroll 0,0 p4")
        XCTAssertTrue(engine.isMomentumActive)
        let before = sink.events.count
        ticks(300)
        let mom = Array(sink.events[before...])
        XCTAssertTrue(mom.first?.hasPrefix("mom 0,") == true && mom.first?.hasSuffix(" p1") == true, "\(mom)")
        XCTAssertTrue(mom.last?.hasSuffix(" p3") == true, "\(mom)")
        XCTAssertTrue(mom.dropFirst().dropLast().allSatisfy { $0.hasSuffix(" p2") })
        // same direction as the finger, decaying, everything is momentum (no scroll phase events)
        let dys = mom.compactMap { Int($0.split(separator: " ")[1].split(separator: ",")[1]) }
        XCTAssertTrue(dys.allSatisfy { $0 >= 0 })
        XCTAssertGreaterThan(dys.reduce(0, +), 100)
        XCTAssertTrue(mom.allSatisfy { $0.hasPrefix("mom") })
        XCTAssertFalse(engine.isMomentumActive)
    }

    func testMomentumInvertedFollowsScrollDirection() {
        makeEngine { $0.invertScroll = true }
        flick()
        ticks(300)
        let dys = sink.events.filter { $0.hasPrefix("mom") }.compactMap { Int($0.split(separator: " ")[1].split(separator: ",")[1]) }
        XCTAssertTrue(dys.allSatisfy { $0 <= 0 })
        XCTAssertLessThan(dys.reduce(0, +), -100)
    }

    func testNoMomentumAfterStoppingBeforeLift() {
        frame([(100, 100), (200, 100)])
        frame([(100, 120), (200, 120)])
        frame([(100, 150), (200, 150)])
        for _ in 0..<12 { frame([(100, 150), (200, 150)]) }   // 120 ms still
        frame([])
        ticks(100)
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("mom") })
        XCTAssertFalse(engine.isMomentumActive)
    }

    func testMomentumDisabled() {
        makeEngine { $0.momentumScroll = false }
        flick()
        XCTAssertFalse(engine.isMomentumActive)
        ticks(100)
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("mom") })
    }

    func testNewTouchStopsMomentum() {
        flick()
        ticks(5)
        XCTAssertTrue(engine.isMomentumActive)
        let before = sink.events.count
        frame([(300, 300), (400, 300)])
        XCTAssertFalse(engine.isMomentumActive)
        XCTAssertEqual(Array(sink.events[before...]), ["mom 0,0 p3", "scroll 0,0 p128", "move 350,300"])
        frame([])   // no scroll followed: mayBegin is cancelled
        XCTAssertEqual(sink.events.last, "scroll 0,0 p8")
        ticks(100)
        XCTAssertFalse(sink.events.dropFirst(before + 4).contains { $0.hasPrefix("mom") })
    }

    func testNewScrollAfterMomentumBeginsNormally() {
        flick()
        ticks(5)
        let before = sink.events.count
        frame([(100, 100), (200, 100)])
        frame([(100, 120), (200, 120)])
        XCTAssertEqual(Array(sink.events[before...]), ["mom 0,0 p3", "scroll 0,0 p128", "move 150,100", "scroll 0,0 p1"])
    }

    func testOneFingerScrollHasMomentum() {
        makeEngine { $0.oneFingerScroll = true }
        frame([(100, 100)])
        frame([(100, 130)])
        frame([(100, 160)])
        frame([(100, 190)])
        frame([])
        XCTAssertTrue(engine.isMomentumActive)
        ticks(300)
        XCTAssertEqual(sink.events.filter { $0.hasPrefix("mom") }.last?.hasSuffix("p3"), true)
    }

    private func rotated(_ deg: CGFloat) -> [(CGFloat, CGFloat)] {
        let a = deg * .pi / 180
        return [(150 - 50 * cos(a), 100 - 50 * sin(a)), (150 + 50 * cos(a), 100 + 50 * sin(a))]
    }

    func testRotateSendsRotationPhases() {
        frame(rotated(0))
        frame(rotated(15))     // clockwise on screen (y down) -> rotation recognised
        frame(rotated(30))     // another 15° clockwise = -15° (macOS: positive = counter-clockwise)
        frame([])
        let rots = sink.events.filter { $0.hasPrefix("rot") }
        XCTAssertEqual(rots, ["rot 0.0 p1", "rot -15.0 p2", "rot 0.0 p4"])
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("scroll") || $0.hasPrefix("mag") || $0.hasPrefix("rclick") })
    }

    private func rotated(_ deg: CGFloat, radius r: CGFloat) -> [(CGFloat, CGFloat)] {
        let a = deg * .pi / 180
        return [(150 - r * cos(a), 100 - r * sin(a)), (150 + r * cos(a), 100 + r * sin(a))]
    }

    func testImperfectRotateIsNotTakenForPinch() {
        // real hands: the finger distance drifts a little while turning
        frame(rotated(0, radius: 150))
        frame(rotated(5, radius: 154))
        frame(rotated(10, radius: 158))
        frame(rotated(16, radius: 162))
        frame([])
        XCTAssertTrue(sink.events.contains("rot 0.0 p1"))
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("mag") })
    }

    func testPinchStillWins() {
        frame([(100, 100), (200, 100)])
        frame([(90, 100), (210, 100)])
        frame([(80, 101), (220, 99)])
        frame([])
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("rot") })
    }

    func testRotateDisabledFallsBackToNothing() {
        makeEngine { $0.rotate = false }
        frame(rotated(0))
        frame(rotated(15))
        frame(rotated(30))
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("rot") })
    }

    func testTwoFingerDoubleTapSmartZoom() {
        frame([(100, 100), (200, 100)])
        frame([])
        frame([(102, 100), (202, 100)], after: 0.1)
        frame([])
        ticks(60)
        XCTAssertEqual(sink.events, ["move 150,100", "move 152,100", "smartzoom 152,100"])
    }

    func testTwoFingerTapImmediateWhenDoubleTapUnmapped() {
        makeEngine { $0.gestures[.twoFingerDoubleTap] = GestureAction.none }
        frame([(100, 100), (200, 100)])
        frame([])
        XCTAssertEqual(sink.events, ["move 150,100", "rclick 150,100"])
    }

    func testPendingRightClickFlushedByOneFingerTouch() {
        frame([(100, 100), (200, 100)])
        frame([])
        frame([(400, 400)], after: 0.05)
        XCTAssertEqual(sink.events, ["move 150,100", "rclick 150,100", "move 400,400"])
    }

    func testThreeFingerSwipeDownOpensAppExpose() {
        frame([(300, 100), (350, 100), (400, 100)])
        frame([(300, 250), (350, 250), (400, 250)])
        XCTAssertEqual(sink.events, ["key ctrl+\(Key.down)"])
    }

    func testThreeFingerSwipeRightGoesToPreviousSpace() {
        frame([(100, 100), (150, 100), (200, 100)])
        frame([(250, 100), (300, 100), (350, 100)])
        XCTAssertEqual(sink.events, ["key ctrl+\(Key.left)"])
    }

    func testFourFingerSwipeWithLateFourthFinger() {
        frame([(300, 100), (350, 100), (400, 100)])
        frame([(300, 100), (350, 100), (400, 100), (450, 100)])   // 4th finger: new baseline, nothing fires
        XCTAssertEqual(sink.events, [])
        frame([(150, 100), (200, 100), (250, 100), (300, 100)])
        XCTAssertEqual(sink.events, ["key ctrl+\(Key.right)"])
    }

    func testFourFingerPinchInOpensLaunchpad() {
        frame([(0, 0), (200, 0), (0, 200), (200, 200)])
        frame([(50, 50), (150, 50), (50, 150), (150, 150)])
        frame([])
        XCTAssertEqual(sink.events, ["open Launchpad.app"])
    }

    func testFiveFingerSpreadShowsDesktop() {
        frame([(80, 80), (120, 80), (80, 120), (120, 120), (100, 100)])
        frame([(20, 20), (180, 20), (20, 180), (180, 180), (100, 100)])
        XCTAssertEqual(sink.events, ["key \(GestureActionRunner.f11)"])
    }

    func testRemappedGesture() {
        makeEngine { $0.gestures[.threeFingerSwipeUp] = GestureAction.none; $0.gestures[.threeFingerSwipeDown] = .launchpad }
        frame([(300, 400), (350, 400), (400, 400)])
        frame([(300, 250), (350, 250), (400, 250)])
        frame([])
        frame([(300, 100), (350, 100), (400, 100)])
        frame([(300, 250), (350, 250), (400, 250)])
        XCTAssertEqual(sink.events, ["open Launchpad.app"])
    }

    func testLongPressDelegateHandles() {
        let spy = LongPressSpy()
        engine.delegate = spy
        frame([(50, 60)])
        hold(0.55)
        frame([])
        XCTAssertEqual(spy.points, [CGPoint(x: 50, y: 60)])
        XCTAssertEqual(sink.events, ["move 50,60"])
    }

    func testLongPressDelegateDeclinesFallsBackToRightClick() {
        let spy = LongPressSpy()
        spy.handled = false
        engine.delegate = spy
        frame([(50, 60)])
        hold(0.55)
        XCTAssertEqual(spy.points.count, 1)
        XCTAssertEqual(sink.events.last, "rclick 50,60")
    }

    func testGestureMapCodable() throws {
        var m = GestureMap.defaults
        m[.threeFingerSwipeUp] = .launchpad
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(GestureMap.self, from: data), m)
        let partial = Data(#"{"threeFingerSwipeUp":"none","bogus":"x","fourFingerSpread":"nope"}"#.utf8)
        let d = try JSONDecoder().decode(GestureMap.self, from: partial)
        XCTAssertEqual(d[.threeFingerSwipeUp], GestureAction.none)
        XCTAssertEqual(d[.fourFingerSpread], .showDesktop)
        XCTAssertEqual(d[.twoFingerDoubleTap], .smartZoom)
    }

    func testEveryTriggerHasDefault() {
        for t in GestureTrigger.allCases { XCTAssertNotNil(GestureMap.defaults.actions[t], t.rawValue) }
    }
}

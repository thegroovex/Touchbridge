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
        now += 0.7
        engine.tick()
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
        frame([(140, 100), (160, 100)])
        frame([(100, 100), (200, 100)])   // Abstand 20 -> 100: Pinch erkannt
        frame([(50, 100), (250, 100)])    // 100 -> 200: Cmd +
        XCTAssertEqual(sink.events.last, "key cmd+\(Key.equal)")
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
}

import CoreGraphics
import XCTest
@testable import TouchBridgeCore

/// Delegate whose "screen" can show a popup menu
final class MenuSpy: GestureEngineDelegate {
    var menus: [CGRect] = []
    var longPresses: [CGPoint] = []
    var outside: [CGPoint] = []
    var tapTargets = 0
    var handled = true
    /// Simulates AXShowMenu: the long press opens a menu
    var opensMenu: CGRect?
    func onLongPress(at point: CGPoint) -> Bool {
        longPresses.append(point)
        if let m = opensMenu { menus = [m] }
        return handled
    }
    func tapTarget(for point: CGPoint) -> CGPoint { tapTargets += 1; return CGPoint(x: point.x + 7, y: point.y) }
    func openMenuFrames() -> [CGRect] { menus }
    func tappedOutsideMenu(at point: CGPoint) { outside.append(point) }
}

final class MenuInteractionTests: XCTestCase {
    var sink: RecordingSink!
    var engine: GestureEngine!
    var spy: MenuSpy!
    var now = 0.0
    let menu = CGRect(x: 100, y: 100, width: 200, height: 300)

    override func setUp() {
        sink = RecordingSink()
        engine = GestureEngine(poster: sink, config: GestureConfig())
        spy = MenuSpy()
        engine.delegate = spy
        now = 50
        engine.clock = { [unowned self] in self.now }
    }

    private func frame(_ pts: [(CGFloat, CGFloat)], after dt: Double = 0.01) {
        now += dt
        engine.update(pts.map { CGPoint(x: $0.0, y: $0.1) })
    }

    private func hold(_ seconds: Double) {
        let steps = Int((seconds / 0.05).rounded())
        for _ in 0..<steps { now += 0.05; engine.tick() }
    }

    private func tap(_ x: CGFloat, _ y: CGFloat) {
        frame([(x, y)])
        frame([])
    }

    // MARK: - The reported bug: after the context menu opened, every touch acted like a right click

    func testTapsAfterLongPressMenuAreLeftClicks() {
        spy.opensMenu = menu
        frame([(150, 50)])
        hold(0.6)
        frame([])
        XCTAssertEqual(spy.longPresses.count, 1)
        XCTAssertEqual(engine.mode, .idle)
        sink.events = []
        // tap an item inside the open menu: plain left click at the finger, no smart target
        tap(150, 200)
        XCTAssertEqual(sink.events, ["move 150,200", "click 150,200"])
        XCTAssertEqual(spy.tapTargets, 0)
        XCTAssertTrue(spy.outside.isEmpty)
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("rclick") })
    }

    func testTapOutsideOpenMenuClicksAndAsksToClose() {
        spy.menus = [menu]
        tap(500, 500)
        XCTAssertEqual(sink.events, ["move 500,500", "click 500,500"])
        XCTAssertEqual(spy.outside, [CGPoint(x: 500, y: 500)])
    }

    func testLongPressWhileMenuOpenDoesNotOpenAnother() {
        spy.menus = [menu]
        frame([(150, 200)])
        hold(0.8)
        XCTAssertTrue(spy.longPresses.isEmpty)
        XCTAssertEqual(sink.events, ["move 150,200"])
        frame([])
        // the lift selects the item under the finger
        XCTAssertEqual(sink.events, ["move 150,200", "click 150,200"])
        XCTAssertEqual(engine.mode, .idle)
    }

    func testLongPressOutsideOpenMenuClosesIt() {
        spy.menus = [menu]
        frame([(600, 20)])
        hold(0.8)
        frame([])
        XCTAssertTrue(spy.longPresses.isEmpty)
        XCTAssertEqual(sink.events.last, "click 600,20")
        XCTAssertEqual(spy.outside, [CGPoint(x: 600, y: 20)])
    }

    func testSlowTapInsideMenuStillSelects() {
        spy.menus = [menu]
        frame([(150, 200)])
        frame([], after: 0.47)   // longer than tapMaxDuration, before the long press
        XCTAssertEqual(sink.events, ["move 150,200", "click 150,200"])
    }

    func testNoMenuNormalTapUsesSmartTarget() {
        tap(400, 400)
        XCTAssertEqual(sink.events, ["move 400,400", "click 407,400"])
        XCTAssertEqual(spy.tapTargets, 1)
    }

    // MARK: - Stalled run loop

    func testStalledTickDoesNotTurnLateTapIntoLongPress() {
        frame([(80, 80)])
        hold(0.05)
        // main thread blocked for 0.7 s: the next tick comes late, the queued lift right after it
        now += 0.7
        engine.tick()
        XCTAssertTrue(spy.longPresses.isEmpty, "a stalled tick must not fire the long press")
        frame([])
        XCTAssertFalse(sink.events.contains { $0.hasPrefix("rclick") })
        XCTAssertEqual(engine.mode, .idle)
    }

    func testFirstTickAfterStallDefersLongPress() {
        frame([(80, 80)])
        now += 0.9
        engine.tick()   // no earlier tick in this touch: the run loop was blocked
        XCTAssertTrue(spy.longPresses.isEmpty)
        hold(0.05)      // finger really still down: fires on the next regular tick
        XCTAssertEqual(spy.longPresses.count, 1)
    }

    func testLongPressStateResetsOnLift() {
        spy.handled = false
        frame([(80, 80)])
        hold(0.6)
        XCTAssertEqual(engine.mode, .longPressed)
        frame([])
        XCTAssertEqual(engine.mode, .idle)
        sink.events = []
        // a quick tap right after is a single left click, not a double click and not a right click
        tap(81, 80)
        XCTAssertEqual(sink.events, ["move 81,80", "click 88,80"])
    }

    // MARK: - Mouse button balance

    func testEveryMouseDownGetsAnUp() {
        frame([(100, 100)])
        frame([(150, 100)])
        engine.update([])
        let downs = sink.events.filter { $0.hasPrefix("down") }.count
        let ups = sink.events.filter { $0.hasPrefix("up") }.count
        XCTAssertEqual(downs, 1)
        XCTAssertEqual(ups, 1)
    }

    func testDragInterruptedByMoreFingersStillReleasesButton() {
        frame([(100, 100)])
        frame([(150, 100)])
        frame([(150, 100), (300, 300), (320, 300)])
        frame([])
        XCTAssertEqual(sink.events.filter { $0.hasPrefix("down") }.count, sink.events.filter { $0.hasPrefix("up") }.count)
    }

    // MARK: - Popup window detection

    func testPopupMenuWindowsFilter() {
        let info: [[String: Any]] = [
            ["kCGWindowLayer": 0, "kCGWindowNumber": 1, "kCGWindowOwnerPID": 10,
             "kCGWindowBounds": ["X": 0.0, "Y": 0.0, "Width": 800.0, "Height": 600.0]],
            ["kCGWindowLayer": 101, "kCGWindowNumber": 2, "kCGWindowOwnerPID": 10, "kCGWindowAlpha": 1.0,
             "kCGWindowBounds": ["X": 120.0, "Y": 140.0, "Width": 220.0, "Height": 310.0]],
            ["kCGWindowLayer": 101, "kCGWindowNumber": 3, "kCGWindowOwnerPID": 10, "kCGWindowAlpha": 0.0,
             "kCGWindowBounds": ["X": 0.0, "Y": 0.0, "Width": 200.0, "Height": 200.0]],
            ["kCGWindowLayer": 101, "kCGWindowNumber": 4, "kCGWindowOwnerPID": 10,
             "kCGWindowBounds": ["X": 5.0, "Y": 5.0, "Width": 4.0, "Height": 4.0]],
        ]
        let w = PopupMenus.windows(in: info)
        XCTAssertEqual(w, [PopupMenuWindow(number: 2, ownerPID: 10, frame: CGRect(x: 120, y: 140, width: 220, height: 310))])
    }

    func testStillOpenMatchesWindowNumbers() {
        let a = PopupMenuWindow(number: 7, ownerPID: 1, frame: menu)
        let b = PopupMenuWindow(number: 8, ownerPID: 1, frame: menu)
        XCTAssertEqual(PopupMenus.stillOpen([a, b], in: [b]), [b])
        XCTAssertTrue(PopupMenus.stillOpen([a], in: []).isEmpty)
    }
}

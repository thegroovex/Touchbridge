import CoreGraphics
import Foundation
import TouchBridgeCore

/// Hides the pointer while the touchscreen is used (like iPad/touch UIs) and shows it again as soon as a real
/// mouse or trackpad moves.
///
/// A background app may only hide the cursor after setting the private connection property
/// "SetsCursorInBackground" (CGSSetConnectionProperty / SLSSetConnectionProperty, resolved with dlsym). Without it
/// CGDisplayHideCursor only works while TouchBridge is frontmost – harmless, the pointer simply stays visible.
/// Restoring needs a listen-only event tap; if it cannot be created the pointer is never hidden (so it can never
/// get stuck invisible). Our own synthetic events carry SystemPointerFilter.marker and are ignored.
public final class CursorHider {
    public private(set) var hidden = false
    public var log: (String) -> Void = { print($0) }
    /// true while a touch is in progress (or just ended) – pointer events then come from the touchscreen itself
    public var touchOngoing: () -> Bool = { false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var backgroundSet = false
    private var unavailable = false
    private var loggedPath = false

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym(_ names: [String]) -> UnsafeMutableRawPointer? {
        for n in names {
            if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), n) { return p }   // RTLD_DEFAULT
            if let h = skylight, let p = dlsym(h, n) { return p }
        }
        return nil
    }
    private static let mainConnection: MainConnection? =
        sym(["_CGSDefaultConnection", "CGSMainConnectionID", "SLSMainConnectionID"]).map { unsafeBitCast($0, to: MainConnection.self) }
    private static let setProperty: SetConnectionProperty? =
        sym(["CGSSetConnectionProperty", "SLSSetConnectionProperty"]).map { unsafeBitCast($0, to: SetConnectionProperty.self) }

    public init() {}

    /// Allow hiding the cursor while not frontmost (once per process)
    private func enableBackgroundHiding() -> Bool {
        if backgroundSet { return true }
        guard let main = CursorHider.mainConnection, let set = CursorHider.setProperty else { return false }
        let cid = main()
        let err = set(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        backgroundSet = err == 0
        return backgroundSet
    }

    /// Called on every touch frame with contacts
    public func touchBegan() {
        guard !hidden, !unavailable else { return }
        guard startTap() else {
            unavailable = true
            log("⚠️  Pointer hiding unavailable: no event tap to detect real mouse movement (check permissions) – pointer stays visible.")
            return
        }
        let background = enableBackgroundHiding()
        if !loggedPath {
            loggedPath = true
            log(background ? "🖱  Pointer hiding: SetsCursorInBackground active – pointer hidden while touching"
                           : "🖱  Pointer hiding: private connection property unavailable – hiding only works while TouchBridge is frontmost")
        }
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    /// Show the pointer again (real mouse moved, setting off, service stopped)
    public func show() {
        guard hidden else { stopTap(); return }
        hidden = false
        CGDisplayShowCursor(CGMainDisplayID())
        stopTap()
    }

    private static let mask: CGEventMask = {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    private func startTap() -> Bool {
        if tap != nil { return true }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: CursorHider.mask, callback: { _, type, event, ctx in
            guard let ctx = ctx else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<CursorHider>.fromOpaque(ctx).takeUnretainedValue()
            me.handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: ctx) else { return false }
        tap = t
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func stopTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        guard hidden else { return }
        if event.getIntegerValueField(.eventSourceUserData) == SystemPointerFilter.marker { return }   // our own event
        if touchOngoing() { return }   // pointer events of the touchscreen's own mouse interface
        // not inside the tap callback: tearing down the tap happens on the next run-loop pass
        DispatchQueue.main.async { [weak self] in self?.show() }
    }
}

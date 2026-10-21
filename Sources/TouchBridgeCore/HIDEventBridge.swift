import CoreGraphics
import Foundation

/// Attaches a real IOHIDEvent to synthetic gesture/scroll CGEvents.
///
/// Since macOS 27 the WindowServer reportedly only honours synthetic gesture events (CGS type 29: magnify,
/// rotate, smart zoom; possibly continuous scroll) when they carry an IOHIDEvent payload attached with the
/// private SkyLight function `SLEventSetIOHIDEvent` (precedent: mac-mouse-fix PR #1920 / #1912 / #1916;
/// joshuarli/iss for dock swipes). Everything is resolved at runtime with dlsym – if a symbol is missing the
/// CGEvent is posted with its plain fields only (the pre-27 path). Undocumented, may change with any release.
public enum HIDEventBridge {
    /// Internal switch (default on). Off: `defaults write <bundle> attachIOHIDEvent -bool NO` or env TB_ATTACH_HID=0.
    public static var enabled: Bool = {
        if ProcessInfo.processInfo.environment["TB_ATTACH_HID"] == "0" { return false }
        return UserDefaults.standard.object(forKey: "attachIOHIDEvent") as? Bool ?? true
    }()
    /// Scroll events only get a payload on macOS 27+ (continuous scroll works without it up to macOS 26, and a
    /// mis-scaled payload could change scrolling there).
    public static var scrollOnlyFrom27 = true
    public static var log: ((String) -> Void)?

    public enum Kind: String { case scroll, magnify, rotate, smartZoom }

    // IOHIDEventType values (IOHIDEventTypes.h)
    static let typeRotation: Int64 = 5
    static let typeScroll: Int64 = 6
    static let typeScale: Int64 = 7
    static let typeZoom: Int64 = 8
    static let typeZoomToggle: Int64 = 22

    private typealias Create3 = @convention(c) (CFAllocator?, UInt64, Double, Double, Double, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias Create0 = @convention(c) (CFAllocator?, UInt64, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias SetBits = @convention(c) (CFTypeRef, UInt32) -> Void
    private typealias Attach = @convention(c) (CGEvent, CFTypeRef) -> Void

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func sym(_ handle: UnsafeMutableRawPointer?, _ name: String) -> UnsafeMutableRawPointer? {
        if let h = handle, let p = dlsym(h, name) { return p }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)   // RTLD_DEFAULT
    }

    private static let attach: Attach? = sym(skylight, "SLEventSetIOHIDEvent").map { unsafeBitCast($0, to: Attach.self) }
    private static let setPhase: SetBits? = sym(iokit, "IOHIDEventSetPhase").map { unsafeBitCast($0, to: SetBits.self) }
    private static let setMomentum: SetBits? = sym(iokit, "IOHIDEventSetScrollMomentum").map { unsafeBitCast($0, to: SetBits.self) }
    private static let createScroll: Create3? = sym(iokit, "IOHIDEventCreateScrollEvent").map { unsafeBitCast($0, to: Create3.self) }
    private static let createRotation: Create3? = sym(iokit, "IOHIDEventCreateRotationEvent").map { unsafeBitCast($0, to: Create3.self) }
    /// Zoom (type 8) is what trackpad magnify reports; Scale (type 7) as a second choice
    private static let createZoom: (Create3, String)? = {
        if let p = sym(iokit, "IOHIDEventCreateZoomEvent") { return (unsafeBitCast(p, to: Create3.self), "IOHIDEventCreateZoomEvent") }
        if let p = sym(iokit, "IOHIDEventCreateScaleEvent") { return (unsafeBitCast(p, to: Create3.self), "IOHIDEventCreateScaleEvent") }
        return nil
    }()
    private static let createZoomToggle: Create0? = sym(iokit, "IOHIDEventCreateZoomToggleEvent").map { unsafeBitCast($0, to: Create0.self) }

    /// Real macOS major version (sysctl is not affected by the SYSTEM_VERSION_COMPAT "16.0" shim)
    public static let osMajor: Int = {
        var size = 0
        if sysctlbyname("kern.osproductversion", nil, &size, nil, 0) == 0, size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osproductversion", &buf, &size, nil, 0) == 0,
               let major = Int(buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.split(separator: ".").first ?? "") { return major }
        }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }()

    private static var logged = Set<String>()
    private static func logOnce(_ kind: Kind, _ line: String) {
        guard !logged.contains(kind.rawValue) else { return }
        logged.insert(kind.rawValue)
        (log ?? { print($0) })(line)
    }

    /// One-line summary for diagnostics
    public static var summary: String {
        "IOHIDEvent attach: " + (enabled ? "on" : "off") + ", macOS \(osMajor)"
            + ", SLEventSetIOHIDEvent " + (attach != nil ? "found" : "missing")
            + ", scroll " + (createScroll != nil ? "yes" : "no")
            + ", rotation " + (createRotation != nil ? "yes" : "no")
            + ", zoom " + (createZoom?.1 ?? "no")
            + ", zoom toggle " + (createZoomToggle != nil ? "yes" : "no")
    }

    /// IOHIDEventPhaseBits: began 1, changed 2, ended 4, cancelled 8, mayBegin 0x80 (same values as the CG scroll phase)
    private static func finish(_ e: CGEvent, _ kind: Kind, _ created: Unmanaged<CFTypeRef>?, creator: String, phase: Int64?,
                               momentum: Int64? = nil) {
        guard let attach = attach else {
            logOnce(kind, "Gesture events (\(kind.rawValue)): plain CGEvent fields – SLEventSetIOHIDEvent not available")
            return
        }
        guard let created = created else {
            logOnce(kind, "Gesture events (\(kind.rawValue)): plain CGEvent fields – \(creator) not available")
            return
        }
        // +1 from IOHIDEventCreate*; the setter is assumed to retain (CF setter convention), Swift releases ours.
        let hid = created.takeRetainedValue()
        if let p = phase, p != 0, let set = setPhase { set(hid, UInt32(p)) }
        if let m = momentum, m != 0, let set = setMomentum {
            // CG momentum phase begin 1 / continue 2 / end 3 -> IOHIDEventScrollMomentumBits start 2 / continue 1 / end 4
            let bits: UInt32 = m == 1 ? 0x02 : (m == 2 ? 0x01 : 0x04)
            set(hid, bits)
        }
        attach(e, hid)
        logOnce(kind, "Gesture events (\(kind.rawValue)): IOHIDEvent attached via SLEventSetIOHIDEvent (\(creator))")
    }

    private static var now: UInt64 { mach_absolute_time() }

    public static func attachScroll(_ e: CGEvent, dx: Int32, dy: Int32, phase: Int64, momentum: Int64) {
        guard enabled else { return }
        if scrollOnlyFrom27 && osMajor < 27 {
            logOnce(.scroll, "Gesture events (scroll): plain CGEvent fields (macOS \(osMajor) < 27, no IOHIDEvent needed)")
            return
        }
        let ev = createScroll?(kCFAllocatorDefault, now, Double(dx), Double(dy), 0, 0)
        finish(e, .scroll, ev, creator: "IOHIDEventCreateScrollEvent", phase: phase, momentum: momentum)
    }

    public static func attachMagnify(_ e: CGEvent, amount: Double, phase: Int64) {
        guard enabled else { return }
        let ev = createZoom?.0(kCFAllocatorDefault, now, amount, amount, amount, 0)
        finish(e, .magnify, ev, creator: createZoom?.1 ?? "IOHIDEventCreateZoomEvent", phase: phase)
    }

    public static func attachRotate(_ e: CGEvent, degrees: Double, phase: Int64) {
        guard enabled else { return }
        let ev = createRotation?(kCFAllocatorDefault, now, 0, 0, degrees, 0)
        finish(e, .rotate, ev, creator: "IOHIDEventCreateRotationEvent", phase: phase)
    }

    public static func attachSmartZoom(_ e: CGEvent) {
        guard enabled else { return }
        let ev = createZoomToggle?(kCFAllocatorDefault, now, 0)
        finish(e, .smartZoom, ev, creator: "IOHIDEventCreateZoomToggleEvent", phase: nil)
    }
}

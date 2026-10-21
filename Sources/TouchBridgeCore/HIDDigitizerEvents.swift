import CoreGraphics
import Foundation

/// Builds IOHIDEvent digitizer collections (parent "hand" event + one child "finger" event per contact) for the
/// real-touch experiment. Structure and constants follow Apple's open-source IOHIDFamily (IOHIDEventTypes.h,
/// IOHIDEventData.h, IOHIDEvent.cpp: appendChild marks the parent as collection) and the userland signatures used
/// by WebKit's IOKitSPI. Everything is resolved with dlsym at runtime – a missing symbol only disables a variant.
/// Undocumented private API: purely experimental, never used on the normal touch path.
public enum HIDDigitizerEvents {
    // IOHIDEventType
    public static let typeVendorDefined: UInt32 = 1
    public static let typeDigitizer: UInt32 = 11
    // IOHIDDigitizerTransducerType
    public static let transducerFinger: UInt32 = 2
    public static let transducerHand: UInt32 = 3
    // IOHIDDigitizerEventMask
    public static let maskRange: UInt32 = 1 << 0
    public static let maskTouch: UInt32 = 1 << 1
    public static let maskPosition: UInt32 = 1 << 2
    public static let maskIdentity: UInt32 = 1 << 5
    public static let maskCancel: UInt32 = 1 << 7
    public static let maskStart: UInt32 = 1 << 8
    // Fields: IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) = 11 << 16
    static let fieldBase: UInt32 = 11 << 16
    public static let fieldChildEventMask: UInt32 = fieldBase + 24
    public static let fieldIsDisplayIntegrated: UInt32 = fieldBase + 25
    // IOHIDEventPhaseBits
    public static let phaseBegan: UInt32 = 1, phaseChanged: UInt32 = 2, phaseEnded: UInt32 = 4, phaseCancelled: UInt32 = 8

    /// One contact; x/y normalised 0…1 relative to the target display (origin top left)
    public struct Contact {
        public var id: UInt32
        public var x: Double
        public var y: Double
        public var touching: Bool
        /// began / moved / ended – selects the event mask bits
        public enum Stage { case began, moved, ended }
        public var stage: Stage
        public init(id: UInt32, x: Double, y: Double, touching: Bool, stage: Stage) {
            self.id = id; self.x = x; self.y = y; self.touching = touching; self.stage = stage
        }
    }

    private typealias CreateDigitizer = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
                                                        Double, Double, Double, Double, Double, UInt32, UInt32, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias CreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32,
                                                     Double, Double, Double, Double, Double, UInt32, UInt32, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias CreateFingerQ = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32,
                                                      Double, Double, Double, Double, Double, Double, Double, Double, Double, Double,
                                                      UInt32, UInt32, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias CreateVendor = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UnsafePointer<UInt8>, Int, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias Append = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    private typealias SetInt = @convention(c) (CFTypeRef, UInt32, Int) -> Void
    private typealias SetU32 = @convention(c) (CFTypeRef, UInt32) -> Void
    private typealias SetU64 = @convention(c) (CFTypeRef, UInt64) -> Void
    private typealias GetType = @convention(c) (CFTypeRef) -> UInt32
    private typealias GetChildren = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias Attach = @convention(c) (CGEvent, CFTypeRef) -> Void
    private typealias Copy = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym(_ h: UnsafeMutableRawPointer?, _ n: String) -> UnsafeMutableRawPointer? {
        if let h = h, let p = dlsym(h, n) { return p }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), n)   // RTLD_DEFAULT
    }

    private static let createDigitizer = sym(iokit, "IOHIDEventCreateDigitizerEvent").map { unsafeBitCast($0, to: CreateDigitizer.self) }
    private static let createFinger = sym(iokit, "IOHIDEventCreateDigitizerFingerEvent").map { unsafeBitCast($0, to: CreateFinger.self) }
    private static let createFingerQ = sym(iokit, "IOHIDEventCreateDigitizerFingerEventWithQuality").map { unsafeBitCast($0, to: CreateFingerQ.self) }
    private static let createVendor = sym(iokit, "IOHIDEventCreateVendorDefinedEvent").map { unsafeBitCast($0, to: CreateVendor.self) }
    private static let append = sym(iokit, "IOHIDEventAppendEvent").map { unsafeBitCast($0, to: Append.self) }
    private static let setInt = sym(iokit, "IOHIDEventSetIntegerValue").map { unsafeBitCast($0, to: SetInt.self) }
    private static let setPhase = sym(iokit, "IOHIDEventSetPhase").map { unsafeBitCast($0, to: SetU32.self) }
    private static let setSender = sym(iokit, "IOHIDEventSetSenderID").map { unsafeBitCast($0, to: SetU64.self) }
    private static let getType = sym(iokit, "IOHIDEventGetType").map { unsafeBitCast($0, to: GetType.self) }
    private static let getChildren = sym(iokit, "IOHIDEventGetChildren").map { unsafeBitCast($0, to: GetChildren.self) }
    private static let attachFn = sym(skylight, "SLEventSetIOHIDEvent").map { unsafeBitCast($0, to: Attach.self) }
    private static let copyFn: (Copy, String)? = {
        for n in ["SLEventCopyIOHIDEvent", "CGEventCopyIOHIDEvent"] {
            if let p = sym(skylight, n) { return (unsafeBitCast(p, to: Copy.self), n) }
        }
        return nil
    }()

    /// Can a digitizer collection be built and attached at all?
    public static var available: Bool { createDigitizer != nil && (createFinger != nil || createFingerQ != nil) && append != nil && attachFn != nil }

    public static var summary: String {
        func y(_ b: Bool) -> String { b ? "yes" : "MISSING" }
        return "IOHIDEventCreateDigitizerEvent \(y(createDigitizer != nil)), FingerEvent \(y(createFinger != nil)), "
            + "FingerEventWithQuality \(y(createFingerQ != nil)), VendorDefined \(y(createVendor != nil)), "
            + "AppendEvent \(y(append != nil)), SetIntegerValue \(y(setInt != nil)), SetPhase \(y(setPhase != nil)), "
            + "SetSenderID \(y(setSender != nil)), SLEventSetIOHIDEvent \(y(attachFn != nil)), "
            + "copy back \(copyFn?.1 ?? "MISSING")"
    }

    /// Fake multitouch device id (NSTouch groups touches per device; legacy gesture events carried it in a
    /// vendor-defined child event, usage page 0xFF00 usage 0x1777 – calftrail TouchSynthesis)
    public static let fakeDeviceID: UInt64 = 0x5442_0000_0000_0001

    private static func mask(_ c: Contact) -> UInt32 {
        switch c.stage {
        case .began: return maskRange | maskTouch | maskIdentity | maskPosition
        case .moved: return maskPosition
        case .ended: return maskRange | maskTouch | maskIdentity
        }
    }

    /// Hand event with one finger child per contact (+ vendor device-id child). Returns nil if a creator is missing.
    public static func makeHand(_ contacts: [Contact], displayIntegrated: Bool, phase: UInt32?, vendorChild: Bool = true) -> CFTypeRef? {
        guard let mkDigitizer = createDigitizer, let appendFn = append else { return nil }
        let ts = mach_absolute_time()
        let touching = contacts.contains { $0.touching }
        let n = Double(max(1, contacts.count))
        let cx = contacts.reduce(0.0) { $0 + $1.x } / n
        let cy = contacts.reduce(0.0) { $0 + $1.y } / n
        let childMask = contacts.reduce(UInt32(0)) { $0 | mask($1) }
        guard let parentU = mkDigitizer(kCFAllocatorDefault, ts, transducerHand, 0, 0, childMask, 0,
                                            cx, cy, 0, 0, 0, touching ? 1 : 0, touching ? 1 : 0, 0) else { return nil }
        let parent = parentU.takeRetainedValue()
        for (i, c) in contacts.enumerated() {
            let identity = UInt32(2 + i)   // 2 = index finger, 3 = middle … (IOHIDEvent.cpp hard-codes 2 for fingers)
            let t: UInt32 = c.touching ? 1 : 0
            var child: Unmanaged<CFTypeRef>?
            if let q = createFingerQ {
                child = q(kCFAllocatorDefault, ts, c.id, identity, mask(c), c.x, c.y, 0, c.touching ? 0.5 : 0, 0,
                          5, 5, c.touching ? 1 : 0, 0, 0, t, t, 0)
            } else if let f = createFinger {
                child = f(kCFAllocatorDefault, ts, c.id, identity, mask(c), c.x, c.y, 0, c.touching ? 0.5 : 0, 0, t, t, 0)
            }
            guard let ch = child?.takeRetainedValue() else { continue }
            if displayIntegrated, let s = setInt { s(ch, fieldIsDisplayIntegrated, 1) }
            if let p = phase, let s = setPhase { s(ch, p) }
            appendFn(parent, ch, 0)
        }
        if vendorChild, let v = createVendor {
            var payload = [UInt8](repeating: 0, count: 40)
            withUnsafeBytes(of: fakeDeviceID.littleEndian) { for (i, b) in $0.enumerated() { payload[i] = b } }
            if let vu = payload.withUnsafeBufferPointer({ v(kCFAllocatorDefault, ts, 0xFF00, 0x1777, 1, $0.baseAddress!, $0.count, 0) }) {
                appendFn(parent, vu.takeRetainedValue(), 0)
            }
        }
        if let s = setInt {
            s(parent, fieldChildEventMask, Int(childMask))
            if displayIntegrated { s(parent, fieldIsDisplayIntegrated, 1) }
        }
        if let p = phase, let s = setPhase { s(parent, p) }
        if let s = setSender { s(parent, fakeDeviceID) }
        return parent
    }

    /// Attach via SLEventSetIOHIDEvent; returns false when the function is missing
    @discardableResult
    public static func attach(_ e: CGEvent, _ hid: CFTypeRef) -> Bool {
        guard let a = attachFn else { return false }
        a(e, hid)
        return true
    }

    /// Reads the attached IOHIDEvent back ("type 11, 3 children") – proves the payload stuck to the CGEvent
    public static func describeAttached(_ e: CGEvent) -> String {
        guard let c = copyFn else { return "copy back not available" }
        let name = c.1
        guard let u = c.0(e) else { return "\(name): no IOHIDEvent attached" }
        let ev = u.takeRetainedValue()
        let type = getType.map { String($0(ev)) } ?? "?"
        let kids = getChildren.flatMap { $0(ev)?.takeUnretainedValue() }.map { String(CFArrayGetCount($0)) } ?? "0"
        return "\(name): IOHIDEvent type \(type), \(kids) children"
    }
}

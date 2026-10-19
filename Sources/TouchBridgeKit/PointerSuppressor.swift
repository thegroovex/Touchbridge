import CoreGraphics
import Foundation
import TouchBridgeCore

/// Fallback, wenn eine Schnittstelle des Touch-Monitors nicht exklusiv übernommen werden kann:
/// Ein aktiver CGEventTap (HID-Ebene, braucht Bedienungshilfen) verwirft die Maus-/Klick-/Scroll-Events,
/// die macOS selbst aus dem Gerät erzeugt. Erkennung:
///  1. Absender-Registry-ID des zugrunde liegenden IOHIDEvent (private CGEventCopyIOHIDEvent + IOHIDEventGetSenderID,
///     per dlsym – fehlt eins davon, entfällt dieser Weg),
///  2. sonst: Hardware-Event (kCGEventSourceUnixProcessID == 0) zeitgleich mit Touch-Reports.
/// Eigene Events tragen SystemPointerFilter.marker in kCGEventSourceUserData und gehen immer durch.
/// Hinweis: Die reine Zeigerbewegung (Cursor) setzt der WindowServer evtl. schon vor dem Tap; deshalb korrigiert
/// TouchService die Position zusätzlich absolut (CGWarpMouseCursorPosition + eigene mouseMoved/dragged).
public final class PointerSuppressor {
    public struct Stats: Equatable {
        public var droppedBySender = 0
        public var droppedByTime = 0
        public var passed = 0
        public var senderIDAvailable = false
    }
    public private(set) var stats = Stats()
    public private(set) var active = false
    /// Erste Hardware-Events mit ihren Feldern (für die Diagnose)
    public private(set) var samples: [String] = []

    public var deviceIDs: Set<UInt64> = []
    public var lastReport: () -> Double? = { nil }
    public var touching: () -> Bool = { false }
    public var log: (String) -> Void = { print($0) }

    private var filter = SystemPointerFilter()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private typealias CopyHIDEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias GetSenderID = @convention(c) (CFTypeRef) -> UInt64
    private static let copyHIDEvent: CopyHIDEvent? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventCopyIOHIDEvent") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(p, to: CopyHIDEvent.self)
    }()
    private static let getSenderID: GetSenderID? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventGetSenderID") else { return nil }
        return unsafeBitCast(p, to: GetSenderID.self)
    }()
    public static var senderIDSupported: Bool { copyHIDEvent != nil && getSenderID != nil }

    public init() {}

    static func senderID(of e: CGEvent) -> UInt64? {
        guard let copy = copyHIDEvent, let get = getSenderID, let ev = copy(e) else { return nil }
        let obj = ev.takeRetainedValue()
        let id = get(obj)
        return id == 0 ? nil : id
    }

    private static let mask: CGEventMask = {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    /// Startet den Tap. false, wenn macOS ihn nicht erlaubt (Bedienungshilfen fehlen).
    @discardableResult
    public func start() -> Bool {
        guard !active else { return true }
        stats = Stats(senderIDAvailable: PointerSuppressor.senderIDSupported)
        samples = []
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: PointerSuppressor.mask, callback: { _, type, event, ctx in
            guard let ctx = ctx else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<PointerSuppressor>.fromOpaque(ctx).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: ctx) else {
            log("⚠️  Systemzeiger-Unterdrückung: Event-Tap nicht erlaubt (Bedienungshilfen für TouchBridge erlauben).")
            return false
        }
        tap = t
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        active = true
        log("🛡  Systemzeiger-Unterdrückung aktiv (Event-Tap; Absender-ID " + (stats.senderIDAvailable ? "verfügbar" : "nicht verfügbar – Zeitkorrelation") + ").")
        return true
    }

    public func stop() {
        guard active else { return }
        active = false
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
        log("🛡  Systemzeiger-Unterdrückung aus (verworfen: \(stats.droppedBySender) per Absender-ID, \(stats.droppedByTime) per Zeitkorrelation).")
    }

    public var statsLine: String {
        "Systemzeiger-Unterdrückung: " + (active ? "aktiv" : "aus")
            + " – Absender-ID " + (PointerSuppressor.senderIDSupported ? "verfügbar" : "nicht verfügbar")
            + ", verworfen \(stats.droppedBySender) (Absender) / \(stats.droppedByTime) (Zeit), durchgelassen \(stats.passed)"
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let info = SystemPointerFilter.EventInfo(
            userData: event.getIntegerValueField(.eventSourceUserData),
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
            senderID: PointerSuppressor.senderID(of: event),
            time: CFAbsoluteTimeGetCurrent())
        if info.userData != SystemPointerFilter.marker && info.sourcePID == 0 && samples.count < 12 {
            samples.append(String(format: "Event-Tap: Typ %d pid %lld state %lld subtype %lld sender %@",
                                  type.rawValue, info.sourcePID, event.getIntegerValueField(.eventSourceStateID),
                                  event.getIntegerValueField(.mouseEventSubtype),
                                  info.senderID.map { String(format: "0x%llX", $0) + (deviceIDs.contains($0) ? " (Touch-Monitor)" : "") } ?? "–"))
        }
        switch filter.verdict(info, deviceIDs: deviceIDs, lastReport: lastReport(), touching: touching()) {
        case .pass: stats.passed += 1; return Unmanaged.passUnretained(event)
        case .dropSender: stats.droppedBySender += 1; return nil
        case .dropCorrelated: stats.droppedByTime += 1; return nil
        }
    }
}

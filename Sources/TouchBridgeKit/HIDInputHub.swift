import Foundation
import IOKit
import IOKit.hid
import TouchBridgeCore

/// Prozessweit genau EIN Input-Report-Callback (und höchstens ein Value-Callback) je IOHIDDevice.
///
/// - Der Hub besitzt Puffer, Runloop-Einplanung und Callback-Registrierung für die gesamte Lebensdauer des
///   Geräts. Der Puffer wird nie freigegeben, solange er bei IOKit registriert sein könnte.
/// - Context ist der Registry-Schlüssel als Integer (kein Objektzeiger). Der C-Callback schlägt die aktuellen
///   Beobachter in einer Tabelle nach (schwach gehalten) und ignoriert unbekannte Schlüssel.
/// - Touch-Dienst und Diagnose hängen sich als Beobachter ein; keiner registriert selbst Callbacks.
/// - Abmelden beim Entfernen des Geräts mit DEMSELBEN Context (IOKit vergleicht Einträge nur per Context).
/// Nur auf dem Main-Thread benutzen (alle Geräte laufen auf dem Main-Runloop).
public final class HIDInputHub {
    public static let shared = HIDInputHub()

    public enum Event {
        case report(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>, result: IOReturn)
        case value(IOHIDValue)
    }

    /// Abmeldung eines Beobachters (auch automatisch bei deinit)
    public final class Observation {
        public let key: UInt64
        fileprivate let token: Int
        private var cancelled = false
        fileprivate init(key: UInt64, token: Int) { self.key = key; self.token = token }
        public func cancel() {
            guard !cancelled else { return }
            cancelled = true
            HIDInputHub.shared.remove(self)
        }
        deinit { cancel() }
    }

    private struct Native {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let size: Int
        var valueCallback = false
    }

    private let reports = HIDObserverTable<Event>()
    private let values = HIDObserverTable<Event>()
    private var natives: [UInt64: Native] = [:]
    /// Puffer abgemeldeter Geräte: absichtlich nie freigegeben (wenige hundert Bytes je Ab-/Anstecken),
    /// damit IOKit nie in freigegebenen Speicher schreiben kann.
    private var retired: [UnsafeMutablePointer<UInt8>] = []
    public var log: ((String) -> Void)?

    private init() {}

    /// Stabiler Schlüssel: IORegistryEntryID, sonst die (vom Hub gehaltene) Objektadresse mit gesetztem Top-Bit.
    public static func key(for device: IOHIDDevice) -> UInt64 {
        if let id = HIDOpenRegistry.registryID(device), id != 0 { return id }
        let p = UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
        return p | (1 << 63)
    }

    /// Anzahl lebender Report-Beobachter (Diagnose/Tests)
    public func observerCount(_ device: IOHIDDevice) -> Int { reports.observerCount(key: Self.key(for: device)) }

    /// Beobachter für Input-Reports (und optional Werte) anhängen. Registriert den IOKit-Callback nur beim
    /// allerersten Beobachter des Geräts. `handler` bekommt den Owner übergeben (nicht stark einfangen).
    @discardableResult
    public func observe<O: AnyObject>(_ device: IOHIDDevice, owner: O, values wantValues: Bool = false,
                                      _ handler: @escaping (O, Event) -> Void) -> Observation {
        let key = Self.key(for: device)
        let (token, first) = reports.add(key: key, owner: owner, handler: handler)
        if first || natives[key] == nil { registerNative(device, key: key) }
        else { ensureScheduled(key) }
        let obs = Observation(key: key, token: token)
        if wantValues {
            let (vt, _) = values.add(key: key, owner: owner, handler: handler)
            valueTokens[token] = vt
            if var n = natives[key], !n.valueCallback {
                IOHIDDeviceRegisterInputValueCallback(n.device, HIDInputHub.valueCallback, HIDObserverTable<Event>.context(for: key))
                n.valueCallback = true
                natives[key] = n
            }
        }
        return obs
    }

    private var valueTokens: [Int: Int] = [:]

    fileprivate func remove(_ o: Observation) {
        reports.remove(o.token)
        if let vt = valueTokens.removeValue(forKey: o.token) {
            values.remove(vt)
            // Kein Werte-Beobachter mehr: Value-Callback mit demselben Context abmelden (der Puffer betrifft ihn nicht)
            if values.observerCount(key: o.key) == 0, var n = natives[o.key], n.valueCallback {
                IOHIDDeviceRegisterInputValueCallback(n.device, nil, HIDObserverTable<Event>.context(for: o.key))
                n.valueCallback = false
                natives[o.key] = n
            }
        }
    }

    /// Re-add the device's event source to the main run loop. An IOHIDManager unschedules every device it
    /// enumerated when it is unscheduled/released (TouchService.stop()); the hub's long-lived IOHIDDevice may be
    /// one of those objects, and then no report callback fires until the app restarts. Adding an already
    /// scheduled source again is a no-op (CFRunLoopAddSource ignores duplicates).
    public func ensureScheduled(_ device: IOHIDDevice) { ensureScheduled(Self.key(for: device)) }

    private func ensureScheduled(_ key: UInt64) {
        guard let n = natives[key] else { return }
        IOHIDDeviceScheduleWithRunLoop(n.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    private func registerNative(_ device: IOHIDDevice, key: UInt64) {
        guard natives[key] == nil else { return }
        let maxSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 0
        let size = max(maxSize, 256)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        natives[key] = Native(device: device, buffer: buffer, size: size)
        // einmal einplanen und bis zum Entfernen eingeplant lassen (unabhängig von Open/Close)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, HIDInputHub.reportCallback,
                                               HIDObserverTable<Event>.context(for: key))
    }

    /// Gerät abgesteckt (Removal-Callback): Callbacks mit demselben Context abmelden, vom Runloop nehmen,
    /// Beobachter verwerfen. Der Puffer wird nicht freigegeben (siehe `retired`).
    /// Nach dem Abstecken liefert IOHIDDeviceGetService evtl. nichts mehr – daher zuerst per Objekt bzw.
    /// mitgegebener Registry-ID suchen.
    public func deviceRemoved(_ device: IOHIDDevice, registryID: UInt64? = nil) {
        let key = natives.first(where: { $0.value.device === device })?.key
            ?? registryID.flatMap { natives[$0] != nil ? $0 : nil }
            ?? Self.key(for: device)
        values.deviceGone(key: key)
        let had = reports.deviceGone(key: key)
        guard had, let n = natives.removeValue(forKey: key) else { return }
        let ctx = HIDObserverTable<Event>.context(for: key)
        IOHIDDeviceRegisterInputReportCallback(n.device, n.buffer, n.size, nil, ctx)
        if n.valueCallback { IOHIDDeviceRegisterInputValueCallback(n.device, nil, ctx) }
        IOHIDDeviceUnscheduleFromRunLoop(n.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        retired.append(n.buffer)
    }

    // MARK: C-Callbacks (ohne Captures; Context = Schlüssel)

    private static let reportCallback: IOHIDReportCallback = { ctx, result, _, _, reportID, report, length in
        guard let key = HIDObserverTable<Event>.key(from: ctx), length >= 0 else { return }
        HIDInputHub.shared.reports.dispatch(key: key, .report(reportID: reportID,
                                                               bytes: UnsafeBufferPointer(start: report, count: length),
                                                               result: result))
    }

    private static let valueCallback: IOHIDValueCallback = { ctx, _, _, value in
        guard let key = HIDObserverTable<Event>.key(from: ctx) else { return }
        HIDInputHub.shared.values.dispatch(key: key, .value(value))
    }
}

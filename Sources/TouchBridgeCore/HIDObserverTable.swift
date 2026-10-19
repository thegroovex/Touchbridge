import Foundation

// MARK: - Callback-Lebensdauer für IOHIDDevice (prozessweit, ohne IOKit testbar)
//
// Hintergrund (Absturz in 0.3.1, EXC_BAD_ACCESS in TouchDevice.handle):
// IOHIDDeviceRegisterInputReportCallback legt Einträge in einem CFSet ab, dessen Gleichheit NUR über den
// Context-Zeiger läuft (IOKitUser/hid.subproj/IOHIDDevice.c, __IOHIDDeviceCallbackBaseDataIsEqual). Abmelden mit
// `callback = nil, context = nil` entfernt deshalb nichts – der Eintrag mit dem Context des freigegebenen
// TouchDevice blieb stehen. Außerdem merkt sich die Gerätekasse genau EINEN Report-Puffer: den zuletzt
// registrierten. Wurde dieser Puffer freigegeben (Diagnose fertig, Gerät neu geöffnet), schrieb macOS in
// freigegebenen Speicher.
//
// Lösung: pro IOHIDDevice genau eine native Registrierung mit stabilem Integer-Context (Registry-Schlüssel) und
// einem Puffer, der nie freigegeben wird, solange er registriert ist. Der C-Callback schlägt die aktuellen
// Beobachter hier nach (schwach gehalten) und ignoriert unbekannte Schlüssel.

/// Beobachter je Gerät (Schlüssel = IORegistryEntryID). Nur auf dem Main-Thread benutzen.
public final class HIDObserverTable<Event> {
    public typealias Token = Int

    private final class Observer {
        weak var owner: AnyObject?
        let handler: (AnyObject, Event) -> Void
        init(owner: AnyObject, handler: @escaping (AnyObject, Event) -> Void) { self.owner = owner; self.handler = handler }
    }

    private var observers: [UInt64: [Token: Observer]] = [:]
    private var tokenKeys: [Token: UInt64] = [:]
    private var native: Set<UInt64> = []
    private var nextToken = 1

    public init() {}

    /// Beobachter anhängen. `needsNativeRegistration` ist nur beim ersten Beobachter eines Geräts true –
    /// dann (und nur dann) muss der Aufrufer den IOKit-Callback registrieren.
    /// Der Handler bekommt den Owner übergeben, damit er ihn nicht stark einfangen muss.
    public func add<O: AnyObject>(key: UInt64, owner: O, handler: @escaping (O, Event) -> Void)
        -> (token: Token, needsNativeRegistration: Bool) {
        let t = nextToken
        nextToken += 1
        observers[key, default: [:]][t] = Observer(owner: owner) { o, e in
            if let o = o as? O { handler(o, e) }
        }
        tokenKeys[t] = key
        let first = native.insert(key).inserted
        return (t, first)
    }

    /// Beobachter abmelden. Die native Registrierung bleibt bestehen (Puffer bleibt gültig) bis `deviceGone`.
    public func remove(_ token: Token) {
        guard let key = tokenKeys.removeValue(forKey: token) else { return }
        observers[key]?[token] = nil
    }

    /// Verteilt ein Ereignis an alle lebenden Beobachter. Unbekannte Schlüssel und tote Owner werden ignoriert
    /// (tote werden dabei entfernt). Rückgabe: Zahl der aufgerufenen Handler.
    @discardableResult
    public func dispatch(key: UInt64, _ event: Event) -> Int {
        guard let obs = observers[key], !obs.isEmpty else { return 0 }
        var n = 0
        for (t, o) in obs.sorted(by: { $0.key < $1.key }) {
            guard let owner = o.owner else { remove(t); continue }
            o.handler(owner, event)
            n += 1
        }
        return n
    }

    public func observerCount(key: UInt64) -> Int {
        observers[key]?.values.filter { $0.owner != nil }.count ?? 0
    }

    public func isRegistered(key: UInt64) -> Bool { native.contains(key) }

    /// Gerät entfernt: alle Beobachter fallen weg. true, wenn eine native Registrierung bestand
    /// (der Aufrufer meldet sie dann mit DEMSELBEN Context ab).
    @discardableResult
    public func deviceGone(key: UInt64) -> Bool {
        if let obs = observers.removeValue(forKey: key) { for t in obs.keys { tokenKeys[t] = nil } }
        return native.remove(key) != nil
    }

    /// Stabiler Context-Zeiger für einen Schlüssel (der Integer selbst, kein Objektzeiger).
    public static func context(for key: UInt64) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: UInt(truncatingIfNeeded: key))
    }

    public static func key(from context: UnsafeMutableRawPointer?) -> UInt64? {
        guard let c = context else { return nil }
        return UInt64(UInt(bitPattern: c))
    }
}

/// Schwache Zuordnung Integer -> Objekt für C-Callbacks (z. B. IOHIDManager-Matching), damit nie ein
/// Unmanaged-Zeiger auf ein kurzlebiges Objekt als Context dient.
public final class WeakRegistry<T: AnyObject> {
    private final class Box { weak var value: T?; init(_ v: T) { value = v } }
    private var boxes: [Int: Box] = [:]
    private var next = 1
    public init() {}

    public func register(_ v: T) -> Int {
        let k = next
        next += 1
        boxes[k] = Box(v)
        return k
    }
    public func lookup(_ k: Int) -> T? { boxes[k]?.value }
    public func remove(_ k: Int) { boxes[k] = nil }

    public static func context(_ k: Int) -> UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: k) }
    public static func key(_ c: UnsafeMutableRawPointer?) -> Int? { c.map { Int(bitPattern: $0) } }
}

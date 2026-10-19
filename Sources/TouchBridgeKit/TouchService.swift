import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import TouchBridgeCore

/// Betriebsart: Touch als Maus & Gesten oder als MIDI-Controller.
public enum InputMode: String, Codable, CaseIterable {
    case gestures, midi
    public var title: String { self == .gestures ? "Maus & Gesten" : "MIDI" }
}

/// Einstellungen, die CLI und Menüleisten-App teilen.
public struct TouchSettings: Codable, Equatable {
    public var enabled = true
    public var displayID: UInt32? = nil       // nil = automatisch (erster externer Bildschirm)
    public var rotation = 0                   // 0, 90, 180, 270
    public var flipX = false
    public var flipY = false
    public var swapXY = false
    public var invertScroll = false
    public var scrollGain = 1.0
    public var seize = true
    public var vid: Int? = nil
    public var pid: Int? = nil
    // MIDI-Modus
    public var mode: InputMode = .gestures
    public var midiLayout: MIDILayoutPreset = .mixer
    public var mpe = true
    public var midiChannel = 1                // 1…16 (ohne MPE bzw. für Fader/Pads/XY ohne MPE)
    public var baseNote = 48                  // C2 (Ableton-Zählung, C3 = 60)
    public var scale: Scale = .chromatic
    public var bendRange = 48
    public var showOverlay = true
    /// Wenn eine Schnittstelle nicht exklusiv ist: macOS-eigene Maus-Events des Touch-Monitors per Event-Tap verwerfen
    public var suppressSystemPointer = true
    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, displayID, rotation, flipX, flipY, swapXY, invertScroll, scrollGain, seize, vid, pid
        case mode, midiLayout, mpe, midiChannel, baseNote, scale, bendRange, showOverlay, suppressSystemPointer
    }

    /// Fehlende Schlüssel (ältere gespeicherte Einstellungen) fallen auf die Standardwerte zurück.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TouchSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        enabled = v(.enabled, d.enabled)
        displayID = (try? c.decodeIfPresent(UInt32.self, forKey: .displayID)) ?? nil
        rotation = v(.rotation, d.rotation)
        flipX = v(.flipX, d.flipX)
        flipY = v(.flipY, d.flipY)
        swapXY = v(.swapXY, d.swapXY)
        invertScroll = v(.invertScroll, d.invertScroll)
        scrollGain = v(.scrollGain, d.scrollGain)
        seize = v(.seize, d.seize)
        vid = (try? c.decodeIfPresent(Int.self, forKey: .vid)) ?? nil
        pid = (try? c.decodeIfPresent(Int.self, forKey: .pid)) ?? nil
        mode = v(.mode, d.mode)
        midiLayout = v(.midiLayout, d.midiLayout)
        mpe = v(.mpe, d.mpe)
        midiChannel = max(1, min(16, v(.midiChannel, d.midiChannel)))
        baseNote = max(0, min(108, v(.baseNote, d.baseNote)))
        scale = v(.scale, d.scale)
        bendRange = max(1, min(96, v(.bendRange, d.bendRange)))
        showOverlay = v(.showOverlay, d.showOverlay)
        suppressSystemPointer = v(.suppressSystemPointer, d.suppressSystemPointer)
    }

    public var mapping: TouchMapping { TouchMapping(rotation: rotation, flipX: flipX, flipY: flipY, swapXY: swapXY) }
    public func gestureConfig(base: GestureConfig = GestureConfig()) -> GestureConfig {
        var g = base
        g.invertScroll = invertScroll
        g.scrollGain = CGFloat(scrollGain)
        return g
    }
    public var midiConfig: MIDIConfig {
        var c = MIDIConfig()
        c.mpe = mpe
        c.channel = max(0, min(15, midiChannel - 1))
        c.bendRange = bendRange
        return c
    }
    public var midiLayoutModel: MIDILayout { midiLayout.build(baseNote: baseNote, scale: scale) }
    /// Im MIDI-Modus wird das Gerät immer exklusiv angefordert (sonst bewegt macOS zusätzlich den Cursor).
    public var effectiveSeize: Bool { seize || mode == .midi }
}

public enum Permissions {
    public static var accessibility: Bool { AXIsProcessTrusted() }
    /// Zeigt den Bedienungshilfen-Dialog („… möchte diesen Mac steuern“), falls nicht erteilt.
    public static func requestAccessibility() {
        askedAccessibility = true
        let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(o)
    }
    public static var inputMonitoring: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    public static var accessCheck: AccessCheck {
        let a = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if a == kIOHIDAccessTypeGranted { return .granted }
        if a == kIOHIDAccessTypeDenied { return .denied }
        return .unknown
    }
    public static var inputMonitoringState: String {
        switch accessCheck {
        case .granted: return "erteilt"
        case .denied: return "ABGELEHNT"
        case .unknown: return "noch nicht entschieden"
        }
    }
    public static func requestInputMonitoring() {
        askedInputMonitoring = true
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // Nur EINMAL automatisch fragen (gemerkt in den Einstellungen); danach nur noch Hinweis im Menü.
    public static var askedAccessibility: Bool {
        get { UserDefaults.standard.bool(forKey: "askedAccessibility") }
        set { UserDefaults.standard.set(newValue, forKey: "askedAccessibility") }
    }
    public static var askedInputMonitoring: Bool {
        get { UserDefaults.standard.bool(forKey: "askedInputMonitoring") }
        set { UserDefaults.standard.set(newValue, forKey: "askedInputMonitoring") }
    }
    public static func requestAccessibilityOnce() {
        guard !accessibility, !askedAccessibility else { return }
        requestAccessibility()
    }
    public static func requestInputMonitoringOnce() {
        guard !inputMonitoring, !askedInputMonitoring else { return }
        requestInputMonitoring()
    }
    /// Nach „Berechtigungen zurücksetzen“: wieder fragen dürfen
    public static func forgetAsked() { askedAccessibility = false; askedInputMonitoring = false }
}

/// Liest HID-Multitouch-Geräte und speist Gesten als macOS-Events ein. Läuft auf dem Main-Runloop.
public final class TouchService {
    public struct Status: Equatable {
        public var running = false
        public var devices: [String] = []
        public var exclusive = false
        public var lastError: String? = nil
        public var inputMonitoring = true
        /// Grund, warum das Gerät nicht exklusiv ist (Return-Code von IOHIDDeviceOpen mit Seize)
        public var seizeError: String? = nil
        /// Geöffnete Schnittstellen des Touch-Monitors (Touch, Maus, Vendor …) mit Exklusiv-Status
        public var interfaces: [InterfaceStatus] = []
        /// Fehlgeschlagene IOHIDDeviceOpen-Return-Codes (für die Berechtigungs-Auswertung)
        public var openFailures: [UInt32] = []
        /// Mindestens ein Touch-Report ist angekommen
        public var receiving = false
        /// alter LaunchAgent gefunden (Menü bietet Entfernen an)
        public var legacyAgent = false
        /// Event-Tap-Fallback aktiv
        public var suppressing = false
    }
    /// Berechtigung nach tatsächlicher Wirkung (Reports, Return-Codes), nicht nur nach IOHIDCheckAccess
    public var inputMonitoringState: InputMonitoringState {
        InputMonitoringState.evaluate(check: Permissions.accessCheck, openRCs: status.openFailures,
                                      reports: reportCount, asked: Permissions.askedInputMonitoring)
    }
    /// Event-Tap-Fallback, wenn eine Schnittstelle nicht exklusiv ist
    public let suppressor = PointerSuppressor()
    /// Zeit des letzten Touch-Reports und ob gerade berührt wird (für den Event-Tap)
    public private(set) var lastTouchReport: Double?
    fileprivate func touchReportSeen() { lastTouchReport = CFAbsoluteTimeGetCurrent() }
    private var registry: HIDOpenRegistry { HIDOpenRegistry.shared }
    /// Return-Codes beim Öffnen / Input Mode je Gerät (für Diagnose und Menü)
    public private(set) var openLog: [String] = []
    /// Anzahl empfangener HID-Input-Reports seit start()
    public private(set) var reportCount = 0
    fileprivate func countReport() {
        reportCount += 1
        if !status.receiving { status.receiving = true }
    }

    public var settings: TouchSettings {
        didSet {
            engine.config = settings.gestureConfig(base: gestureBase)
            if settings.mode != oldValue.mode {
                // laufende Geste bzw. klingende Noten sauber beenden
                if oldValue.mode == .gestures, engine.isActive { engine.update([]) }
                if oldValue.mode == .midi { midiEngine?.releaseAll() }
            }
            if let m = midiEngine {
                m.setLayout(settings.midiLayoutModel)
                m.setConfig(settings.midiConfig)
            }
            if settings.mode != oldValue.mode || settings.midiLayout != oldValue.midiLayout
                || settings.baseNote != oldValue.baseNote || settings.scale != oldValue.scale {
                onMIDIUpdate?()
            }
            if settings.suppressSystemPointer != oldValue.suppressSystemPointer { updateSuppression() }
            if settings.enabled != oldValue.enabled || settings.effectiveSeize != oldValue.effectiveSeize
                || settings.vid != oldValue.vid || settings.pid != oldValue.pid || settings.mode != oldValue.mode {
                if running { stop(); start() }
            }
        }
    }
    /// Wird im MIDI-Modus nach jedem Frame aufgerufen (Overlay-Anzeige).
    public var onMIDIUpdate: (() -> Void)?
    /// MIDI-Engine (nur im MIDI-Modus angelegt) – Layout, Finger und Werte für das Overlay.
    public private(set) var midiEngine: MIDIEngine?
    private var midiOutput: CoreMIDIOutput?
    /// Nur Kontakte protokollieren, keine Events senden (Diagnose / --dump).
    public var dumpMode = false
    public var log: (String) -> Void = { print($0) }
    public var onStatus: ((Status) -> Void)?
    public private(set) var status = Status() { didSet { if status != oldValue { onStatus?(status) } } }

    public let gestureBase: GestureConfig
    private let poster = EventPoster()
    private lazy var engine = GestureEngine(poster: poster, config: settings.gestureConfig(base: gestureBase))
    private var manager: IOHIDManager?
    private var devices: [TouchDevice] = []
    private var pending: [IOHIDDevice] = []
    private var retryTimer: Timer?
    private var timer: Timer?
    private var running = false
    public let staleTimeout = 0.5

    public init(settings: TouchSettings, gestureBase: GestureConfig = GestureConfig()) {
        self.settings = settings
        self.gestureBase = gestureBase
        suppressor.lastReport = { [weak self] in self?.lastTouchReport }
        suppressor.touching = { [weak self] in self?.devices.contains(where: \.hadContacts) ?? false }
    }

    /// Hersteller-/Produktnamen der geöffneten Touch-Geräte (für die automatische Bildschirmwahl)
    public private(set) var deviceHints: [String] = []
    public var targetDisplay: CGDirectDisplayID { Displays.resolve(settings.displayID, deviceHints: deviceHints) }

    /// Geräte, die zum Touch-Monitor gehören können: Digitizer/Touchscreen (0x0D/0x04) und der Anmite per VID/PID –
    /// bzw. nur VID/PID, wenn per --vid/--pid vorgegeben.
    private var matching: [[String: Any]] {
        var m: [String: Any] = [:]
        if let v = settings.vid { m[kIOHIDVendorIDKey] = v }
        if let p = settings.pid { m[kIOHIDProductIDKey] = p }
        if !m.isEmpty { return [m] }
        return [[kIOHIDDeviceUsagePageKey: Int(Usage.pageDigitizer), kIOHIDDeviceUsageKey: Int(Usage.touchScreen)],
                [kIOHIDVendorIDKey: HIDProbe.anmiteVID, kIOHIDProductIDKey: HIDProbe.anmitePID]]
    }

    public func start() {
        guard !running else { return }
        running = true
        openLog = []
        reportCount = 0
        guard settings.enabled || dumpMode else { status = Status(running: false); return }

        suppressor.log = log
        let access = Permissions.inputMonitoring
        log("🔐 Eingabeüberwachung: \(Permissions.inputMonitoringState)")
        if !access {
            // Anfragen übernimmt der Aufrufer (App: nur einmal); hier nur Hinweis
            log("⚠️  Ohne Eingabeüberwachung liefert macOS keine Touch-Reports. Systemeinstellungen › Datenschutz & Sicherheit › Eingabeüberwachung › TouchBridge erlauben.")
        }

        // Der Manager dient nur zum Finden der Geräte. Geöffnet wird jedes Gerät einzeln (IOHIDDeviceOpen),
        // damit Seize-Fehler pro Gerät sauber auf „nicht exklusiv“ zurückfallen können. (Früher: ein zweites
        // IOHIDManagerOpen nach fehlgeschlagenem Seize – das öffnete die Geräte nicht mehr, es kamen keine Reports.)
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            Unmanaged<TouchService>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            Unmanaged<TouchService>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        status = Status(running: true, devices: [], exclusive: false, lastError: nil, inputMonitoring: access)
        lastTouchReport = nil
        // Bereits angeschlossene Geräte sofort übernehmen (der Matching-Callback dedupliziert)
        if let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> {
            for d in set { attach(d) }
        }
        if devices.isEmpty { log("ℹ️  Noch kein Touch-Gerät gefunden – warte auf Anschluss.") }

        let midi = settings.mode == .midi && !dumpMode
        if midi { startMIDI() }

        // commonModes: Touch funktioniert auch, während ein Menü oder Dialog offen ist.
        // Im MIDI-Modus schneller (4 ms), damit gedrosselte Werte zügig nachgesendet werden.
        let t = Timer(timeInterval: midi ? 0.004 : 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for d in self.devices { d.checkStale(self.staleTimeout) }
            if self.dumpMode { return }
            if self.settings.mode == .midi { self.midiEngine?.tick() } else { self.engine.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let r = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.retryDevices() }
        RunLoop.main.add(r, forMode: .common)
        retryTimer = r
    }

    public func stop() {
        guard running else { return }
        running = false
        timer?.invalidate(); timer = nil
        retryTimer?.invalidate(); retryTimer = nil
        pending.removeAll()
        if engine.isActive { engine.update([]) }
        midiEngine?.releaseAll()
        onMIDIUpdate?()
        // erst Callbacks abmelden und Geräte schließen, dann Buffer/Context freigeben
        for d in devices { d.close() }
        devices.removeAll()
        suppressor.stop()
        if let m = manager {
            IOHIDManagerRegisterDeviceMatchingCallback(m, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(m, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        manager = nil
        status = Status(running: false)
    }

    private func note(_ line: String) {
        openLog.append(line)
        log(line)
    }

    /// Legt den virtuellen MIDI-Port (einmal pro Prozess) und die Engine an und sendet die MPE-Konfiguration.
    private func startMIDI() {
        if midiOutput == nil { midiOutput = CoreMIDIOutput(name: "TouchBridge", log: log) }
        guard let out = midiOutput else {
            status.lastError = "MIDI-Port konnte nicht angelegt werden"
            return
        }
        if let m = midiEngine {
            m.setLayout(settings.midiLayoutModel)
            m.setConfig(settings.midiConfig)
            m.start()
        } else {
            let m = MIDIEngine(sink: out, layout: settings.midiLayoutModel, config: settings.midiConfig)
            midiEngine = m
            m.start()
        }
        log("🎛  MIDI-Modus: Layout \(settings.midiLayout.title), " + (settings.mpe ? "MPE (Kanal 1 Master, 2–16 Member)" : "Kanal \(settings.midiChannel)"))
        onMIDIUpdate?()
    }

    /// Öffnet ein Interface genau einmal (Seize mit Fallback auf nicht exklusiv). quiet: bei Wiederholungen nur Änderungen loggen.
    private func open(_ d: TouchDevice, quiet: Bool) -> IOReturn {
        let seize = settings.effectiveSeize
        var rc: IOReturn
        d.exclusive = false
        if seize {
            rc = registry.open(d.device, seize: true)
            if !quiet || rc != d.lastSeizeRC {
                note("   IOHIDDeviceOpen (Seize/exklusiv) \(d.label): " + HIDReturn.describe(rc))
            }
            d.lastSeizeRC = rc
            if rc == kIOReturnSuccess {
                d.exclusive = true
                return rc
            }
            if !quiet || d.seizeMessage == nil { d.seizeMessage = seizeMessage(rc) }
            if !quiet {
                note("⚠️  \(d.label): exklusiver Zugriff nicht möglich (\(d.seizeMessage ?? "")) – öffne nicht exklusiv, neuer Versuch alle 2 s.")
            }
        }
        rc = registry.open(d.device, seize: false)
        if !quiet || rc != d.lastOpenRC { note("   IOHIDDeviceOpen (nicht exklusiv) \(d.label): " + HIDReturn.describe(rc)) }
        d.lastOpenRC = rc
        return rc
    }

    /// Meldung für einen gescheiterten Seize – „läuft doppelt“ nur, wenn wirklich ein zweiter Prozess/LaunchAgent existiert.
    private func seizeMessage(_ rc: IOReturn) -> String {
        let code = UInt32(bitPattern: rc)
        var others: [OtherInstance] = []
        var agent = false
        var holders: [String] = []
        if code == HIDReturnCode.exclusiveAccess {
            others = SystemCheck.otherInstances()
            agent = SystemCheck.legacyAgentPresent
            status.legacyAgent = agent
            if others.isEmpty && !agent {
                let r = SystemCheck.holderReport(vid: settings.vid ?? HIDProbe.anmiteVID, pid: settings.pid ?? HIDProbe.anmitePID)
                for i in r.duplicateOwnClients(ownPID: getpid()) {
                    note("❌ TouchBridge hält \(i.name) (id \(i.registryID.map { String(format: "0x%llX", $0) } ?? "?")) doppelt offen")
                }
                holders = r.likelyHolders(ownPID: getpid())
                if !holders.isEmpty { note("   Mögliche Halter laut ioreg: " + holders.joined(separator: "; ")) }
            }
        }
        return HIDOpenMessages.seizeFailure(rc: code, others: others, legacyAgent: agent, holders: holders)
    }

    /// Alle 2 s: nicht geöffnete Geräte erneut öffnen, nicht exklusive Geräte erneut exklusiv anfordern
    /// (vorher sauber schließen – nie ein zweites IOHIDDeviceOpen auf ein offenes Interface).
    private func retryDevices() {
        guard running else { return }
        for dev in pending { attach(dev, quiet: true) }
        if settings.effectiveSeize {
            for d in devices where !d.exclusive && !d.hadContacts {   // nie mitten in einer Berührung
                d.close()
                let rc = open(d, quiet: true)
                if rc == kIOReturnSuccess { d.start() } else { devices.removeAll { $0 === d }; pending.append(d.device) }
                if d.exclusive { note("✅ \(d.label) jetzt exklusiv übernommen."); d.seizeMessage = nil }
            }
        }
        refreshStatus()
    }

    private func refreshStatus() {
        status.devices = devices.filter(\.isTouch).map(\.name)
        status.interfaces = devices.map { InterfaceStatus(registryID: $0.registryID ?? 0, role: $0.role, exclusive: $0.exclusive) }
        status.exclusive = !devices.isEmpty && devices.allSatisfy(\.exclusive)
        status.seizeError = devices.first(where: { !$0.exclusive && $0.seizeMessage != nil })
            .map { "\($0.role.rawValue): \($0.seizeMessage ?? "")" }
        updateSuppression()
    }

    /// Event-Tap-Fallback ein, wenn eine Schnittstelle nicht exklusiv ist (und die Option an ist), sonst aus.
    private func updateSuppression() {
        let want = running && settings.enabled && !dumpMode && settings.suppressSystemPointer
            && devices.contains(where: { !$0.exclusive })
        if want {
            suppressor.deviceIDs = Set(devices.flatMap { HIDOpenRegistry.descendantIDs($0.device) })
            if !suppressor.active { suppressor.start() }
        } else if suppressor.active {
            suppressor.stop()
        }
        status.suppressing = suppressor.active
    }

    /// Schnittstellen des Touch-Monitors: per VID/PID (vorgegeben oder Anmite) – dann werden auch Maus-/Vendor-
    /// Schnittstellen exklusiv übernommen, damit macOS den Zeiger nicht selbst bewegt.
    private func isMonitorInterface(_ device: IOHIDDevice) -> Bool {
        let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        if settings.vid != nil || settings.pid != nil {
            return (settings.vid == nil || settings.vid == vid) && (settings.pid == nil || settings.pid == pid)
        }
        return vid == HIDProbe.anmiteVID && pid == HIDProbe.anmitePID
    }

    private func attach(_ device: IOHIDDevice) { attach(device, quiet: false) }

    private func attach(_ raw: IOHIDDevice, quiet: Bool) {
        guard running, manager != nil else { return }
        // ein IOHIDDevice-Objekt pro Registry-ID, jedes Interface genau einmal
        let (device, rid) = registry.canonical(raw)
        guard !devices.contains(where: { $0.device === device || ($0.registryID != nil && $0.registryID == rid) }) else { return }
        guard let d = TouchDevice(device: device, service: self, registryID: rid, auxiliary: isMonitorInterface(device), quiet: quiet) else { return }
        let rc = open(d, quiet: quiet)
        guard rc == kIOReturnSuccess else {
            let code = UInt32(bitPattern: rc)
            let msg = HIDOpenMessages.openFailure(rc: code, others: code == HIDReturnCode.exclusiveAccess ? SystemCheck.otherInstances() : [],
                                                  legacyAgent: code == HIDReturnCode.exclusiveAccess && SystemCheck.legacyAgentPresent)
            if !quiet { note("❌ \(d.label): " + msg) }
            if d.isTouch { status.lastError = msg }
            if !status.openFailures.contains(code) { status.openFailures.append(code) }
            if !pending.contains(where: { $0 === device }) { pending.append(device) }
            return
        }
        pending.removeAll { $0 === device }
        status.openFailures.removeAll()
        let exclusive = d.exclusive
        d.start()
        devices.append(d)
        if d.isTouch, let r = HIDFeature.applyInputMode(device, descriptor: d.descriptor, name: d.name, log: { [weak self] in self?.note($0) }) {
            if r != kIOReturnSuccess { note("   (Input Mode ließ sich nicht setzen – Touch kann trotzdem funktionieren)") }
        }
        if d.isTouch { status.lastError = nil }
        deviceHints = devices.flatMap(\.hints)
        refreshStatus()
        if d.isTouch {
            let b = CGDisplayBounds(targetDisplay)
            note("🖥  Touch-Ziel: \(Displays.name(of: targetDisplay)) (id \(targetDisplay)) \(Int(b.width))×\(Int(b.height)) @ (\(Int(b.minX)),\(Int(b.minY)))"
                 + (exclusive ? " – exklusiv" : " – NICHT exklusiv"))
        } else {
            note("🔒 Schnittstelle \(d.label) " + (exclusive ? "exklusiv übernommen (macOS bekommt keine Events mehr davon)" : "NICHT exklusiv geöffnet"))
        }
        note("   " + InterfaceStatus.summary(status.interfaces))
    }

    private func detach(_ raw: IOHIDDevice) {
        let rid = HIDOpenRegistry.registryID(raw)
        let same: (IOHIDDevice) -> Bool = { $0 === raw || (rid != nil && HIDOpenRegistry.registryID($0) == rid) }
        pending.removeAll(where: same)
        devices.removeAll { d in
            if same(d.device) { log("🔌 Gerät getrennt: \(d.label)"); d.close(); registry.forget(d.device); return true }
            return false
        }
        refreshStatus()
    }

    fileprivate func deliver(_ contacts: [RawContact], layout: TouchLayout) {
        guard let f0 = layout.fingers.first, let xf = f0.x, let yf = f0.y else { return }
        let rect = CGDisplayBounds(targetDisplay)
        let map = settings.mapping
        if settings.mode == .midi && !dumpMode {
            let touches = contacts.map { c -> TouchPoint in
                let p = map.apply(TouchMapping.normalize(c.x, min: xf.logicalMin, max: xf.logicalMax),
                                  TouchMapping.normalize(c.y, min: yf.logicalMin, max: yf.logicalMax))
                return TouchPoint(id: c.id, x: Double(p.x), y: Double(p.y), pressure: c.pressure, size: c.size)
            }
            midiEngine?.update(touches)
            onMIDIUpdate?()
            return
        }
        let points = contacts.map {
            map.screenPoint(TouchMapping.normalize($0.x, min: xf.logicalMin, max: xf.logicalMax),
                            TouchMapping.normalize($0.y, min: yf.logicalMin, max: yf.logicalMax), in: rect)
        }
        // Nicht exklusiv: macOS bewegt den Zeiger zusätzlich selbst (relativ) – Position absolut auf den Touch-Bildschirm korrigieren
        if !dumpMode, suppressor.active, points.count == 1 { CGWarpMouseCursorPosition(points[0]) }
        if dumpMode {
            let s = zip(contacts, points).map { c, p in "#\(c.id) raw(\(c.x),\(c.y)) -> (\(Int(p.x)),\(Int(p.y)))" }
                .joined(separator: "  ")
            log(contacts.isEmpty ? "— keine Kontakte —" : "\(contacts.count) Finger: \(s)")
            return
        }
        engine.update(points)
    }

    fileprivate func releaseIfActive() {
        if engine.isActive { engine.update([]) }
        if let m = midiEngine, !m.fingerInfo.isEmpty { m.releaseAll(); onMIDIUpdate?() }
    }
}

// MARK: - Einzelnes HID-Gerät

final class TouchDevice {
    let device: IOHIDDevice
    let name: String
    unowned let service: TouchService
    let bufferSize: Int
    let buffer: UnsafeMutablePointer<UInt8>
    let descriptor: HIDDescriptor
    let hints: [String]
    let registryID: UInt64?
    let role: InterfaceRole
    /// Interface liefert Multitouch-Frames (sonst nur exklusiv halten, Reports verwerfen/protokollieren)
    var isTouch: Bool { !assembler.layouts.isEmpty }
    var label: String { "\(name) [\(role.rawValue)" + (registryID.map { String(format: " 0x%llX", $0) } ?? "") + "]" }
    var seizeMessage: String?
    var exclusive = false
    private var started = false
    private var assembler: TouchFrameAssembler
    private var lastReport = 0.0
    private(set) var hadContacts = false

    var lastSeizeRC: IOReturn = kIOReturnSuccess
    var lastOpenRC: IOReturn = kIOReturnSuccess

    init?(device: IOHIDDevice, service: TouchService, registryID: UInt64?, auxiliary: Bool, quiet: Bool = false) {
        let log: (String) -> Void = quiet ? { _ in } : service.log
        let nm = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Touch-Gerät"
        guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
            log("⚠️  \(nm): kein Report-Descriptor lesbar."); return nil
        }
        let desc = HIDDescriptor(bytes: [UInt8](data))
        let asm = TouchFrameAssembler(descriptor: desc)
        let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        log("🖐  Gerät: \(nm)  (VID " + String(format: "0x%04X", vid) + ", PID " + String(format: "0x%04X", pid) + ")")
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let pairs: [(Int, Int)] = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []).map {
            ($0[kIOHIDDeviceUsagePageKey] as? Int ?? 0, $0[kIOHIDDeviceUsageKey] as? Int ?? 0)
        } + [((IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0,
              (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0)]
        let role = InterfaceRole.classify(usagePairs: pairs, hasTouchLayout: !asm.layouts.isEmpty)
        log("   Schnittstelle: \(role.rawValue)  id " + (registryID.map { String(format: "0x%llX", $0) } ?? "?")
            + "  UsagePairs " + pairs.map { String(format: "0x%02X/0x%02X", $0.0, $0.1) }.joined(separator: ", "))
        if asm.layouts.isEmpty {
            guard auxiliary else {
                log("⚠️  Keine Multitouch-Finger im Descriptor gefunden. Descriptor (hex):")
                log(hex)
                return nil
            }
            log("   (keine Touch-Finger – wird nur exklusiv gehalten, damit macOS daraus keine Zeiger-Events macht)")
        }
        for (rid, l) in asm.layouts.sorted(by: { $0.key < $1.key }) {
            log("   Report \(rid): \(l.fingers.count) Finger-Slots, Contact Count: \(l.contactCount != nil ? "ja" : "nein")")
            if service.dumpMode {
                for (i, f) in l.fingers.enumerated() {
                    log("     Slot \(i): X[\(f.x?.describe ?? "-")] Y[\(f.y?.describe ?? "-")] Tip:\(f.tip != nil) ID:\(f.contactID != nil)")
                }
            }
        }
        if service.dumpMode { log("   Descriptor (hex): " + hex) }
        // Buffer >= MaxInputReportSize (Anmite Report 13: 1 + 10·5 + 2 + 1 = 54 Bytes), mindestens 256
        let maxSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 256
        log("   MaxInputReportSize \(maxSize) Bytes")
        self.device = device
        self.service = service
        self.name = nm
        self.descriptor = desc
        self.hints = [nm, (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String) ?? "",
                      vid == HIDProbe.anmiteVID ? "ANMITE" : ""].filter { !$0.isEmpty }
        self.assembler = asm
        self.registryID = registryID
        self.role = role
        self.bufferSize = max(maxSize, 256)
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(maxSize, 256))
    }

    deinit { buffer.deallocate() }

    /// Callbacks abmelden, vom Runloop nehmen, schließen – vor dem Freigeben aufrufen.
    private(set) var reports = 0
    private(set) var values = 0
    private func valueSeen() {
        values += 1
        if values == 50 && reports == 0 {
            service.log("⚠️  \(name): HID-Werte kommen an, aber keine ganzen Reports (\(values) Werte, 0 Reports).")
        }
    }

    func close() {
        guard started else { return }
        started = false
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, nil, nil)
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        HIDOpenRegistry.shared.close(device)
    }

    func start() {
        started = true
        // Gerät selbst auf dem Main-Runloop einplanen (unabhängig vom Manager)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { ctx, _, _, _, _, report, length in
            guard let ctx = ctx else { return }
            Unmanaged<TouchDevice>.fromOpaque(ctx).takeUnretainedValue()
                .handle(UnsafeBufferPointer(start: report, count: length))
        }, ctx)
        // Fallback-Zähler: kommen Werte, aber keine Reports, liegt es an der Report-Zustellung
        IOHIDDeviceRegisterInputValueCallback(device, { ctx, _, _, _ in
            guard let ctx = ctx else { return }
            Unmanaged<TouchDevice>.fromOpaque(ctx).takeUnretainedValue().valueSeen()
        }, ctx)
    }

    private func handle(_ r: UnsafeBufferPointer<UInt8>) {
        reports += 1
        guard isTouch else {
            if reports <= 3 || (service.dumpMode && reports <= 20) {
                service.log("ℹ️  \(label): Report #\(reports) (\(r.count) Bytes, verworfen): " + HIDFeature.hex(Array(r.prefix(16))))
            }
            return
        }
        service.countReport()
        service.touchReportSeen()
        if reports == 1 { service.log("✅ \(name): erster Touch-Report empfangen (\(r.count) Bytes).") }
        guard let result = assembler.feed(r) else { return }
        lastReport = CFAbsoluteTimeGetCurrent()
        hadContacts = !result.contacts.isEmpty
        service.deliver(result.contacts, layout: result.layout)
    }

    func checkStale(_ timeout: Double) {
        guard hadContacts, CFAbsoluteTimeGetCurrent() - lastReport > timeout else { return }
        assembler.reset()
        hadContacts = false
        service.releaseIfActive()
    }
}

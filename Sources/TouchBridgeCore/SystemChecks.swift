import Foundation

// MARK: - Plattformneutrale, getestete Logik für Berechtigungen, Gerätebelegung, Signatur und Systemzeiger-Filter

/// IOReturn-Codes, die TouchBridge unterscheidet (iokit_common_err – in Swift nicht als Makro verfügbar).
public enum HIDReturnCode {
    public static let success: UInt32 = 0
    public static let notPermitted: UInt32 = 0xE000_02E2
    public static let notPrivileged: UInt32 = 0xE000_02C1
    public static let exclusiveAccess: UInt32 = 0xE000_02C5

    public static func hex(_ rc: UInt32) -> String { String(format: "0x%08X", rc) }
    public static func hex(_ rc: Int32) -> String { hex(UInt32(bitPattern: rc)) }
    public static func isPermissionError(_ rc: UInt32) -> Bool { rc == notPermitted || rc == notPrivileged }
}

/// Andere laufende TouchBridge-Prozesse (aus `pgrep -il touchbridge`, Ausgabe „PID NAME“ je Zeile).
public struct OtherInstance: Equatable {
    public let pid: Int32
    public let name: String
    public init(pid: Int32, name: String) { self.pid = pid; self.name = name }
}

public enum InstanceScan {
    /// Zeilen „1234 TouchBridgeApp“ parsen; eigener Prozess und Nicht-TouchBridge-Treffer fallen weg.
    public static func parse(_ output: String, ownPID: Int32) -> [OtherInstance] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int32(parts[0]), pid != ownPID else { return nil }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            guard name.lowercased().contains("touchbridge") else { return nil }
            return OtherInstance(pid: pid, name: name)
        }
    }
}

/// Meldungen, wenn IOHIDDeviceOpen scheitert – „läuft doppelt“ nur, wenn es wirklich einen zweiten Prozess/LaunchAgent gibt.
public enum HIDOpenMessages {
    public static func seizeFailure(rc: UInt32, others: [OtherInstance], legacyAgent: Bool, holders: [String] = []) -> String {
        let code = " (\(HIDReturnCode.hex(rc)))"
        switch rc {
        case HIDReturnCode.exclusiveAccess:
            if !others.isEmpty {
                let list = others.map { "\($0.name) [\($0.pid)]" }.joined(separator: ", ")
                return "Gerät belegt (exklusiv) – TouchBridge läuft doppelt: \(list)" + code
            }
            if legacyAgent { return "Gerät belegt (exklusiv) – alter LaunchAgent com.groovex.touchbridge aktiv" + code }
            if let h = holders.first { return "Gerät exklusiv von macOS belegt (\(h))" + code }
            return "Gerät exklusiv von einem macOS-Treiber/-Dienst belegt" + code
        case HIDReturnCode.notPermitted, HIDReturnCode.notPrivileged:
            return "Keine Berechtigung für exklusiven Zugriff" + code
        default:
            return "Exklusiver Zugriff fehlgeschlagen" + code
        }
    }

    public static func openFailure(rc: UInt32, others: [OtherInstance], legacyAgent: Bool) -> String {
        switch rc {
        case HIDReturnCode.notPermitted, HIDReturnCode.notPrivileged:
            return "Keine Berechtigung (Eingabeüberwachung) – Gerät ließ sich nicht öffnen (\(HIDReturnCode.hex(rc)))"
        case HIDReturnCode.exclusiveAccess:
            return seizeFailure(rc: rc, others: others, legacyAgent: legacyAgent)
        default:
            return "Touch-Gerät ließ sich nicht öffnen (\(HIDReturnCode.hex(rc)))"
        }
    }
}

// MARK: - Berechtigungen: tatsächliche Wirkung statt nur IOHIDCheckAccess

public enum AccessCheck: String { case granted, denied, unknown }

public enum InputMonitoringState: Equatable {
    /// Reports kommen an – wirksam, egal was IOHIDCheckAccess meldet
    case working
    /// Laut System erteilt, noch keine Gegenprobe (kein Report / keine Berührung)
    case granted
    /// Noch nie gefragt
    case notDetermined
    /// Fehlt (nachdem wir schon einmal gefragt haben) – evtl. veralteter Eintrag
    case missing
    /// Laut System erteilt, aber das Öffnen scheitert mit „keine Berechtigung“ → Eintrag gehört zu einem alten Build
    case stale

    public var isProblem: Bool { self == .missing || self == .stale || self == .notDetermined }
    /// Hinweis „Eintrag veraltet …“ + Menüpunkt „Berechtigungen zurücksetzen …“ anbieten
    public var suggestReset: Bool { self == .missing || self == .stale }

    public var statusText: String {
        switch self {
        case .working: return "Eingabeüberwachung wirksam (Reports kommen an)"
        case .granted: return "Eingabeüberwachung erteilt"
        case .notDetermined: return "Eingabeüberwachung noch nicht erlaubt"
        case .missing: return "Keine Berechtigung (Eingabeüberwachung)"
        case .stale: return "Eingabeüberwachung erteilt, greift aber nicht"
        }
    }

    public static func evaluate(check: AccessCheck, openRCs: [UInt32], reports: Int, asked: Bool) -> InputMonitoringState {
        if reports > 0 { return .working }
        let refused = openRCs.contains(where: HIDReturnCode.isPermissionError)
        if refused { return check == .granted || asked ? .stale : .notDetermined }
        switch check {
        case .granted: return .granted
        case .unknown: return asked ? .missing : .notDetermined
        case .denied: return .missing
        }
    }
}

public enum PermissionTexts {
    public static let staleHint = "Eintrag veraltet – in Systemeinstellungen entfernen (–) und neu hinzufügen"
    /// Name der Privacy-Seite: ab macOS 27 „Gerätesteuerung und Datenzugriff“, vorher „Bedienungshilfen“
    public static let accessibilityName = "Gerätesteuerung und Datenzugriff (Bedienungshilfen)"
    public static let accessibilityPath = "Systemeinstellungen › Datenschutz & Sicherheit › Gerätesteuerung und Datenzugriff (älteres macOS: Bedienungshilfen)"
    public static func accessibility(trusted: Bool, asked: Bool) -> String? {
        if trusted { return nil }
        return asked ? "\(accessibilityName) fehlt – falls schon aktiviert: " + staleHint : "\(accessibilityName) noch nicht erlaubt"
    }
}

// MARK: - Code-Signatur (stabile Designated Requirement, Update-Prüfung)

public enum SigningPolicy {
    public static let appIdentifier = "com.groovex.touchbridge"
    public static let cliIdentifier = "com.groovex.touchbridge.cli"

    public static func normalize(_ sha1: String) -> String {
        sha1.uppercased().filter { $0.isHexDigit }
    }

    public static func designatedRequirement(identifier: String, leafSHA1: String) -> String {
        "designated => identifier \"\(identifier)\" and certificate leaf = H\"\(normalize(leafSHA1).lowercased())\""
    }

    /// Leaf-Hash aus der Ausgabe von `codesign -dr-` („… certificate leaf = H"abcd…"“), sonst nil (z. B. ad-hoc/cdhash).
    public static func leafHash(fromRequirement text: String) -> String? {
        guard let r = text.range(of: "certificate leaf = H\"") else { return nil }
        let rest = text[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let h = normalize(String(rest[..<end]))
        return h.count == 40 ? h : nil
    }

    public enum UpdateDecision: Equatable {
        case allowed(String)
        case rejected(String)
        public var isAllowed: Bool { if case .allowed = self { return true } else { return false } }
    }

    /// Neues Bundle muss mit demselben Leaf-Zertifikat signiert sein wie die laufende App – sofern diese schon so signiert ist.
    public static func checkUpdate(currentLeaf: String?, newLeaf: String?) -> UpdateDecision {
        guard let cur = currentLeaf.map(normalize), !cur.isEmpty else {
            return .allowed("laufende App ist ad-hoc signiert – kein Zertifikatsvergleich möglich")
        }
        guard let new = newLeaf.map(normalize), !new.isEmpty else {
            return .rejected("neues Bundle ist nicht mit dem TouchBridge-Zertifikat signiert (ad-hoc)")
        }
        return cur == new ? .allowed("gleiches Zertifikat (SHA-1 \(new))")
                          : .rejected("anderes Zertifikat (erwartet \(cur), erhalten \(new))")
    }
}

// MARK: - Wer hält das HID-Gerät? (Auswertung von `ioreg -a -r -c IOHIDDevice -l`)

public struct HIDHolderReport: Equatable {
    public struct Interface: Equatable {
        public var name: String
        public var objectClass: String
        public var registryID: UInt64?
        public var usagePairs: [String]
        public var builtIn: Bool?
        public var transport: String?
        /// Prozess-Clients: „pid 123, hidd“ + Klasse
        public var userClients: [String]
        /// Kernel-/DriverKit-Treiber unterhalb (Klassen), z. B. IOHIDInterface, IOHIDEventDriver, AppleHIDTouch…
        public var drivers: [String]
        /// alle Registry-IDs dieses Interfaces und seiner Nachfahren (für den Abgleich mit dem Event-Absender)
        public var descendantIDs: [UInt64]
    }
    public var interfaces: [Interface] = []
    public init() {}

    /// Kurzfassung der vermutlichen Halter: fremde Prozess-Clients (ohne eigenen PID) und Event-Treiber.
    public func likelyHolders(ownPID: Int32) -> [String] {
        var out: [String] = []
        for i in interfaces {
            for c in i.userClients where !c.hasPrefix("pid \(ownPID),") && !out.contains(c) { out.append(c) }
            for d in i.drivers where HIDHolderReport.isEventDriver(d) && !out.contains(d) { out.append(d) }
        }
        return out
    }

    public static func isEventDriver(_ cls: String) -> Bool {
        let c = cls.lowercased()
        return c.contains("eventdriver") || c.contains("touch") || c.contains("digitizer") || c.contains("multitouch")
    }

    public func lines(ownPID: Int32) -> [String] {
        if interfaces.isEmpty { return ["ioreg: kein IOHIDDevice mit dieser VID/PID gefunden"] }
        var l: [String] = []
        for (n, i) in interfaces.enumerated() {
            l.append("[ioreg \(n)] \(i.name) <\(i.objectClass)> id=\(i.registryID.map { String(format: "0x%llX", $0) } ?? "?")"
                     + " Transport \(i.transport ?? "?")" + " Built-In \(i.builtIn.map { $0 ? "ja" : "nein" } ?? "?")")
            l.append("   DeviceUsagePairs [\(i.usagePairs.joined(separator: ", "))]")
            l.append("   Treiber: " + (i.drivers.isEmpty ? "–" : i.drivers.joined(separator: ", ")))
            l.append("   Clients: " + (i.userClients.isEmpty ? "–" : i.userClients.map {
                $0.hasPrefix("pid \(ownPID),") ? $0 + " (TouchBridge selbst)" : $0 }.joined(separator: "; ")))
            let own = i.userClients.filter { $0.hasPrefix("pid \(ownPID),") }.count
            if own > 1 { l.append("   ❌ FEHLER: TouchBridge hält \(own) Clients auf diesem Interface (doppelt geöffnet)") }
        }
        return l
    }

    public static func analyze(plist data: Data, vid: Int, pid: Int) -> HIDHolderReport {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return HIDHolderReport() }
        var tops: [[String: Any]] = []
        if let a = root as? [[String: Any]] { tops = a } else if let d = root as? [String: Any] { tops = [d] }
        var report = HIDHolderReport()
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? Int) }
        func children(_ d: [String: Any]) -> [[String: Any]] { d["IORegistryEntryChildren"] as? [[String: Any]] ?? [] }
        func findDevices(_ d: [String: Any]) {
            if int(d["VendorID"]) == vid, int(d["ProductID"]) == pid, d["ReportDescriptor"] != nil || d["PrimaryUsagePage"] != nil {
                report.interfaces.append(interface(d)); return
            }
            for c in children(d) { findDevices(c) }
        }
        func interface(_ d: [String: Any]) -> Interface {
            var i = Interface(name: d["Product"] as? String ?? d["IORegistryEntryName"] as? String ?? "?",
                              objectClass: d["IOObjectClass"] as? String ?? "?",
                              registryID: (d["IORegistryEntryID"] as? NSNumber)?.uint64Value,
                              usagePairs: (d["DeviceUsagePairs"] as? [[String: Any]] ?? []).map {
                                  String(format: "0x%02X/0x%02X", int($0["DeviceUsagePage"]) ?? 0, int($0["DeviceUsage"]) ?? 0) },
                              builtIn: (d["Built-In"] as? NSNumber)?.boolValue,
                              transport: d["Transport"] as? String,
                              userClients: [], drivers: [], descendantIDs: [])
            if let id = i.registryID { i.descendantIDs.append(id) }
            func walk(_ n: [String: Any]) {
                let cls = n["IOObjectClass"] as? String ?? "?"
                if let id = (n["IORegistryEntryID"] as? NSNumber)?.uint64Value { i.descendantIDs.append(id) }
                if let creator = n["IOUserClientCreator"] as? String {
                    i.userClients.append("\(creator) <\(cls)>")
                } else if !i.drivers.contains(cls) {
                    i.drivers.append(cls)
                }
                for c in children(n) { walk(c) }
            }
            for c in children(d) { walk(c) }
            return i
        }
        for t in tops { findDevices(t) }
        return report
    }
}

// MARK: - Systemzeiger unterdrücken, wenn das Gerät nicht exklusiv ist

/// Entscheidet im Event-Tap, ob ein Maus-/Scroll-Event vom macOS-eigenen Treiber des Touch-Monitors stammt.
/// Eigene Events tragen `marker` in kCGEventSourceUserData und gehen immer durch.
public struct SystemPointerFilter {
    public static let marker: Int64 = 0x54_42_52_47   // "TBRG"
    /// Zeitfenster nach dem letzten Touch-Report, in dem Hardware-Events dem Touch zugerechnet werden
    public var window: Double = 0.12
    public init() {}

    public struct EventInfo {
        public var userData: Int64
        public var sourcePID: Int64
        /// Registry-ID des absendenden IOHIDService (IOHIDEventGetSenderID), wenn ermittelbar
        public var senderID: UInt64?
        public var time: Double
        public init(userData: Int64, sourcePID: Int64, senderID: UInt64?, time: Double) {
            self.userData = userData; self.sourcePID = sourcePID; self.senderID = senderID; self.time = time
        }
    }

    public enum Verdict: Equatable { case pass, dropSender, dropCorrelated }

    /// deviceIDs: Registry-IDs des Touch-Geräts und seiner Nachfahren; lastReport: Zeit des letzten Touch-Reports
    public func verdict(_ e: EventInfo, deviceIDs: Set<UInt64>, lastReport: Double?, touching: Bool) -> Verdict {
        if e.userData == SystemPointerFilter.marker { return .pass }          // eigenes Event
        if e.sourcePID != 0 { return .pass }                                   // synthetisch von einer anderen App
        if let s = e.senderID, s != 0, !deviceIDs.isEmpty {
            return deviceIDs.contains(s) ? .dropSender : .pass                 // eindeutig zuordenbar
        }
        // Ohne Absender-ID: Hardware-Event während/kurz nach Touch-Reports diesem Gerät zurechnen
        guard let t = lastReport else { return .pass }
        let dt = e.time - t
        if touching || (dt >= -0.02 && dt <= window) { return .dropCorrelated }
        return .pass
    }
}

// MARK: - Mehrere HID-Schnittstellen eines Geräts: jede genau einmal öffnen

/// Rolle einer HID-Schnittstelle des Touch-Monitors (für Menü und Diagnose).
public enum InterfaceRole: String, Equatable {
    case touch = "Touch", mouse = "Maus", keyboard = "Tastatur", vendor = "Vendor", other = "HID"

    /// usagePairs: (UsagePage, Usage) aus DeviceUsagePairs bzw. PrimaryUsagePage/Usage
    public static func classify(usagePairs: [(Int, Int)], hasTouchLayout: Bool) -> InterfaceRole {
        if hasTouchLayout { return .touch }
        if usagePairs.contains(where: { $0.0 == 0x0D }) { return .touch }
        if usagePairs.contains(where: { $0.0 == 0x01 && ($0.1 == 0x02 || $0.1 == 0x01) }) { return .mouse }
        if usagePairs.contains(where: { $0.0 == 0x01 && ($0.1 == 0x06 || $0.1 == 0x07) }) { return .keyboard }
        if usagePairs.contains(where: { $0.0 >= 0xFF00 }) { return .vendor }
        return .other
    }
}

public struct InterfaceStatus: Equatable {
    public var registryID: UInt64
    public var role: InterfaceRole
    public var exclusive: Bool
    public init(registryID: UInt64, role: InterfaceRole, exclusive: Bool) {
        self.registryID = registryID; self.role = role; self.exclusive = exclusive
    }

    /// „3 Schnittstellen: Touch exklusiv, Maus exklusiv, Vendor NICHT exklusiv“
    public static func summary(_ list: [InterfaceStatus]) -> String {
        guard !list.isEmpty else { return "keine Schnittstelle offen" }
        let sorted = list.sorted { ($0.role == .touch ? 0 : 1, $0.registryID) < ($1.role == .touch ? 0 : 1, $1.registryID) }
        let parts = sorted.map { "\($0.role.rawValue) " + ($0.exclusive ? "exklusiv" : "NICHT exklusiv") }
        return "\(list.count) Schnittstelle\(list.count == 1 ? "" : "n"): " + parts.joined(separator: ", ")
    }

    /// „Touch: 0 Reports, Maus: 120 Reports“ – welche Schnittstelle tatsächlich Daten liefert
    public static func reportSummary(_ list: [(role: InterfaceRole, reports: Int)]) -> String {
        guard !list.isEmpty else { return "keine Schnittstelle offen" }
        let order: [InterfaceRole] = [.touch, .mouse, .keyboard, .vendor, .other]
        var sums: [InterfaceRole: Int] = [:]
        for e in list { sums[e.role, default: 0] += e.reports }
        return order.compactMap { r in sums[r].map { "\(r.rawValue): \($0) Report\($0 == 1 ? "" : "s")" } }.joined(separator: ", ")
    }
}

/// Woher die Touch-Daten kommen
public enum TouchSource: Equatable {
    case none, multitouch, singleTouchPointer
    public var title: String {
        switch self {
        case .none: return "noch keine Touch-Daten"
        case .multitouch: return "Multitouch"
        case .singleTouchPointer: return "Single-Touch (Gerät im Mausmodus)"
        }
    }

    /// Multitouch, sobald der Digitizer Reports liefert; sonst Single-Touch, wenn eine Absolutmaus-Schnittstelle da ist.
    public static func evaluate(multitouchReports: Int, pointerInterfaces: Int, multitouchInterfaces: Int) -> TouchSource {
        if multitouchReports > 0 { return .multitouch }
        if pointerInterfaces > 0 { return .singleTouchPointer }
        return multitouchInterfaces > 0 ? .multitouch : .none
    }
}
}

/// Open-Zustand je IORegistryEntryID im ganzen Prozess. Verhindert doppelte IOHIDDeviceOpen-Aufrufe
/// (zwei eigene Clients auf demselben Interface lassen jeden späteren Seize mit kIOReturnExclusiveAccess scheitern).
public struct HIDOpenTracker: Equatable {
    public enum State: Equatable { case shared, exclusive }
    public private(set) var open: [UInt64: State] = [:]
    public init() {}

    public func isOpen(_ id: UInt64) -> Bool { open[id] != nil }
    public func isExclusive(_ id: UInt64) -> Bool { open[id] == .exclusive }

    /// Vor einem Öffnen: muss das Interface erst geschlossen werden? (Retry/Seize auf bereits offenes Gerät)
    public func mustCloseBeforeOpen(_ id: UInt64) -> Bool { isOpen(id) }

    public mutating func opened(_ id: UInt64, exclusive: Bool) { open[id] = exclusive ? .exclusive : .shared }
    public mutating func closed(_ id: UInt64) { open[id] = nil }

    /// Neue Geräte aus Matching-Callback/CopyDevices: nur bisher unbekannte Registry-IDs, jede höchstens einmal.
    public static func dedupe(_ ids: [UInt64], known: Set<UInt64>) -> [UInt64] {
        var seen = known
        var out: [UInt64] = []
        for id in ids where !seen.contains(id) { seen.insert(id); out.append(id) }
        return out
    }
}

public extension HIDHolderReport {
    /// Interfaces, an denen der eigene Prozess mehr als einen Client hält (Fehler: doppelt geöffnet)
    func duplicateOwnClients(ownPID: Int32) -> [Interface] {
        interfaces.filter { i in i.userClients.filter { $0.hasPrefix("pid \(ownPID),") }.count > 1 }
    }
}

import CryptoKit
import Foundation
import IOKit
import IOKit.hid
import Security
import TouchBridgeCore

/// Systemprüfungen: andere TouchBridge-Prozesse, alter LaunchAgent, Code-Signatur, TCC-Reset, HID-Halter (ioreg).
public enum SystemCheck {
    public static let legacyAgentLabel = "com.groovex.touchbridge"
    public static var legacyAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(legacyAgentLabel).plist")
    }

    @discardableResult
    public static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Andere TouchBridge-Prozesse (Name, Groß-/Kleinschreibung egal: TouchBridgeApp, touchbridge-CLI)
    public static func otherInstances() -> [OtherInstance] {
        InstanceScan.parse(run("/usr/bin/pgrep", ["-il", "touchbridge"]).output, ownPID: getpid())
    }

    /// Alter LaunchAgent aus v0.1 (install.sh): Datei vorhanden bzw. in launchd geladen
    public static var legacyAgentFilePresent: Bool { FileManager.default.fileExists(atPath: legacyAgentURL.path) }
    public static var legacyAgentLoaded: Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(legacyAgentLabel)"]).status == 0
    }
    public static var legacyAgentPresent: Bool { legacyAgentFilePresent || legacyAgentLoaded }

    /// launchctl bootout + Datei löschen. Liefert ein Protokoll.
    public static func removeLegacyAgent() -> [String] {
        var log: [String] = []
        let b = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(legacyAgentLabel)"])
        log.append("launchctl bootout gui/\(getuid())/\(legacyAgentLabel): \(b.status == 0 ? "ok" : "Status \(b.status) \(b.output.trimmingCharacters(in: .whitespacesAndNewlines))")")
        if legacyAgentFilePresent {
            do { try FileManager.default.removeItem(at: legacyAgentURL); log.append("gelöscht: \(legacyAgentURL.path)") }
            catch { log.append("Löschen fehlgeschlagen: \(error.localizedDescription)") }
        }
        return log
    }

    /// tccutil reset ListenEvent/Accessibility für die App-Bundle-ID
    public static func resetPermissions(bundleID: String = SigningPolicy.appIdentifier) -> [String] {
        ["ListenEvent", "Accessibility"].map { service in
            let r = run("/usr/bin/tccutil", ["reset", service, bundleID])
            return "tccutil reset \(service) \(bundleID): " + (r.status == 0 ? "ok" : "Status \(r.status) " + r.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Code-Signatur

    /// SHA-1 des Leaf-Zertifikats der Signatur (nil bei ad-hoc oder unsigniert)
    public static func leafSHA1(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let c = code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(c, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any],
              let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// `codesign -dr-` und die wichtigsten Zeilen von `codesign -dv` für ein Bundle/Programm
    public static func signingLines(of url: URL) -> [String] {
        var l: [String] = ["Code-Signatur: \(url.path)"]
        let dr = run("/usr/bin/codesign", ["-d", "-r-", url.path]).output
        for line in dr.split(whereSeparator: \.isNewline) where !line.hasPrefix("Executable=") { l.append("   " + line) }
        let dv = run("/usr/bin/codesign", ["-dv", "--verbose=2", url.path]).output
        for line in dv.split(whereSeparator: \.isNewline)
        where ["Identifier=", "Authority=", "Signature=", "CDHash=", "TeamIdentifier=", "Format="].contains(where: { line.hasPrefix($0) }) {
            l.append("   " + line)
        }
        l.append("   Leaf-Zertifikat SHA-1: " + (leafSHA1(of: url) ?? "– (ad-hoc/unsigniert: TCC-Rechte gelten nur für genau diesen Build)"))
        return l
    }

    // MARK: HID-Halter

    /// Wer hält die HID-Schnittstellen des Geräts? (`ioreg -a -r -c IOHIDDevice -l`)
    public static func holderReport(vid: Int, pid: Int) -> HIDHolderReport {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-a", "-r", "-c", "IOHIDDevice", "-l"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return HIDHolderReport() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return HIDHolderReport.analyze(plist: data, vid: vid, pid: pid)
    }

    /// Zusammenfassung für die Diagnose (CLI und App)
    public static func diagnosisLines(vid: Int, pid: Int, bundle: URL = Bundle.main.bundleURL) -> [String] {
        var l: [String] = ["— System —"]
        l.append("IOHIDCheckAccess(ListenEvent): \(Permissions.accessCheck.rawValue)  (gefragt: \(Permissions.askedInputMonitoring ? "ja" : "nein"))")
        l.append("AXIsProcessTrusted: \(Permissions.accessibility)  (gefragt: \(Permissions.askedAccessibility ? "ja" : "nein"))")
        l.append(contentsOf: signingLines(of: bundle))
        let others = otherInstances()
        l.append("Andere TouchBridge-Prozesse: " + (others.isEmpty ? "keine" : others.map { "\($0.name) [\($0.pid)]" }.joined(separator: ", ")))
        l.append("Alter LaunchAgent \(legacyAgentLabel): " + (legacyAgentFilePresent ? "Datei vorhanden" : "keine Datei")
                 + (legacyAgentLoaded ? ", geladen" : ", nicht geladen"))
        l.append("— ioreg: Halter der HID-Schnittstellen (VID \(String(format: "0x%04X", vid)) PID \(String(format: "0x%04X", pid))) —")
        let r = holderReport(vid: vid, pid: pid)
        l.append(contentsOf: r.lines(ownPID: getpid()))
        let holders = r.likelyHolders(ownPID: getpid())
        if !holders.isEmpty { l.append("Mögliche fremde Halter: " + holders.joined(separator: "; ")) }
        return l
    }
}

// MARK: - Ein IOHIDDevice-Objekt und ein Open-Zustand je Registry-ID (prozessweit)

public final class HIDOpenRegistry {
    public static let shared = HIDOpenRegistry()
    private var objects: [UInt64: IOHIDDevice] = [:]
    public private(set) var tracker = HIDOpenTracker()
    public var log: ((String) -> Void)?

    public static func registryID(_ d: IOHIDDevice) -> UInt64? {
        let s = IOHIDDeviceGetService(d)
        guard s != 0 else { return nil }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(s, &id) == KERN_SUCCESS ? id : nil
    }

    /// Registry-IDs des Interfaces und aller Nachfahren (IOHIDInterface, Event-Treiber, Event-Services …)
    public static func descendantIDs(_ d: IOHIDDevice) -> [UInt64] {
        let s = IOHIDDeviceGetService(d)
        guard s != 0 else { return [] }
        var out: [UInt64] = []
        var id: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(s, &id) == KERN_SUCCESS { out.append(id) }
        var it: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(s, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }
        while case let e = IOIteratorNext(it), e != 0 {
            if IORegistryEntryGetRegistryEntryID(e, &id) == KERN_SUCCESS { out.append(id) }
            IOObjectRelease(e)
        }
        return out
    }

    /// Immer dasselbe IOHIDDevice-Objekt pro Interface verwenden (ein Objekt = ein IOHIDLibUserClient)
    public func canonical(_ d: IOHIDDevice) -> (device: IOHIDDevice, id: UInt64?) {
        guard let id = HIDOpenRegistry.registryID(d) else { return (d, nil) }
        if let known = objects[id] { return (known, id) }
        objects[id] = d
        return (d, id)
    }

    public func isOpen(_ d: IOHIDDevice) -> Bool { HIDOpenRegistry.registryID(d).map(tracker.isOpen) ?? false }

    /// Öffnet genau einmal: ist das Interface schon offen, wird es vorher geschlossen.
    public func open(_ d: IOHIDDevice, seize: Bool) -> IOReturn {
        let id = HIDOpenRegistry.registryID(d)
        if let id = id, tracker.mustCloseBeforeOpen(id) {
            IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
            tracker.closed(id)
        }
        let rc = IOHIDDeviceOpen(d, IOOptionBits(seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
        if rc == kIOReturnSuccess, let id = id { tracker.opened(id, exclusive: seize) }
        return rc
    }

    public func close(_ d: IOHIDDevice) {
        guard let id = HIDOpenRegistry.registryID(d) else { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)); return }
        guard tracker.isOpen(id) else { return }
        IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
        tracker.closed(id)
    }

    /// Existiert der Registry-Eintrag noch? (nach Abstecken/Neu-Enumeration/Ruhezustand nicht mehr)
    public static func isLive(_ id: UInt64) -> Bool {
        guard let m = IORegistryEntryIDMatching(id) else { return false }
        let s = IOServiceGetMatchingService(0, m)
        guard s != 0 else { return false }
        IOObjectRelease(s)
        return true
    }

    /// Objekte zu nicht mehr existierenden Registry-IDs verwerfen; liefert die verworfenen IDs
    @discardableResult
    public func pruneDead() -> [UInt64] {
        let dead = objects.keys.filter { !HIDOpenRegistry.isLive($0) }
        for id in dead {
            objects[id] = nil
            if tracker.isOpen(id) { tracker.closed(id) }
        }
        return dead
    }

    /// Gerät abgesteckt: Objekt vergessen
    public func forget(_ d: IOHIDDevice) {
        guard let id = HIDOpenRegistry.registryID(d) else { return }
        if tracker.isOpen(id) { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)); tracker.closed(id) }
        objects[id] = nil
    }
}

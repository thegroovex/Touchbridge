import CryptoKit
import Foundation
import TouchBridgeCore

/// In-App-Update über GitHub-Releases: prüfen, DMG + SHA256SUMS laden, Prüfsumme/Bundle/Signatur prüfen,
/// App ersetzen und neu starten.
public final class Updater {
    public static let releasesURL = URL(string: "https://api.github.com/repos/thegroovex/Touchbridge/releases?per_page=30")!
    public static let bundleID = "com.groovex.touchbridge"

    public enum UpdateError: LocalizedError {
        case network(String), noAsset, noChecksum, checksumMismatch(String, String), mount(String),
             noApp, wrongBundle(String), wrongVersion(String), signature(String), install(String)
        public var errorDescription: String? {
            switch self {
            case .network(let m): return "Download fehlgeschlagen: \(m)"
            case .noAsset: return "Im Release fehlt das DMG."
            case .noChecksum: return "Im Release fehlt SHA256SUMS.txt bzw. der Eintrag für das DMG."
            case let .checksumMismatch(a, b): return "Prüfsumme stimmt nicht (erwartet \(a), erhalten \(b))."
            case .mount(let m): return "DMG ließ sich nicht öffnen: \(m)"
            case .noApp: return "Im DMG wurde keine TouchBridge.app gefunden."
            case .wrongBundle(let b): return "Falsche App im DMG (Bundle-ID \(b))."
            case .wrongVersion(let v): return "Version im DMG passt nicht (\(v))."
            case .signature(let m): return "Code-Signatur ungültig: \(m)"
            case .install(let m): return "Installation fehlgeschlagen: \(m)"
            }
        }
    }

    /// Aktuelle Version: vollständige Version (TouchBridgeVersion, inkl. -preview…) oder CFBundleShortVersionString.
    public static var currentVersion: String {
        let b = Bundle.main
        return (b.object(forInfoDictionaryKey: "TouchBridgeVersion") as? String)
            ?? (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    public let log: (String) -> Void
    public init(log: @escaping (String) -> Void = { print($0) }) { self.log = log }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        r.setValue("TouchBridge/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return r
    }

    /// Releases abrufen und das passende Update wählen. completion auf dem Main-Thread.
    public func check(includePrereleases: Bool, skipped: String?, current: String = Updater.currentVersion,
                      completion: @escaping (Result<ReleaseInfo?, Error>) -> Void) {
        URLSession.shared.dataTask(with: request(Updater.releasesURL)) { data, resp, err in
            let result: Result<ReleaseInfo?, Error>
            if let e = err {
                result = .failure(UpdateError.network(e.localizedDescription))
            } else if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                result = .failure(UpdateError.network("GitHub antwortet mit HTTP \(h.statusCode)"))
            } else {
                do {
                    let list = try UpdateLogic.decodeReleases(data ?? Data())
                    result = .success(UpdateLogic.pickUpdate(list, current: current, includePrereleases: includePrereleases,
                                                             skipped: skipped))
                } catch { result = .failure(UpdateError.network("Antwort unlesbar: \(error.localizedDescription)")) }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func download(_ url: URL, to dest: URL) throws {
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        URLSession.shared.downloadTask(with: request(url)) { tmp, resp, err in
            defer { sem.signal() }
            if let e = err { failure = UpdateError.network(e.localizedDescription); return }
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { failure = UpdateError.network("HTTP \(h.statusCode) für \(url.lastPathComponent)"); return }
            guard let tmp = tmp else { failure = UpdateError.network("keine Datei"); return }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
            } catch { failure = UpdateError.network(error.localizedDescription) }
        }.resume()
        sem.wait()
        if let f = failure { throw f }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
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

    public static func sha256(of url: URL) throws -> String {
        let h = FileHandle(forReadingAtPath: url.path)
        guard let fh = h else { throw UpdateError.network("Datei nicht lesbar") }
        defer { fh.closeFile() }
        var hasher = SHA256()
        while true {
            let chunk = fh.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return UpdateLogic.hex(Array(hasher.finalize()))
    }

    /// Lädt, prüft und bereitet die neue App vor (Hintergrund-Thread!). Liefert den Pfad der geprüften App im Temp-Ordner.
    public func prepare(_ release: ReleaseInfo) throws -> URL {
        guard let dmgAsset = UpdateLogic.dmgAsset(release), let dmgURL = URL(string: dmgAsset.browserDownloadURL) else { throw UpdateError.noAsset }
        guard let sumsAsset = UpdateLogic.sumsAsset(release), let sumsURL = URL(string: sumsAsset.browserDownloadURL) else { throw UpdateError.noChecksum }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("TouchBridge-Update-\(release.versionString)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent(dmgAsset.name), sums = work.appendingPathComponent("SHA256SUMS.txt")
        log("⬇️  Lade \(dmgAsset.name) …")
        try download(sumsURL, to: sums)
        try download(dmgURL, to: dmg)
        let table = UpdateLogic.parseSHA256Sums((try? String(contentsOf: sums, encoding: .utf8)) ?? "")
        guard let expected = table[dmgAsset.name] else { throw UpdateError.noChecksum }
        let actual = try Updater.sha256(of: dmg)
        guard actual == expected else { throw UpdateError.checksumMismatch(expected, actual) }
        log("✅ SHA256 ok (\(actual.prefix(16))…)")

        let mount = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let att = Updater.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        guard att.status == 0 else { throw UpdateError.mount(att.output) }
        defer { Updater.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let srcApp = mount.appendingPathComponent("TouchBridge.app")
        guard FileManager.default.fileExists(atPath: srcApp.path) else { throw UpdateError.noApp }
        let newApp = work.appendingPathComponent("TouchBridge.app")
        let cp = Updater.run("/usr/bin/ditto", [srcApp.path, newApp.path])
        guard cp.status == 0 else { throw UpdateError.install("Kopieren: " + cp.output) }

        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else { throw UpdateError.noApp }
        let bid = info["CFBundleIdentifier"] as? String ?? "?"
        guard bid == Updater.bundleID else { throw UpdateError.wrongBundle(bid) }
        let ver = (info["TouchBridgeVersion"] as? String) ?? (info["CFBundleShortVersionString"] as? String) ?? "?"
        if let a = SemVer(ver), let b = release.version {
            // ältere DMGs tragen nur die numerische Version (ohne -preview) – Kern muss passen
            guard a == b || (a.major, a.minor, a.patch) == (b.major, b.minor, b.patch) else { throw UpdateError.wrongVersion(ver) }
        } else { throw UpdateError.wrongVersion(ver) }
        let sig = Updater.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        guard sig.status == 0 else { throw UpdateError.signature(sig.output) }
        // Gatekeeper: heruntergeladene App ist ad-hoc signiert – Quarantäne entfernen (vom User ausdrücklich gewünscht)
        Updater.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        log("✅ TouchBridge \(ver) geprüft (Bundle-ID, Version, Signatur).")
        return newApp
    }

    /// Ersetzt die laufende App (target) durch newApp. Bei fehlenden Schreibrechten per Administrator-Dialog.
    public func install(newApp: URL, over target: URL) throws {
        let fm = FileManager.default
        do {
            _ = try fm.replaceItemAt(target, withItemAt: newApp, backupItemName: "TouchBridge-alt.app", options: [])
            log("✅ App ersetzt: \(target.path)")
            return
        } catch {
            log("ℹ️  Direktes Ersetzen nicht möglich (\(error.localizedDescription)) – frage nach Administrator-Rechten.")
        }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "rm -rf \(q(target.path)) && /usr/bin/ditto \(q(newApp.path)) \(q(target.path)) && /usr/bin/xattr -dr com.apple.quarantine \(q(target.path))"
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        var ok = false
        let run = { ok = NSAppleScript(source: script)?.executeAndReturnError(&err) != nil }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        guard ok else { throw UpdateError.install((err?[NSAppleScript.errorMessage] as? String) ?? "abgebrochen") }
        log("✅ App mit Administrator-Rechten ersetzt: \(target.path)")
    }

    /// Kleines Shell-Skript: wartet, bis dieser Prozess beendet ist, und startet die neue App.
    public static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let sh = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open -n '\(app.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", sh]
        try? p.run()
    }
}

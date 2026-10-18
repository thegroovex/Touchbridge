import Foundation

// MARK: - Update-Logik (plattformneutral, getestet): Versionen, Release-Auswahl, Assets, SHA256SUMS

/// Semantische Version (SemVer 2.0): 1.2.3, 1.2.3-preview.1, v0.2.0 …; Build-Metadaten (+…) werden ignoriert.
public struct SemVer: Comparable, CustomStringConvertible, Equatable {
    public let major: Int, minor: Int, patch: Int
    public let prerelease: [String]

    public init?(_ s: String) {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let plus = t.firstIndex(of: "+") { t = String(t[..<plus]) }
        var pre: [String] = []
        if let dash = t.firstIndex(of: "-") {
            pre = t[t.index(after: dash)...].split(separator: ".").map(String.init)
            t = String(t[..<dash])
            if pre.isEmpty || pre.contains(where: { $0.isEmpty }) { return nil }
        }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        major = parts[0]!
        minor = parts.count > 1 ? parts[1]! : 0
        patch = parts.count > 2 ? parts[2]! : 0
        prerelease = pre
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }
    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // Version ohne Pre-Release ist höher als mit
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true          // numerisch < alphanumerisch
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

public struct ReleaseAsset: Codable, Equatable {
    public let name: String
    public let browserDownloadURL: String
    public let size: Int?
    enum CodingKeys: String, CodingKey { case name, size, browserDownloadURL = "browser_download_url" }
    public init(name: String, url: String, size: Int? = nil) { self.name = name; browserDownloadURL = url; self.size = size }
}

/// Ein Eintrag aus https://api.github.com/repos/<owner>/<repo>/releases
public struct ReleaseInfo: Codable, Equatable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let prerelease: Bool
    public let draft: Bool
    public let htmlURL: String?
    public let assets: [ReleaseAsset]
    enum CodingKeys: String, CodingKey {
        case name, body, prerelease, draft, assets
        case tagName = "tag_name", htmlURL = "html_url"
    }
    public init(tagName: String, name: String? = nil, body: String? = nil, prerelease: Bool = false, draft: Bool = false,
                htmlURL: String? = nil, assets: [ReleaseAsset] = []) {
        self.tagName = tagName; self.name = name; self.body = body; self.prerelease = prerelease
        self.draft = draft; self.htmlURL = htmlURL; self.assets = assets
    }

    public var version: SemVer? { SemVer(tagName) }
    /// Version wie im DMG-Namen (Tag ohne führendes v)
    public var versionString: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
}

public enum UpdateLogic {
    public static func decodeReleases(_ data: Data) throws -> [ReleaseInfo] {
        try JSONDecoder().decode([ReleaseInfo].self, from: data)
    }

    /// Höchste Version > current (keine Entwürfe; Vorabversionen nur wenn erlaubt; übersprungene Version nicht).
    /// Nur Releases mit DMG-Asset kommen in Frage. Unlesbare aktuelle Version (z. B. „dev“) gilt als 0.0.0.
    public static func pickUpdate(_ releases: [ReleaseInfo], current: String, includePrereleases: Bool,
                                  skipped: String? = nil) -> ReleaseInfo? {
        let cur = SemVer(current) ?? SemVer("0.0.0")!
        let skip = skipped.flatMap { SemVer($0) }
        return releases
            .filter { !$0.draft && (includePrereleases || (!$0.prerelease && !($0.version?.isPrerelease ?? true))) }
            .filter { r in r.version.map { $0 > cur && $0 != skip } ?? false }
            .filter { dmgAsset($0) != nil }
            .max { $0.version! < $1.version! }
    }

    /// TouchBridge-<version>.dmg, sonst das einzige TouchBridge-*.dmg
    public static func dmgAsset(_ r: ReleaseInfo) -> ReleaseAsset? {
        if let a = r.assets.first(where: { $0.name == "TouchBridge-\(r.versionString).dmg" }) { return a }
        let dmgs = r.assets.filter { $0.name.hasPrefix("TouchBridge") && $0.name.lowercased().hasSuffix(".dmg") }
        return dmgs.count == 1 ? dmgs[0] : nil
    }

    public static func sumsAsset(_ r: ReleaseInfo) -> ReleaseAsset? {
        r.assets.first { $0.name == "SHA256SUMS.txt" } ?? r.assets.first { $0.name.uppercased().hasPrefix("SHA256SUMS") }
    }

    /// shasum-Format: "<64 hex>  <datei>" bzw. "<hex> *<datei>" (binär). Ergebnis: Dateiname -> Hash (klein).
    public static func parseSHA256Sums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            var file = parts[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            if let slash = file.lastIndex(of: "/") { file = String(file[file.index(after: slash)...]) }
            out[file] = hash
        }
        return out
    }

    public static func hex(_ digest: [UInt8]) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Prüfintervall: fällig, wenn noch nie geprüft oder länger als `interval` her.
    public static func isCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval = 24 * 3600) -> Bool {
        guard let l = lastCheck else { return true }
        return now.timeIntervalSince(l) >= interval || now < l
    }
}

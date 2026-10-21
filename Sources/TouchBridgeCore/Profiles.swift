import Foundation

// MARK: - Settings a profile can override

/// Settings that an app profile may override. TouchSettings (TouchBridgeKit) conforms; kept as a protocol so
/// the resolution logic stays pure and testable here.
public protocol ProfileTunable {
    var gestures: GestureMap { get set }
    var nativeZoom: Bool { get set }
    var invertScroll: Bool { get set }
    var scrollGain: Double { get set }
    var oneFingerScroll: Bool { get set }
    var momentumScroll: Bool { get set }
    var smartTarget: Bool { get set }
    var contextMenu: Bool { get set }
    var longPressDuration: Double { get set }
}

/// Per-setting overrides; nil = same as the default profile (global settings).
public struct ProfileOverrides: Codable, Equatable {
    public var nativeZoom: Bool?
    public var invertScroll: Bool?
    public var scrollGain: Double?
    public var oneFingerScroll: Bool?
    public var momentumScroll: Bool?
    public var smartTarget: Bool?
    public var contextMenu: Bool?
    public var longPressDuration: Double?

    public init(nativeZoom: Bool? = nil, invertScroll: Bool? = nil, scrollGain: Double? = nil,
                oneFingerScroll: Bool? = nil, momentumScroll: Bool? = nil, smartTarget: Bool? = nil,
                contextMenu: Bool? = nil, longPressDuration: Double? = nil) {
        self.nativeZoom = nativeZoom
        self.invertScroll = invertScroll
        self.scrollGain = scrollGain
        self.oneFingerScroll = oneFingerScroll
        self.momentumScroll = momentumScroll
        self.smartTarget = smartTarget
        self.contextMenu = contextMenu
        self.longPressDuration = longPressDuration
    }

    /// Number of overridden settings
    public var count: Int {
        [nativeZoom, invertScroll, oneFingerScroll, momentumScroll, smartTarget, contextMenu].compactMap { $0 }.count
            + (scrollGain == nil ? 0 : 1) + (longPressDuration == nil ? 0 : 1)
    }

    /// Scroll gain presets offered in the menu / profile editor
    public static let scrollGains: [Double] = [0.6, 1.0, 1.6, 2.4]

    public static func clampGain(_ g: Double) -> Double { max(0.2, min(5, g)) }
    public static func clampLongPress(_ d: Double) -> Double { max(0.25, min(2, d)) }
}

// MARK: - Profile

public struct AppProfile: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// App the profile switches on automatically; nil = manual profile (menu only)
    public var bundleID: String?
    /// Path of the .app (icon / display only, optional)
    public var appPath: String?
    /// Full gesture map (14 slots) used while the profile is active
    public var gestures: GestureMap
    public var overrides: ProfileOverrides

    public init(id: UUID = UUID(), name: String, bundleID: String? = nil, appPath: String? = nil,
                gestures: GestureMap = .defaults, overrides: ProfileOverrides = ProfileOverrides()) {
        self.id = id
        self.name = name
        self.bundleID = AppProfile.normalized(bundleID)
        self.appPath = appPath
        self.gestures = gestures
        self.overrides = overrides
    }

    enum CodingKeys: String, CodingKey { case id, name, bundleID, appPath, gestures, overrides }

    /// Tolerant decoding: missing id -> new UUID, missing gestures -> defaults, missing overrides -> none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        bundleID = AppProfile.normalized((try? c.decodeIfPresent(String.self, forKey: .bundleID)) ?? nil)
        appPath = (try? c.decodeIfPresent(String.self, forKey: .appPath)) ?? nil
        gestures = ((try? c.decodeIfPresent(GestureMap.self, forKey: .gestures)) ?? nil) ?? .defaults
        var o = ((try? c.decodeIfPresent(ProfileOverrides.self, forKey: .overrides)) ?? nil) ?? ProfileOverrides()
        o.scrollGain = o.scrollGain.map(ProfileOverrides.clampGain)
        o.longPressDuration = o.longPressDuration.map(ProfileOverrides.clampLongPress)
        overrides = o
    }

    static func normalized(_ b: String?) -> String? {
        guard let t = b?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    public var isManual: Bool { bundleID == nil }

    /// Base settings with this profile's gesture map and overrides applied.
    public func apply<S: ProfileTunable>(to base: S) -> S {
        var s = base
        s.gestures = gestures
        let o = overrides
        if let v = o.nativeZoom { s.nativeZoom = v }
        if let v = o.invertScroll { s.invertScroll = v }
        if let v = o.scrollGain { s.scrollGain = ProfileOverrides.clampGain(v) }
        if let v = o.oneFingerScroll { s.oneFingerScroll = v }
        if let v = o.momentumScroll { s.momentumScroll = v }
        if let v = o.smartTarget { s.smartTarget = v }
        if let v = o.contextMenu { s.contextMenu = v }
        if let v = o.longPressDuration { s.longPressDuration = ProfileOverrides.clampLongPress(v) }
        return s
    }
}

// MARK: - Selection

/// Menu "Profile: Automatic / Default / <name>"
public enum ProfileSelection: Equatable, Codable {
    /// Follow the frontmost app
    case automatic
    /// Always the default profile (global settings)
    case defaultProfile
    /// Always this profile
    case profile(UUID)

    /// "automatic", "default", "profile:<uuid>"
    public var rawValue: String {
        switch self {
        case .automatic: return "automatic"
        case .defaultProfile: return "default"
        case .profile(let id): return "profile:" + id.uuidString
        }
    }

    public init(rawValue: String) {
        if rawValue == "default" { self = .defaultProfile }
        else if rawValue.hasPrefix("profile:"), let id = UUID(uuidString: String(rawValue.dropFirst("profile:".count))) {
            self = .profile(id)
        } else { self = .automatic }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "automatic")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Store

/// All profiles plus the menu selection. Persisted as JSON (UserDefaults) by the app.
public struct ProfileStore: Codable, Equatable {
    public var profiles: [AppProfile]
    public var selection: ProfileSelection

    public init(profiles: [AppProfile] = [], selection: ProfileSelection = .automatic) {
        self.profiles = profiles
        self.selection = selection
    }

    enum CodingKeys: String, CodingKey { case profiles, selection }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = ((try? c.decodeIfPresent([AppProfile].self, forKey: .profiles)) ?? nil) ?? []
        selection = ((try? c.decodeIfPresent(ProfileSelection.self, forKey: .selection)) ?? nil) ?? .automatic
        normalize()
    }

    public subscript(id: UUID) -> AppProfile? {
        profiles.first { $0.id == id }
    }

    /// First profile assigned to this app
    public func profile(forBundleID b: String?) -> AppProfile? {
        guard let b = b, !b.isEmpty else { return nil }
        return profiles.first { $0.bundleID?.caseInsensitiveCompare(b) == .orderedSame }
    }

    /// Profile in effect for the given frontmost app; nil = default profile (global settings).
    public func active(frontmostBundleID: String?) -> AppProfile? {
        switch selection {
        case .defaultProfile: return nil
        case .profile(let id): return self[id] ?? profile(forBundleID: frontmostBundleID)
        case .automatic: return profile(forBundleID: frontmostBundleID)
        }
    }

    /// Effective settings: global settings with the active profile applied.
    public func effective<S: ProfileTunable>(_ global: S, frontmostBundleID: String?) -> S {
        guard let p = active(frontmostBundleID: frontmostBundleID) else { return global }
        return p.apply(to: global)
    }

    // MARK: Editing

    /// Adds a profile; for an app that already has one, that profile is returned unchanged.
    @discardableResult
    public mutating func add(name: String, bundleID: String?, appPath: String? = nil,
                             gestures: GestureMap = .defaults) -> AppProfile {
        if let existing = profile(forBundleID: bundleID) { return existing }
        let p = AppProfile(name: uniqueName(name), bundleID: bundleID, appPath: appPath, gestures: gestures)
        profiles.append(p)
        return p
    }

    /// Copy of a profile (as manual profile, so the app keeps exactly one automatic profile)
    @discardableResult
    public mutating func duplicate(_ id: UUID) -> AppProfile? {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        var p = profiles[i]
        p.id = UUID()
        p.name = uniqueName(L("\(p.name) copy", "\(p.name) Kopie"))
        p.bundleID = nil
        profiles.insert(p, at: i + 1)
        return p
    }

    public mutating func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if selection == .profile(id) { selection = .automatic }
    }

    public mutating func update(_ p: AppProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i] = p
        normalize()
    }

    /// "Name", "Name 2", "Name 3", …
    public func uniqueName(_ base: String) -> String {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Profile", "Profil") : base
        let names = Set(profiles.map { $0.name })
        if !names.contains(b) { return b }
        var n = 2
        while names.contains("\(b) \(n)") { n += 1 }
        return "\(b) \(n)"
    }

    /// One automatic profile per app (later duplicates become manual), unique ids, valid selection.
    mutating func normalize() {
        var seenIDs = Set<UUID>(), seenApps = Set<String>()
        for i in profiles.indices {
            if seenIDs.contains(profiles[i].id) { profiles[i].id = UUID() }
            seenIDs.insert(profiles[i].id)
            if let b = profiles[i].bundleID?.lowercased() {
                if seenApps.contains(b) { profiles[i].bundleID = nil } else { seenApps.insert(b) }
            }
        }
        if case .profile(let id) = selection, self[id] == nil { selection = .automatic }
    }

    // MARK: Export / import

    public static let exportFormat = "touchbridge-profiles"
    public static let exportVersion = 1

    struct ExportFile: Codable {
        var format: String
        var version: Int
        var profiles: [AppProfile]
    }

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case notAProfileFile
        case unsupportedVersion(Int)
        case empty
        public var description: String {
            switch self {
            case .notAProfileFile: return L("This is not a TouchBridge profile file.", "Das ist keine TouchBridge-Profildatei.")
            case .unsupportedVersion(let v):
                return L("Profile file version \(v) is newer than this TouchBridge supports – please update.",
                         "Profildatei-Version \(v) ist neuer als diese TouchBridge-Version – bitte aktualisieren.")
            case .empty: return L("The file contains no profiles.", "Die Datei enthält keine Profile.")
            }
        }
    }

    /// JSON file (versioned) with the given profiles (default: all)
    public func exportData(_ ids: [UUID]? = nil) throws -> Data {
        let list = ids.map { set in profiles.filter { set.contains($0.id) } } ?? profiles
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(ExportFile(format: ProfileStore.exportFormat, version: ProfileStore.exportVersion, profiles: list))
    }

    public static func decodeExport(_ data: Data) throws -> [AppProfile] {
        struct Header: Decodable { var format: String?; var version: Int? }
        guard let h = try? JSONDecoder().decode(Header.self, from: data), h.format == exportFormat else {
            throw ImportError.notAProfileFile
        }
        let v = h.version ?? 1
        guard v <= exportVersion else { throw ImportError.unsupportedVersion(v) }
        guard let f = try? JSONDecoder().decode(ExportFile.self, from: data) else { throw ImportError.notAProfileFile }
        guard !f.profiles.isEmpty else { throw ImportError.empty }
        return f.profiles
    }

    /// Imports profiles: a profile for an app that already has one replaces it (keeping the local id);
    /// all others are added (new id if the id is taken, unique name).
    @discardableResult
    public mutating func importProfiles(_ incoming: [AppProfile]) -> (added: Int, replaced: Int) {
        var added = 0, replaced = 0
        for var p in incoming {
            if let existing = profile(forBundleID: p.bundleID), let i = profiles.firstIndex(where: { $0.id == existing.id }) {
                p.id = existing.id
                profiles[i] = p
                replaced += 1
            } else {
                if self[p.id] != nil { p.id = UUID() }
                p.name = uniqueName(p.name)
                profiles.append(p)
                added += 1
            }
        }
        normalize()
        return (added, replaced)
    }

    /// Import from a file's data
    @discardableResult
    public mutating func importData(_ data: Data) throws -> (added: Int, replaced: Int) {
        importProfiles(try ProfileStore.decodeExport(data))
    }
}

// MARK: - Frontmost app tracking

public enum FrontmostApp {
    /// Bundle ID that drives automatic profiles after an app activation. Activating TouchBridge itself
    /// (settings window, menus) keeps the previous app so its profile stays in effect.
    public static func next(current: String?, activated: String?, own: String?) -> String? {
        guard let a = activated, !a.isEmpty else { return current }
        if let o = own, a.caseInsensitiveCompare(o) == .orderedSame { return current }
        return a
    }
}

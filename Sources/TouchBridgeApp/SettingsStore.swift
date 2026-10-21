import Foundation
import TouchBridgeCore
import TouchBridgeKit

enum SettingsStore {
    private static let key = "touchSettings"
    static func load() -> TouchSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(TouchSettings.self, from: d) else { return TouchSettings() }
        return s
    }
    static func save(_ s: TouchSettings) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
    }
    /// Automatisch beim Start und alle 24 h nach Updates suchen
    static var autoUpdateCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdateCheck") }
    }
    /// Vorabversionen (Pre-Releases) anbieten – Standard an, solange alle Releases Previews sind
    static var includePrereleases: Bool {
        get { UserDefaults.standard.object(forKey: "includePrereleases") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "includePrereleases") }
    }
    /// Offer versions like 0.4.0-beta1? Default: only when a beta is installed.
    static var includeBetas: Bool {
        get { UserDefaults.standard.object(forKey: "includeBetas") as? Bool ?? UpdateLogic.betaDefault(current: Updater.currentVersion) }
        set { UserDefaults.standard.set(newValue, forKey: "includeBetas") }
    }
    static var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "skippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedVersion") }
    }
    static var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }
    static var softwareBrightness: Double {
        get { UserDefaults.standard.object(forKey: "softwareBrightness") as? Double ?? 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: "softwareBrightness") }
    }
}

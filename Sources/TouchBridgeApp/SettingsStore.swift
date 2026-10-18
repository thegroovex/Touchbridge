import Foundation
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
    static var softwareBrightness: Double {
        get { UserDefaults.standard.object(forKey: "softwareBrightness") as? Double ?? 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: "softwareBrightness") }
    }
}

import Foundation

/// App language: English by default, German on request (Menu › Language).
public enum AppLanguage: String, CaseIterable {
    case english = "en", german = "de"
    public var title: String { self == .english ? "English" : "Deutsch" }
}

public enum L10n {
    private static let key = "appLanguage"
    public static var language: AppLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .english
    public static func set(_ l: AppLanguage) { language = l; UserDefaults.standard.set(l.rawValue, forKey: key) }
    public static var german: Bool { language == .german }
}

/// L("English", "Deutsch")
@inline(__always) public func L(_ en: String, _ de: String) -> String { L10n.german ? de : en }

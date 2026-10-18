import Foundation

/// Bildschirm-Kandidat für die automatische Auswahl des Touch-Ziels (plattformneutral, testbar).
public struct DisplayCandidate: Equatable {
    public let id: UInt32
    public let name: String
    public let isBuiltin: Bool
    public let isMain: Bool
    public init(id: UInt32, name: String, isBuiltin: Bool, isMain: Bool) {
        self.id = id; self.name = name; self.isBuiltin = isBuiltin; self.isMain = isMain
    }
}

public enum DisplayChoice {
    /// Reihenfolge: gewählte ID › externer Bildschirm, dessen Name zum Touch-Gerät passt (z. B. „ANMITE“)
    /// › einziger externer › erster externer Nicht-Hauptbildschirm › erster externer › Hauptbildschirm.
    public static func choose(_ list: [DisplayCandidate], preferred: UInt32?, deviceHints: [String]) -> UInt32? {
        if let p = preferred, list.contains(where: { $0.id == p }) { return p }
        let external = list.filter { !$0.isBuiltin }
        let hints = deviceHints.map { $0.lowercased() }.flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
            .map(String.init).filter { $0.count >= 4 && !generic.contains($0) }
        if let m = external.first(where: { d in let n = d.name.lowercased(); return hints.contains { n.contains($0) } }) {
            return m.id
        }
        if external.count == 1 { return external[0].id }
        return external.first(where: { !$0.isMain })?.id ?? external.first?.id
            ?? list.first(where: { $0.isMain })?.id ?? list.first?.id
    }

    /// Wörter, die in Gerätenamen ohne Aussagekraft sind
    static let generic: Set<String> = ["touch", "touchscreen", "screen", "display", "monitor", "device", "multi", "multitouch", "inc", "corp", "ltd", "technology", "usb", "hid"]
}

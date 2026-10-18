import AppKit
import CoreGraphics
import TouchBridgeCore

public struct DisplayInfo: Equatable {
    public let id: CGDirectDisplayID
    public let name: String
    public let bounds: CGRect
    public let isBuiltin: Bool
    public let isMain: Bool

    public var summary: String {
        "\(name) – \(Int(bounds.width))×\(Int(bounds.height))" + (isMain ? " (Hauptbildschirm)" : "")
    }
}

public enum Displays {
    public static func activeIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    public static func name(of id: CGDirectDisplayID) -> String {
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == id {
                if #available(macOS 10.15, *) { return s.localizedName }
            }
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Integrierter Bildschirm" : "Bildschirm \(id)"
    }

    public static func all() -> [DisplayInfo] {
        activeIDs().map {
            DisplayInfo(id: $0, name: name(of: $0), bounds: CGDisplayBounds($0),
                        isBuiltin: CGDisplayIsBuiltin($0) != 0, isMain: $0 == CGMainDisplayID())
        }
    }

    /// Externe Bildschirme in stabiler Reihenfolge (für die Zuordnung zu DDC-Diensten).
    public static func externalIDs() -> [CGDirectDisplayID] {
        activeIDs().filter { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Bevorzugt: gewählte ID, sonst der externe Bildschirm, dessen Name zum Touch-Gerät passt (deviceHints,
    /// z. B. Hersteller/Produkt „ANMITE“), sonst der einzige externe, sonst erster externer Nicht-Hauptbildschirm.
    public static func resolve(_ preferred: CGDirectDisplayID?, deviceHints: [String] = []) -> CGDirectDisplayID {
        let list = all().map { DisplayCandidate(id: $0.id, name: $0.name, isBuiltin: $0.isBuiltin, isMain: $0.isMain) }
        return DisplayChoice.choose(list, preferred: preferred, deviceHints: deviceHints) ?? CGMainDisplayID()
    }
}

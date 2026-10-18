import Foundation

// MARK: - Spielfläche in normierten Bildschirmkoordinaten
// (0,0) = oben links, (1,1) = unten rechts – dieselben Koordinaten, die TouchMapping.apply liefert.

public struct NRect: Codable, Equatable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    /// Halboffen [x, x+w) – benachbarte Zonen überlappen sich nicht; der rechte/untere Bildrand zählt dazu.
    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && py >= y && (px < maxX || (maxX >= 1 && px <= 1)) && (py < maxY || (maxY >= 1 && py <= 1))
    }
    /// Punkt -> lokale Koordinaten 0…1 (auf die Zone begrenzt).
    public func local(_ px: Double, _ py: Double) -> (u: Double, v: Double) {
        (w > 0 ? min(1, max(0, (px - x) / w)) : 0, h > 0 ? min(1, max(0, (py - y) / h)) : 0)
    }
    /// Verkleinert um einen Rand (Abstand zwischen Zonen)
    public func inset(_ dx: Double, _ dy: Double) -> NRect { NRect(x + dx, y + dy, max(0, w - 2 * dx), max(0, h - 2 * dy)) }
}

public enum Scale: String, Codable, CaseIterable {
    case chromatic, major, minor, pentatonic, minorPentatonic, dorian, blues

    public var intervals: [Int] {
        switch self {
        case .chromatic: return Array(0...11)
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .pentatonic: return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        case .dorian: return [0, 2, 3, 5, 7, 9, 10]
        case .blues: return [0, 3, 5, 6, 7, 10]
        }
    }

    public var title: String {
        switch self {
        case .chromatic: return "Chromatisch"
        case .major: return "Dur"
        case .minor: return "Moll"
        case .pentatonic: return "Pentatonik (Dur)"
        case .minorPentatonic: return "Pentatonik (Moll)"
        case .dorian: return "Dorisch"
        case .blues: return "Blues"
        }
    }

    /// Halbtonabstand der Stufe `degree` (auch negativ / über die Oktave hinaus).
    public func offset(_ degree: Int) -> Int {
        let n = intervals.count
        let oct = Int((Double(degree) / Double(n)).rounded(.down))
        return intervals[degree - oct * n] + 12 * oct
    }
}

public enum PadVelocity: Codable, Equatable {
    /// feste Anschlagstärke
    case fixed(Int)
    /// aus der Anschlag-Position: oben im Pad = laut (127), unten = leise (`min`)
    case position(min: Int)
}

public struct KeyboardZone: Codable, Equatable {
    public var keys: Int
    /// Note der ersten (linken) Taste
    public var baseNote: Int
    public var scale: Scale
    public init(keys: Int, baseNote: Int, scale: Scale) { self.keys = keys; self.baseNote = baseNote; self.scale = scale }

    /// Note der Taste `index` (0 = links)
    public func note(_ index: Int) -> Int { baseNote + scale.offset(index) }

    /// Kontinuierliche Tonhöhe (Halbtöne) an lokaler Position u (0…1): Tastenmitten liegen exakt auf den
    /// Skalentönen, dazwischen wird linear interpoliert – so landet ein Glide auf der Nachbartaste genau auf deren Ton.
    public func pitch(atU u: Double) -> Double {
        let f = u * Double(keys) - 0.5          // 0 = Mitte der ersten Taste
        let i = Int(f.rounded(.down))
        let t = f - Double(i)
        return Double(note(i)) * (1 - t) + Double(note(i + 1)) * t
    }

    public func keyIndex(atU u: Double) -> Int { max(0, min(keys - 1, Int(u * Double(keys)))) }
}

public enum ZoneKind: Codable, Equatable {
    /// Vertikaler Fader: unten = 0, oben = 127
    case fader(cc: Int)
    case pad(note: Int, velocity: PadVelocity)
    /// XY-Feld: X -> ccX (links 0), Y -> ccY (unten 0)
    case xy(ccX: Int, ccY: Int)
    /// Tastenreihe (MPE-fähig)
    case keyboard(KeyboardZone)
}

public struct Zone: Codable, Equatable {
    public var name: String
    public var rect: NRect
    public var kind: ZoneKind
    public init(_ name: String, _ rect: NRect, _ kind: ZoneKind) { self.name = name; self.rect = rect; self.kind = kind }
}

public struct MIDILayout: Codable, Equatable {
    public var name: String
    public var zones: [Zone]
    public init(name: String, zones: [Zone]) { self.name = name; self.zones = zones }

    /// Index der Zone unter dem Punkt (bei Überlappung gewinnt die zuletzt definierte = oberste), sonst nil.
    public func hitTest(_ x: Double, _ y: Double) -> Int? {
        zones.indices.last { zones[$0].rect.contains(x, y) }
    }
}

// MARK: - Standard-Layouts

public enum MIDILayoutPreset: String, Codable, CaseIterable {
    case mixer, keyboard, performance

    public var title: String {
        switch self {
        case .mixer: return "Mixer (8 Fader + 8 Pads)"
        case .keyboard: return "MPE-Keyboard (2 Reihen)"
        case .performance: return "Performance (4 Fader, XY, 8 Pads)"
        }
    }

    /// baseNote: Grundnote für Keyboard bzw. erstes Pad; Fader-CCs ab 20, Pads ab baseNote.
    public func build(baseNote: Int = 48, scale: Scale = .chromatic) -> MIDILayout {
        let gap = 0.006
        switch self {
        case .mixer:
            var z: [Zone] = []
            for i in 0..<8 {
                let x = Double(i) / 8
                z.append(Zone("Fader \(i + 1)", NRect(x, 0, 1.0 / 8, 0.7).inset(gap, gap), .fader(cc: 20 + i)))
            }
            for i in 0..<8 {
                let x = Double(i) / 8
                z.append(Zone("Pad \(i + 1)", NRect(x, 0.7, 1.0 / 8, 0.3).inset(gap, gap),
                              .pad(note: baseNote + i, velocity: .position(min: 40))))
            }
            return MIDILayout(name: "Mixer", zones: z)

        case .keyboard:
            // obere Reihe eine Oktave höher, chromatisch: 2 × 13 Tasten (C bis C)
            let keys = scale == .chromatic ? 13 : scale.intervals.count + 1
            let upper = KeyboardZone(keys: keys, baseNote: baseNote + 12, scale: scale)
            let lower = KeyboardZone(keys: keys, baseNote: baseNote, scale: scale)
            return MIDILayout(name: "MPE-Keyboard", zones: [
                Zone("Obere Reihe", NRect(0, 0, 1, 0.5).inset(gap, gap), .keyboard(upper)),
                Zone("Untere Reihe", NRect(0, 0.5, 1, 0.5).inset(gap, gap), .keyboard(lower)),
            ])

        case .performance:
            var z: [Zone] = []
            for i in 0..<4 {
                z.append(Zone("Fader \(i + 1)", NRect(Double(i) * 0.1, 0, 0.1, 0.65).inset(gap, gap), .fader(cc: 20 + i)))
            }
            z.append(Zone("XY", NRect(0.4, 0, 0.6, 0.65).inset(gap, gap), .xy(ccX: 16, ccY: 17)))
            for i in 0..<8 {
                z.append(Zone("Pad \(i + 1)", NRect(Double(i) / 8, 0.65, 1.0 / 8, 0.35).inset(gap, gap),
                              .pad(note: baseNote + i, velocity: .position(min: 40))))
            }
            return MIDILayout(name: "Performance", zones: z)
        }
    }
}

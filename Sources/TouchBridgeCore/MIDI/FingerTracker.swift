import Foundation

/// Ein Kontakt in normierten Bildschirmkoordinaten (nach TouchMapping), id = Contact-ID des Controllers.
public struct TouchPoint: Equatable {
    public var id: Int
    public var x: Double
    public var y: Double
    /// Druck 0…1, falls vorhanden (sonst ggf. aus der Kontaktgröße abgeleitet)
    public var pressure: Double?
    /// Kontaktgröße 0…1, falls vorhanden (Ersatz für Druck)
    public var size: Double?
    public init(id: Int, x: Double, y: Double, pressure: Double? = nil, size: Double? = nil) {
        self.id = id; self.x = x; self.y = y; self.pressure = pressure; self.size = size
    }
}

public enum FingerEvent: Equatable {
    case began(finger: Int, TouchPoint)
    case moved(finger: Int, TouchPoint)
    case ended(finger: Int)
}

/// Vergibt stabile Finger-IDs über Frames hinweg (bis `maxFingers` gleichzeitig).
/// Basis ist die Contact-ID des Controllers; springt ein Kontakt mit derselben ID unplausibel weit
/// (Controller hat die ID sofort neu vergeben), wird das als Abheben + neues Aufsetzen gewertet.
public struct FingerTracker {
    public var maxFingers: Int
    /// Sprungweite (normiert), ab der eine wiederverwendete Contact-ID als neuer Finger gilt
    public var jumpThreshold: Double
    private var active: [Int: (finger: Int, last: TouchPoint)] = [:]   // Contact-ID -> Finger
    private var nextFinger = 1

    public init(maxFingers: Int = 10, jumpThreshold: Double = 0.3) {
        self.maxFingers = maxFingers; self.jumpThreshold = jumpThreshold
    }

    public var activeCount: Int { active.count }

    /// Kompletter Frame (alle aktuell aufliegenden Kontakte) -> Ereignisse. Reihenfolge: ended, moved, began.
    public mutating func update(_ contacts: [TouchPoint]) -> [FingerEvent] {
        var ended: [FingerEvent] = [], moved: [FingerEvent] = [], began: [FingerEvent] = []
        var seen = Set<Int>()
        var fresh: [TouchPoint] = []
        for c in contacts where !seen.contains(c.id) {
            seen.insert(c.id)
            if let a = active[c.id] {
                if hypot(c.x - a.last.x, c.y - a.last.y) > jumpThreshold {
                    ended.append(.ended(finger: a.finger))
                    active[c.id] = nil
                    fresh.append(c)
                } else {
                    active[c.id] = (a.finger, c)
                    if c != a.last { moved.append(.moved(finger: a.finger, c)) }
                }
            } else {
                fresh.append(c)
            }
        }
        for (cid, a) in active where !seen.contains(cid) {
            ended.append(.ended(finger: a.finger))
            active[cid] = nil
        }
        ended.sort { f($0) < f($1) }
        for c in fresh where active.count < maxFingers {
            let id = nextFinger
            nextFinger = nextFinger == Int.max ? 1 : nextFinger + 1
            active[c.id] = (id, c)
            began.append(.began(finger: id, c))
        }
        return ended + moved.sorted { f($0) < f($1) } + began
    }

    /// Alle Finger beenden (z. B. Gerät weg / Modus gewechselt).
    public mutating func reset() -> [FingerEvent] { update([]) }

    private func f(_ e: FingerEvent) -> Int {
        switch e {
        case .began(let i, _), .moved(let i, _): return i
        case .ended(let i): return i
        }
    }
}

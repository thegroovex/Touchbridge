import Foundation

/// Kanalvergabe für MPE Lower Zone: Master = Kanal 1 (0), Member = Kanäle 2…(1+memberCount).
/// Round-robin; freie Kanäle werden bevorzugt (so klingen Release-Phasen auf ihrem Kanal aus).
/// Sind alle belegt, wird der am längsten belegte Kanal übernommen (`stolen` meldet das).
public struct MPEChannelAllocator {
    public let masterChannel = 0
    public let memberChannels: [Int]
    private var busy: [Int: UInt64] = [:]    // Kanal -> Vergabe-Reihenfolge
    private var serial: UInt64 = 0
    private var cursor = 0

    public init(memberCount: Int = 15) {
        let n = max(1, min(15, memberCount))
        memberChannels = Array(1...n)
    }

    public var activeChannels: Set<Int> { Set(busy.keys) }
    public func isBusy(_ ch: Int) -> Bool { busy[ch] != nil }

    /// Liefert den Kanal für eine neue Note. stolen = true, wenn der Kanal noch eine Note trug.
    public mutating func allocate() -> (channel: Int, stolen: Bool) {
        serial += 1
        let n = memberChannels.count
        for k in 0..<n {
            let ch = memberChannels[(cursor + k) % n]
            if busy[ch] == nil {
                cursor = (cursor + k + 1) % n
                busy[ch] = serial
                return (ch, false)
            }
        }
        let oldest = busy.min { $0.value < $1.value }!.key
        busy[oldest] = serial
        if let i = memberChannels.firstIndex(of: oldest) { cursor = (i + 1) % n }
        return (oldest, true)
    }

    public mutating func release(_ channel: Int) { busy[channel] = nil }
    public mutating func reset() { busy = [:]; cursor = 0 }
}

public enum PitchBend {
    /// Halbtöne -> 14-bit-Pitch-Bend (8192 = Mitte), begrenzt auf ±range.
    public static func value(semitones: Double, range: Int) -> Int {
        guard range > 0 else { return 8192 }
        let r = Double(range)
        let s = max(-r, min(r, semitones))
        let v = 8192 + (s / r) * (s >= 0 ? 8191 : 8192)
        return max(0, min(16383, Int(v.rounded())))
    }
}

import Foundation

public struct MIDIConfig: Codable, Equatable {
    /// MPE (Lower Zone: Master Kanal 1, Member 2…16) für Keyboard-Zonen; aus = alles auf `channel`.
    public var mpe = true
    /// 0-basierter Kanal für alle Zonen ohne MPE. Mit MPE gehen Fader/Pads/XY auf den Master-Kanal 1.
    public var channel = 0
    /// Anzahl der MPE-Member-Kanäle (1…15)
    public var memberCount = 15
    /// Pitch-Bend-Range der Member-Kanäle in Halbtönen (MPE-Standard 48)
    public var bendRange = 48
    /// RPN 6 (MPE Configuration) + RPN 0 (Bend-Range) beim Start senden
    public var sendConfiguration = true
    /// Höchstrate kontinuierlicher Daten (CC, Pitch Bend, Druck) pro Kanal in Hz
    public var maxRate = 250.0
    /// Anschlagstärke der Keyboard-Tasten, wenn der Controller keinen Druck meldet
    public var keyVelocity = 100
    /// Kontaktgröße (normiert), die vollem Druck entspricht, wenn nur Width/Height gemeldet werden
    public var sizeFullScale = 0.06
    public init() {}
}

/// Zustand für die Overlay-Anzeige.
public struct MIDIFingerInfo: Equatable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var zone: Int?
    public var note: Int?
    public var channel: Int?
}

public struct XYValue: Equatable {
    public var x: Double, y: Double
}

/// Übersetzt Touch-Frames (normierte Bildschirmkoordinaten) über ein Layout in MIDI.
/// Jeder Finger bleibt an der Zone, in der er aufgesetzt hat.
public final class MIDIEngine {
    public private(set) var config: MIDIConfig
    public private(set) var layout: MIDILayout
    public var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private let sink: MIDISink

    private struct Finger {
        var point: TouchPoint
        var down: TouchPoint
        var zone: Int?
        var note: Int?
        var channel = 0
        var downPitch = 0.0
    }

    private var tracker = FingerTracker()
    private var fingers: [Int: Finger] = [:]
    private var allocator: MPEChannelAllocator
    private var padCount: [Int: Int] = [:]
    private var noteCount: [Int: Int] = [:]       // (Kanal << 8 | Note) -> gedrückte Finger (ohne MPE)

    // Drosselung: nur bei Änderung, höchstens maxRate pro Kanal
    private var lastValue: [Int: [UInt8]] = [:]
    private var pending: [Int: [UInt8]] = [:]
    private var pendingOrder: [Int] = []
    private var lastSent: [Int: Double] = [:]
    private var sentThisBatch = Set<Int>()
    private var out: [[UInt8]] = []

    public private(set) var faderValues: [Int: Double] = [:]
    public private(set) var xyValues: [Int: XYValue] = [:]
    public var activePads: Set<Int> { Set(padCount.filter { $0.value > 0 }.keys) }

    public init(sink: MIDISink, layout: MIDILayout, config: MIDIConfig = MIDIConfig()) {
        self.sink = sink
        self.layout = layout
        self.config = config
        allocator = MPEChannelAllocator(memberCount: config.memberCount)
    }

    /// Kanal für Fader, Pads und XY
    public var controlChannel: Int { config.mpe ? 0 : max(0, min(15, config.channel)) }

    public var fingerInfo: [MIDIFingerInfo] {
        fingers.keys.sorted().map { id in
            let f = fingers[id]!
            return MIDIFingerInfo(id: id, x: f.point.x, y: f.point.y, zone: f.zone, note: f.note,
                                  channel: f.note != nil ? f.channel : nil)
        }
    }

    /// Konfigurationsnachrichten für den Empfänger (MPE: RPN 6 auf Kanal 1, RPN 0 auf jedem Member-Kanal).
    public static func configurationMessages(_ c: MIDIConfig) -> [[UInt8]] {
        guard c.mpe, c.sendConfiguration else { return [] }
        let a = MPEChannelAllocator(memberCount: c.memberCount)
        var m = MIDIMsg.mpeConfiguration(masterChannel: 0, memberCount: a.memberChannels.count)
        for ch in a.memberChannels { m += MIDIMsg.pitchBendRange(ch, semitones: c.bendRange) }
        return m
    }

    public func start() {
        let m = MIDIEngine.configurationMessages(config)
        if !m.isEmpty { sink.send(m) }
    }

    /// Alle Finger loslassen (Note Off für alles, was klingt).
    public func releaseAll() { update([]) }

    public func setLayout(_ l: MIDILayout) {
        guard l != layout else { return }
        releaseAll()
        layout = l
        faderValues = [:]; xyValues = [:]
    }

    public func setConfig(_ c: MIDIConfig) {
        guard c != config else { return }
        releaseAll()
        let resend = c.mpe != config.mpe || c.memberCount != config.memberCount || c.bendRange != config.bendRange
        let mpeOff = config.mpe && !c.mpe
        config = c
        allocator = MPEChannelAllocator(memberCount: c.memberCount)
        lastValue = [:]; pending = [:]; pendingOrder = []
        if mpeOff, c.sendConfiguration {
            sink.send(MIDIMsg.mpeConfiguration(masterChannel: 0, memberCount: 0))
        } else if resend { start() }
    }

    // MARK: - Frames

    /// touches: alle aktuell aufliegenden Kontakte. Leeres Array = alle Finger weg.
    public func update(_ touches: [TouchPoint]) {
        beginBatch()
        for e in tracker.update(touches) {
            switch e {
            case let .began(id, p): began(id, p)
            case let .moved(id, p): moved(id, p)
            case let .ended(id): ended(id)
            }
        }
        flushPending(force: false)
        endBatch()
    }

    /// Regelmäßig aufrufen (z. B. alle 4 ms): sendet gedrosselte, noch ausstehende Werte.
    public func tick() {
        guard !pending.isEmpty else { return }
        beginBatch()
        flushPending(force: false)
        endBatch()
    }

    private func beginBatch() { out = []; sentThisBatch = [] }
    private func endBatch() {
        if !out.isEmpty { sink.send(out) }
        out = []
    }

    private func pressure(_ p: TouchPoint) -> Double? {
        if let pr = p.pressure { return pr }
        if let s = p.size, config.sizeFullScale > 0 { return min(1, s / config.sizeFullScale) }
        return nil
    }

    private static func v7(_ x: Double) -> Int { Int((max(0, min(1, x)) * 127).rounded()) }

    private func began(_ id: Int, _ p: TouchPoint) {
        var f = Finger(point: p, down: p, zone: layout.hitTest(p.x, p.y))
        defer { fingers[id] = f }
        guard let zi = f.zone else { return }
        let zone = layout.zones[zi]
        let (u, v) = zone.rect.local(p.x, p.y)
        let ctl = controlChannel
        switch zone.kind {
        case let .fader(cc):
            faderValues[zi] = 1 - v
            continuous(ctl, kind: 0xB0, num: cc, MIDIMsg.cc(ctl, cc, Self.v7(1 - v)))
        case let .xy(ccX, ccY):
            xyValues[zi] = XYValue(x: u, y: 1 - v)
            continuous(ctl, kind: 0xB0, num: ccX, MIDIMsg.cc(ctl, ccX, Self.v7(u)))
            continuous(ctl, kind: 0xB0, num: ccY, MIDIMsg.cc(ctl, ccY, Self.v7(1 - v)))
        case let .pad(note, vel):
            let velocity: Int
            switch vel {
            case .fixed(let x): velocity = x
            case .position(let mn): velocity = mn + Int((Double(127 - mn) * (1 - v)).rounded())
            }
            f.note = note; f.channel = ctl
            if padCount[zi, default: 0] == 0 { emit(MIDIMsg.noteOn(ctl, note, velocity), channel: ctl) }
            padCount[zi, default: 0] += 1
        case let .keyboard(kb):
            let note = kb.note(kb.keyIndex(atU: u))
            f.note = note
            f.downPitch = kb.pitch(atU: u)
            let pr = pressure(p)
            let velocity = pr.map { 40 + Int(($0 * 87).rounded()) } ?? config.keyVelocity
            if config.mpe {
                let a = allocator.allocate()
                if a.stolen, let victim = fingers.first(where: { $0.value.note != nil && $0.value.channel == a.channel
                                                                 && $0.value.zone.map(isKeyboard) == true }) {
                    flushPending(channel: a.channel)
                    emit(MIDIMsg.noteOff(a.channel, victim.value.note!), channel: a.channel)
                    var o = victim.value; o.note = nil
                    fingers[victim.key] = o
                }
                let ch = a.channel
                f.channel = ch
                // Ausdruck vor Note On zurücksetzen (MPE-Empfehlung)
                direct(ch, kind: 0xE0, num: 0, MIDIMsg.pitchBend(ch, 8192))
                direct(ch, kind: 0xB0, num: 74, MIDIMsg.cc(ch, 74, Self.v7(1 - v)))
                direct(ch, kind: 0xD0, num: 0, MIDIMsg.channelPressure(ch, pr.map(Self.v7) ?? 0))
                emit(MIDIMsg.noteOn(ch, note, velocity), channel: ch)
            } else {
                f.channel = ctl
                let key = ctl << 8 | note
                if noteCount[key, default: 0] == 0 { emit(MIDIMsg.noteOn(ctl, note, velocity), channel: ctl) }
                noteCount[key, default: 0] += 1
            }
        }
    }

    private func isKeyboard(_ zi: Int) -> Bool {
        if case .keyboard = layout.zones[zi].kind { return true }
        return false
    }

    private func moved(_ id: Int, _ p: TouchPoint) {
        guard var f = fingers[id] else { return }
        f.point = p
        fingers[id] = f
        guard let zi = f.zone else { return }
        let zone = layout.zones[zi]
        let (u, v) = zone.rect.local(p.x, p.y)   // außerhalb der Zone: auf den Rand begrenzt
        let ctl = controlChannel
        switch zone.kind {
        case let .fader(cc):
            faderValues[zi] = 1 - v
            continuous(ctl, kind: 0xB0, num: cc, MIDIMsg.cc(ctl, cc, Self.v7(1 - v)))
        case let .xy(ccX, ccY):
            xyValues[zi] = XYValue(x: u, y: 1 - v)
            continuous(ctl, kind: 0xB0, num: ccX, MIDIMsg.cc(ctl, ccX, Self.v7(u)))
            continuous(ctl, kind: 0xB0, num: ccY, MIDIMsg.cc(ctl, ccY, Self.v7(1 - v)))
        case .pad:
            if let note = f.note, let pr = pressure(p) {
                continuous(ctl, kind: 0xA0, num: note, MIDIMsg.polyPressure(ctl, note, Self.v7(pr)))
            }
        case let .keyboard(kb):
            guard let note = f.note else { return }
            let ch = f.channel
            if config.mpe {
                let semis = kb.pitch(atU: u) - f.downPitch
                continuous(ch, kind: 0xE0, num: 0, MIDIMsg.pitchBend(ch, PitchBend.value(semitones: semis, range: config.bendRange)))
                continuous(ch, kind: 0xB0, num: 74, MIDIMsg.cc(ch, 74, Self.v7(1 - v)))
                if let pr = pressure(p) {
                    continuous(ch, kind: 0xD0, num: 0, MIDIMsg.channelPressure(ch, Self.v7(pr)))
                }
            } else if let pr = pressure(p) {
                continuous(ch, kind: 0xA0, num: note, MIDIMsg.polyPressure(ch, note, Self.v7(pr)))
            }
        }
    }

    private func ended(_ id: Int) {
        guard let f = fingers.removeValue(forKey: id), let zi = f.zone else { return }
        switch layout.zones[zi].kind {
        case .fader, .xy: break
        case .pad:
            guard let note = f.note else { return }
            let n = padCount[zi, default: 1] - 1
            padCount[zi] = n > 0 ? n : nil
            if n <= 0 {
                flushPending(channel: f.channel)
                emit(MIDIMsg.noteOff(f.channel, note), channel: f.channel)
            }
        case .keyboard:
            guard let note = f.note else { return }   // Kanal wurde bereits übernommen
            if config.mpe {
                flushPending(channel: f.channel)
                emit(MIDIMsg.noteOff(f.channel, note), channel: f.channel)
                allocator.release(f.channel)
            } else {
                let key = f.channel << 8 | note
                let n = noteCount[key, default: 1] - 1
                noteCount[key] = n > 0 ? n : nil
                if n <= 0 { emit(MIDIMsg.noteOff(f.channel, note), channel: f.channel) }
            }
        }
    }

    // MARK: - Ausgabe

    private func key(_ ch: Int, _ kind: Int, _ num: Int) -> Int { ch << 16 | kind << 8 | num }

    private func emit(_ m: [UInt8], channel: Int) {
        out.append(m)
        lastSent[channel] = clock()
        sentThisBatch.insert(channel)
    }

    /// Sofort senden (ohne Drosselung), aber für die Duplikat-Erkennung merken.
    private func direct(_ ch: Int, kind: Int, num: Int, _ m: [UInt8]) {
        let k = key(ch, kind, num)
        pending[k] = nil
        lastValue[k] = m
        emit(m, channel: ch)
    }

    /// Kontinuierlicher Wert: nur bei Änderung, höchstens maxRate pro Kanal; sonst zurückgestellt.
    private func continuous(_ ch: Int, kind: Int, num: Int, _ m: [UInt8]) {
        let k = key(ch, kind, num)
        if lastValue[k] == m { pending[k] = nil; return }
        if canSend(ch) {
            pending[k] = nil
            lastValue[k] = m
            emit(m, channel: ch)
        } else {
            if pending[k] == nil { pendingOrder.append(k) }
            pending[k] = m
        }
    }

    private func canSend(_ ch: Int) -> Bool {
        if sentThisBatch.contains(ch) { return true }
        guard config.maxRate > 0, let last = lastSent[ch] else { return true }
        return clock() - last >= 1 / config.maxRate - 1e-9
    }

    private func flushPending(force: Bool) {
        guard !pending.isEmpty else { pendingOrder = []; return }
        var rest: [Int] = []
        for k in pendingOrder {
            guard let m = pending[k] else { continue }
            let ch = k >> 16
            if force || canSend(ch) {
                pending[k] = nil
                if lastValue[k] != m { lastValue[k] = m; emit(m, channel: ch) }
            } else { rest.append(k) }
        }
        pendingOrder = rest
    }

    /// Ausstehende Werte eines Kanals sofort senden (vor Note Off, damit der Ausdruck stimmt).
    private func flushPending(channel: Int) {
        for k in pendingOrder where k >> 16 == channel {
            guard let m = pending[k] else { continue }
            pending[k] = nil
            if lastValue[k] != m { lastValue[k] = m; emit(m, channel: channel) }
        }
        pendingOrder.removeAll { pending[$0] == nil }
    }
}

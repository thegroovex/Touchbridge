import Foundation

// MARK: - MIDI 1.0 Nachrichten als Byte-Arrays
// Kanäle sind überall 0-basiert (0 = MIDI-Kanal 1, 15 = MIDI-Kanal 16).

/// Ziel der MIDI-Engine. CoreMIDI-Implementierung in TouchBridgeKit, in Tests ein Recorder.
public protocol MIDISink: AnyObject {
    /// Eine Gruppe vollständiger MIDI-1.0-Nachrichten (jede ein eigenes Array), in dieser Reihenfolge zu senden.
    func send(_ messages: [[UInt8]])
}

public enum MIDIMsg {
    static func ch(_ c: Int) -> UInt8 { UInt8(clamping: max(0, min(15, c))) }
    static func d(_ v: Int) -> UInt8 { UInt8(clamping: max(0, min(127, v))) }

    public static func noteOn(_ channel: Int, _ note: Int, _ velocity: Int) -> [UInt8] {
        [0x90 | ch(channel), d(note), UInt8(clamping: max(1, min(127, velocity)))]
    }
    public static func noteOff(_ channel: Int, _ note: Int, _ velocity: Int = 0) -> [UInt8] {
        [0x80 | ch(channel), d(note), d(velocity)]
    }
    public static func cc(_ channel: Int, _ controller: Int, _ value: Int) -> [UInt8] {
        [0xB0 | ch(channel), d(controller), d(value)]
    }
    public static func polyPressure(_ channel: Int, _ note: Int, _ value: Int) -> [UInt8] {
        [0xA0 | ch(channel), d(note), d(value)]
    }
    public static func channelPressure(_ channel: Int, _ value: Int) -> [UInt8] {
        [0xD0 | ch(channel), d(value)]
    }
    /// value: 0…16383, Mitte 8192
    public static func pitchBend(_ channel: Int, _ value: Int) -> [UInt8] {
        let v = max(0, min(16383, value))
        return [0xE0 | ch(channel), UInt8(v & 0x7F), UInt8(v >> 7)]
    }
    /// Registered Parameter Number setzen (Data Entry MSB/LSB), danach RPN „Null“ (127/127).
    public static func rpn(_ channel: Int, msb: Int, lsb: Int, valueMSB: Int, valueLSB: Int? = nil) -> [[UInt8]] {
        var out = [cc(channel, 101, msb), cc(channel, 100, lsb), cc(channel, 6, valueMSB)]
        if let l = valueLSB { out.append(cc(channel, 38, l)) }
        out += [cc(channel, 101, 127), cc(channel, 100, 127)]
        return out
    }
    /// MPE Configuration Message (RPN 6) auf dem Master-Kanal: Anzahl Member-Kanäle (0 = MPE aus).
    public static func mpeConfiguration(masterChannel: Int, memberCount: Int) -> [[UInt8]] {
        rpn(masterChannel, msb: 0, lsb: 6, valueMSB: max(0, min(15, memberCount)))
    }
    /// Pitch-Bend-Range (RPN 0) in Halbtönen.
    public static func pitchBendRange(_ channel: Int, semitones: Int) -> [[UInt8]] {
        rpn(channel, msb: 0, lsb: 0, valueMSB: max(0, min(96, semitones)), valueLSB: 0)
    }
    public static func allNotesOff(_ channel: Int) -> [UInt8] { cc(channel, 123, 0) }
}

/// Notenname (C3 = 60, wie Ableton Live): 48 -> "C2", 61 -> "C#3".
public func midiNoteName(_ n: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let i = ((n % 12) + 12) % 12
    return names[i] + "\(Int((Double(n) / 12).rounded(.down)) - 2)"
}

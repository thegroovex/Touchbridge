import CoreMIDI
import Foundation
import TouchBridgeCore

/// Virtuelle CoreMIDI-Quelle „TouchBridge“: erscheint in Ableton Live, Logic, Ohpe, livelooper … als MIDI-Eingang.
/// MIDI 1.0 über MIDIPacketList / MIDIReceived (läuft ab macOS 12).
public final class CoreMIDIOutput: MIDISink {
    public let name: String
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()

    /// Feste Unique-ID, damit DAWs den Port nach einem Neustart wiedererkennen ('TBM1').
    public static let uniqueID: MIDIUniqueID = 0x5442_4D31

    public init?(name: String = "TouchBridge", log: (String) -> Void = { print($0) }) {
        self.name = name
        var c = MIDIClientRef()
        var st = MIDIClientCreate(name as CFString, nil, nil, &c)
        guard st == noErr else {
            log("❌ CoreMIDI: Client konnte nicht angelegt werden (\(st)).")
            return nil
        }
        var s = MIDIEndpointRef()
        st = MIDISourceCreate(c, name as CFString, &s)
        guard st == noErr else {
            log("❌ CoreMIDI: virtuelle Quelle „\(name)“ konnte nicht angelegt werden (\(st)).")
            MIDIClientDispose(c)
            return nil
        }
        _ = MIDIObjectSetIntegerProperty(s, kMIDIPropertyUniqueID, CoreMIDIOutput.uniqueID)
        _ = MIDIObjectSetStringProperty(s, kMIDIPropertyManufacturer, "TouchBridge" as CFString)
        client = c
        source = s
        log("🎹 MIDI-Port „\(name)“ bereit.")
    }

    deinit {
        MIDIEndpointDispose(source)
        MIDIClientDispose(client)
    }

    public func send(_ messages: [[UInt8]]) {
        let msgs = messages.filter { !$0.isEmpty }
        guard !msgs.isEmpty else { return }
        let total = msgs.reduce(0) { $0 + $1.count }
        // Reicht auch, wenn jede Nachricht ein eigenes Paket bekommt.
        let capacity = MemoryLayout<MIDIPacketList>.size + msgs.count * MemoryLayout<MIDIPacket>.size + total + 64
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet: UnsafeMutablePointer<MIDIPacket>? = MIDIPacketListInit(list)
        for m in msgs {
            guard let cur = packet else { break }
            m.withUnsafeBufferPointer { b in
                packet = MIDIPacketListAdd(list, capacity, cur, 0, b.count, b.baseAddress!)
            }
        }
        MIDIReceived(source, list)
    }
}

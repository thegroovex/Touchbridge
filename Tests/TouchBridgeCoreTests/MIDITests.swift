import XCTest
@testable import TouchBridgeCore

final class RecordingMIDISink: MIDISink {
    var messages: [[UInt8]] = []
    var batches = 0
    func send(_ m: [[UInt8]]) { messages += m; batches += 1 }
    func drain() -> [[UInt8]] { defer { messages = [] }; return messages }
}

final class MIDILayoutTests: XCTestCase {
    func testMixerHitTest() {
        let l = MIDILayoutPreset.mixer.build(baseNote: 36)
        XCTAssertEqual(l.zones.count, 16)
        XCTAssertEqual(l.hitTest(0.05, 0.3), 0)           // Fader 1
        XCTAssertEqual(l.hitTest(0.93, 0.3), 7)           // Fader 8
        XCTAssertEqual(l.hitTest(0.05, 0.85), 8)          // Pad 1
        XCTAssertEqual(l.hitTest(0.95, 0.9), 15)          // Pad 8
        XCTAssertNil(l.hitTest(0.1225, 0.3))              // Spalt zwischen Fader 1 und 2
        XCTAssertNil(l.hitTest(0.05, 0.7))                // Spalt zwischen Fadern und Pads
        if case let .pad(note, _) = l.zones[9].kind { XCTAssertEqual(note, 37) } else { XCTFail() }
        if case let .fader(cc) = l.zones[3].kind { XCTAssertEqual(cc, 23) } else { XCTFail() }
    }

    func testPerformanceAndKeyboardHitTest() {
        let p = MIDILayoutPreset.performance.build()
        XCTAssertEqual(p.zones.count, 13)
        XCTAssertEqual(p.hitTest(0.7, 0.3), 4)
        if case .xy = p.zones[4].kind {} else { XCTFail("zone 4 should be XY") }
        XCTAssertEqual(p.hitTest(0.05, 0.3), 0)
        XCTAssertEqual(p.hitTest(0.05, 0.8), 5)
        let k = MIDILayoutPreset.keyboard.build(baseNote: 48)
        XCTAssertEqual(k.zones.count, 2)
        XCTAssertEqual(k.hitTest(0.5, 0.2), 0)
        XCTAssertEqual(k.hitTest(0.5, 0.8), 1)
    }

    func testNRectEdgesAndLocal() {
        let r = NRect(0, 0, 0.5, 1)
        XCTAssertTrue(r.contains(0, 0))
        XCTAssertFalse(r.contains(0.5, 0.5))                       // halboffen
        XCTAssertTrue(r.contains(0.2, 1))                          // unterer Bildrand zählt
        XCTAssertEqual(r.local(0.25, 0.5).u, 0.5, accuracy: 1e-12)
        XCTAssertEqual(r.local(2, -1).u, 1); XCTAssertEqual(r.local(2, -1).v, 0)
    }

    func testScalesAndKeys() {
        XCTAssertEqual(Scale.major.offset(7), 12)
        XCTAssertEqual(Scale.major.offset(-1), -1)
        XCTAssertEqual(Scale.minorPentatonic.offset(6), 15)
        let kb = KeyboardZone(keys: 8, baseNote: 60, scale: .major)
        XCTAssertEqual((0..<8).map(kb.note), [60, 62, 64, 65, 67, 69, 71, 72])
        XCTAssertEqual(kb.keyIndex(atU: 0.999), 7)
        XCTAssertEqual(kb.pitch(atU: 0.5 / 8), 60, accuracy: 1e-9)      // Tastenmitte = Ton
        XCTAssertEqual(kb.pitch(atU: 1.0 / 8), 61, accuracy: 1e-9)      // zwischen C und D
        XCTAssertEqual(midiNoteName(60), "C3")
        XCTAssertEqual(midiNoteName(49), "C#2")
    }
}

final class FingerTrackerTests: XCTestCase {
    func testStableIDsAndJumps() {
        var t = FingerTracker()
        var e = t.update([TouchPoint(id: 5, x: 0.1, y: 0.1), TouchPoint(id: 9, x: 0.5, y: 0.5)])
        XCTAssertEqual(e, [.began(finger: 1, TouchPoint(id: 5, x: 0.1, y: 0.1)),
                           .began(finger: 2, TouchPoint(id: 9, x: 0.5, y: 0.5))])
        e = t.update([TouchPoint(id: 9, x: 0.52, y: 0.5)])
        XCTAssertEqual(e, [.ended(finger: 1), .moved(finger: 2, TouchPoint(id: 9, x: 0.52, y: 0.5))])
        // Controller vergibt ID 9 sofort neu, weit entfernt -> neuer Finger
        e = t.update([TouchPoint(id: 9, x: 0.95, y: 0.95)])
        XCTAssertEqual(e, [.ended(finger: 2), .began(finger: 3, TouchPoint(id: 9, x: 0.95, y: 0.95))])
        // unverändert -> keine Ereignisse
        XCTAssertEqual(t.update([TouchPoint(id: 9, x: 0.95, y: 0.95)]), [])
        XCTAssertEqual(t.reset(), [.ended(finger: 3)])
    }

    func testTenFingersMax() {
        var t = FingerTracker()
        let pts = (0..<12).map { TouchPoint(id: $0, x: Double($0) / 12, y: 0.5) }
        let e = t.update(pts)
        XCTAssertEqual(e.count, 10)
        XCTAssertEqual(t.activeCount, 10)
    }
}

final class MPETests: XCTestCase {
    func testAllocatorRoundRobinPrefersFree() {
        var a = MPEChannelAllocator(memberCount: 15)
        XCTAssertEqual(a.memberChannels, Array(1...15))
        XCTAssertEqual(a.allocate().channel, 1)
        XCTAssertEqual(a.allocate().channel, 2)
        XCTAssertEqual(a.allocate().channel, 3)
        a.release(2)
        XCTAssertEqual(a.allocate().channel, 4)     // nicht sofort den gerade freigegebenen Kanal
        XCTAssertEqual(a.activeChannels, [1, 3, 4])
    }

    func testAllocatorWrapsAndSteals() {
        var a = MPEChannelAllocator(memberCount: 2)
        XCTAssertEqual(a.allocate().channel, 1)
        XCTAssertEqual(a.allocate().channel, 2)
        a.release(1)
        let r = a.allocate()
        XCTAssertEqual(r.channel, 1); XCTAssertFalse(r.stolen)
        let s = a.allocate()                          // alles belegt -> ältester (2) wird übernommen
        XCTAssertEqual(s.channel, 2); XCTAssertTrue(s.stolen)
    }

    func testPitchBendValues() {
        XCTAssertEqual(PitchBend.value(semitones: 0, range: 48), 8192)
        XCTAssertEqual(PitchBend.value(semitones: 48, range: 48), 16383)
        XCTAssertEqual(PitchBend.value(semitones: -48, range: 48), 0)
        XCTAssertEqual(PitchBend.value(semitones: 100, range: 48), 16383)
        XCTAssertEqual(PitchBend.value(semitones: 12, range: 48), 10240)
        XCTAssertEqual(PitchBend.value(semitones: -2, range: 2), 0)
        XCTAssertEqual(PitchBend.value(semitones: 1, range: 2), 12288)
        XCTAssertEqual(MIDIMsg.pitchBend(1, 8192), [0xE1, 0x00, 0x40])
        XCTAssertEqual(MIDIMsg.pitchBend(0, 16383), [0xE0, 0x7F, 0x7F])
    }

    func testRPN6Bytes() {
        XCTAssertEqual(MIDIMsg.mpeConfiguration(masterChannel: 0, memberCount: 15),
                       [[0xB0, 101, 0], [0xB0, 100, 6], [0xB0, 6, 15], [0xB0, 101, 127], [0xB0, 100, 127]])
        let all = MIDIEngine.configurationMessages(MIDIConfig())
        XCTAssertEqual(all.count, 5 + 15 * 6)
        XCTAssertEqual(Array(all[5..<11]),
                       [[0xB1, 101, 0], [0xB1, 100, 0], [0xB1, 6, 48], [0xB1, 38, 0], [0xB1, 101, 127], [0xB1, 100, 127]])
        var c = MIDIConfig(); c.mpe = false
        XCTAssertEqual(MIDIEngine.configurationMessages(c), [])
    }
}

final class MIDIEngineTests: XCTestCase {
    var sink: RecordingMIDISink!
    var now = 0.0

    override func setUp() { sink = RecordingMIDISink(); now = 10 }

    func engine(_ preset: MIDILayoutPreset, mpe: Bool = true, baseNote: Int = 48, maxRate: Double = 0) -> MIDIEngine {
        var c = MIDIConfig(); c.mpe = mpe; c.maxRate = maxRate; c.channel = 2
        let e = MIDIEngine(sink: sink, layout: preset.build(baseNote: baseNote), config: c)
        e.clock = { [unowned self] in self.now }
        return e
    }

    /// Mitte der Taste `k` (chromatisch, 13 Tasten) in der Reihe des Keyboard-Layouts
    func keyX(_ k: Int) -> Double { 0.006 + (Double(k) + 0.5) * 0.988 / 13 }
    let lowerY = 0.506 + 0.488 / 2

    func testFaderCCValues() {
        let e = engine(.mixer, mpe: false)
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.35)])                 // Mitte Fader 1
        XCTAssertEqual(sink.drain(), [[0xB2, 20, 64]])
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.006)])                // oben
        XCTAssertEqual(sink.drain(), [[0xB2, 20, 127]])
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.4)])                  // in Schritten nach unten
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.694)])                // unten
        XCTAssertEqual(sink.drain().last, [0xB2, 20, 0])
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.6941)])               // gleicher Wert -> nichts
        XCTAssertEqual(sink.drain(), [])
        XCTAssertEqual(e.faderValues[0] ?? -1, 0, accuracy: 1e-9)
    }

    func testFingerStaysInStartZone() {
        let e = engine(.mixer, mpe: false)
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.35)])
        _ = sink.drain()
        // Finger rutscht über Fader 2 bis in die Pads: bleibt Fader 1, Wert auf 0 begrenzt, kein Pad-Ton
        e.update([TouchPoint(id: 1, x: 0.18, y: 0.5)])
        e.update([TouchPoint(id: 1, x: 0.18, y: 0.7)])
        e.update([TouchPoint(id: 1, x: 0.18, y: 0.9)])
        let msgs: [[UInt8]] = sink.drain()
        let onlyFader1 = msgs.allSatisfy { $0[0] == 0xB2 && $0[1] == 20 }
        XCTAssertTrue(onlyFader1, "\(msgs)")
        XCTAssertEqual(msgs.last, [0xB2, 20, 0])
        e.update([])
        XCTAssertEqual(sink.drain(), [])
        XCTAssertEqual(e.fingerInfo, [])
    }

    func testPadsNoteOnOffAndVelocity() {
        let e = engine(.mixer, mpe: false, baseNote: 36)
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.706)])                 // ganz oben im Pad 1 -> 127
        XCTAssertEqual(sink.drain(), [[0x92, 36, 127]])
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.706), TouchPoint(id: 2, x: 0.06, y: 0.99)]) // 2. Finger, gleiches Pad
        XCTAssertEqual(sink.drain(), [])
        XCTAssertEqual(e.activePads, [8])
        e.update([TouchPoint(id: 2, x: 0.06, y: 0.99)])
        XCTAssertEqual(sink.drain(), [])
        e.update([])
        XCTAssertEqual(sink.drain(), [[0x82, 36, 0]])
        e.update([TouchPoint(id: 3, x: 0.19, y: 0.99)])                  // fast unten im Pad 2 -> ~min 40
        XCTAssertEqual(sink.drain(), [[0x92, 37, 41]])
    }

    func testMPEKeyboardChannelsAndRelease() {
        let e = engine(.keyboard, baseNote: 48)
        e.update([TouchPoint(id: 1, x: keyX(0), y: lowerY)])
        XCTAssertEqual(sink.drain(), [[0xE1, 0, 64], [0xB1, 74, 64], [0xD1, 0], [0x91, 48, 100]])
        e.update([TouchPoint(id: 1, x: keyX(0), y: lowerY), TouchPoint(id: 2, x: keyX(4), y: lowerY)])
        XCTAssertEqual(sink.drain().last, [0x92, 52, 100])
        e.update([TouchPoint(id: 1, x: keyX(0), y: lowerY), TouchPoint(id: 2, x: keyX(4), y: lowerY),
                  TouchPoint(id: 3, x: keyX(7), y: 0.25)])                // obere Reihe = +12
        XCTAssertEqual(sink.drain().last, [0x93, 67, 100])
        e.update([TouchPoint(id: 1, x: keyX(0), y: lowerY), TouchPoint(id: 3, x: keyX(7), y: 0.25)])
        XCTAssertEqual(sink.drain(), [[0x82, 52, 0]])
        e.update([TouchPoint(id: 1, x: keyX(0), y: lowerY), TouchPoint(id: 3, x: keyX(7), y: 0.25),
                  TouchPoint(id: 4, x: keyX(2), y: lowerY)])
        XCTAssertEqual(sink.drain().last, [0x94, 50, 100])                // Kanal 5, nicht der eben frei gewordene
        XCTAssertEqual(Set(e.fingerInfo.compactMap(\.channel)), [1, 3, 4])
        e.releaseAll()
        XCTAssertEqual(Set(sink.drain()), [[0x81, 48, 0], [0x83, 67, 0], [0x84, 50, 0]])
    }

    func testMPEGlidePitchBendAndTimbre() {
        let e = engine(.keyboard)
        e.update([TouchPoint(id: 1, x: keyX(3), y: lowerY)])
        _ = sink.drain()
        e.update([TouchPoint(id: 1, x: keyX(5), y: lowerY)])             // 2 Halbtöne nach rechts
        XCTAssertEqual(sink.drain(), [MIDIMsg.pitchBend(1, 8533)])
        e.update([TouchPoint(id: 1, x: keyX(5), y: 0.506)])              // ganz oben in der Reihe
        XCTAssertEqual(sink.drain(), [[0xB1, 74, 127]])
        e.update([TouchPoint(id: 1, x: keyX(3), y: 0.506)])
        e.update([TouchPoint(id: 1, x: keyX(1), y: 0.506)])              // 2 HT unter Anschlag
        XCTAssertEqual(sink.drain(), [MIDIMsg.pitchBend(1, 8192), MIDIMsg.pitchBend(1, PitchBend.value(semitones: -2, range: 48))])
        e.update([])
        XCTAssertEqual(sink.drain(), [[0x81, 51, 0]])
    }

    func testPressureFromContact() {
        let e = engine(.keyboard)
        e.update([TouchPoint(id: 1, x: keyX(0), y: lowerY, pressure: 0.5)])
        XCTAssertEqual(sink.drain(), [[0xE1, 0, 64], [0xB1, 74, 64], [0xD1, 64], [0x91, 48, 84]])
        e.update([TouchPoint(id: 1, x: keyX(0), y: lowerY, pressure: 1)])
        XCTAssertEqual(sink.drain(), [[0xD1, 127]])
        e.update([TouchPoint(id: 1, x: keyX(0), y: lowerY, size: 0.03)])  // nur Größe: 0.03 / 0.06 = 0.5
        XCTAssertEqual(sink.drain(), [[0xD1, 64]])
    }

    func testNonMPESingleChannel() {
        let e = engine(.keyboard, mpe: false)
        e.update([TouchPoint(id: 1, x: keyX(0), y: lowerY), TouchPoint(id: 2, x: keyX(0) + 0.01, y: lowerY)])
        XCTAssertEqual(sink.drain(), [[0x92, 48, 100]])                   // gleiche Taste: nur ein Note On
        e.update([TouchPoint(id: 2, x: keyX(2), y: lowerY)])             // kein Pitch Bend ohne MPE
        XCTAssertEqual(sink.drain(), [])
        e.update([])
        XCTAssertEqual(sink.drain(), [[0x82, 48, 0]])
    }

    func testThrottleAndTick() {
        let e = engine(.mixer, mpe: false, maxRate: 250)
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.35)])
        XCTAssertEqual(sink.drain(), [[0xB2, 20, 64]])
        now += 0.001
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.2)])                   // zu früh -> zurückgestellt
        XCTAssertEqual(sink.drain(), [])
        now += 0.001
        e.update([TouchPoint(id: 1, x: 0.06, y: 0.1)])                   // überschreibt den zurückgestellten Wert
        e.tick()
        XCTAssertEqual(sink.drain(), [])
        now += 0.003
        e.tick()
        XCTAssertEqual(sink.drain(), [[0xB2, 20, 110]])
        e.tick()
        XCTAssertEqual(sink.drain(), [])
    }

    func testStartSendsConfiguration() {
        let e = engine(.keyboard)
        e.start()
        XCTAssertEqual(sink.drain().prefix(3), [[0xB0, 101, 0], [0xB0, 100, 6], [0xB0, 6, 15]])
        var c = e.config; c.mpe = false
        e.setConfig(c)
        XCTAssertEqual(sink.drain(), MIDIMsg.mpeConfiguration(masterChannel: 0, memberCount: 0))
    }

    func testRawContactDefaults() {
        let r = RawContact(id: 1, x: 2, y: 3)
        XCTAssertNil(r.pressure); XCTAssertNil(r.size)
    }
}

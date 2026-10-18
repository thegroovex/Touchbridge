import CoreGraphics
import Foundation
import TouchBridgeCore
import TouchBridgeKit

// touchbridge – Kommandozeilen-Version (Diagnose, Skripte, Autostart ohne Menüleisten-App).

var settings = TouchSettings()
var listDisplays = false
var dump = false
var displayIndex: Int? = nil
var ddcGet: [String] = []
var ddcSet: [(String, Int)] = []

func parseInt(_ s: String) -> Int? {
    s.lowercased().hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
}

func printUsage() {
    print("""
    touchbridge – Multitouch für USB-Touchmonitore am Mac

      --list-displays        Bildschirme auflisten
      --display N            Touch auf Bildschirm N abbilden (Standard: erster externer)
      --dump                 Descriptor + Kontakte ausgeben, keine Events senden
      --no-seize             Gerät nicht exklusiv öffnen
      --rotate 0|90|180|270  Panel-Drehung (im Uhrzeigersinn)
      --swap-xy --flip-x --flip-y   Achsen anpassen
      --invert-scroll        Scrollrichtung umkehren
      --scroll-gain F        Scroll-Faktor (Standard 1.0)
      --vid 0x1234 --pid 0x5678     Bestimmtes Gerät wählen
      --midi                 MIDI-Modus: virtueller MIDI-Port „TouchBridge“ statt Maus & Gesten
      --layout mixer|keyboard|performance           MIDI-Layout (Standard: mixer)
      --no-mpe               ohne MPE, alles auf einem Kanal (--channel)
      --channel N            MIDI-Kanal 1–16 (ohne MPE; Standard 1)
      --base-note N          Grundnote für Keyboard/Pads (MIDI-Nummer, Standard 48 = C2)
      --scale NAME           Keyboard-Skala: chromatic|major|minor|pentatonic|minorPentatonic|dorian|blues
      --bend-range N         MPE-Pitch-Bend-Bereich in Halbtönen (Standard 48)
      --brightness N | --contrast N | --volume N    Bildsteuerung per DDC (0–100), dann Ende
      --get brightness|contrast|volume              Wert per DDC lesen, dann Ende
    """)
}

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    func next() -> String { args.isEmpty ? "" : args.removeFirst() }
    switch a {
    case "--list-displays": listDisplays = true
    case "--display": displayIndex = Int(next())
    case "--dump": dump = true
    case "--no-seize": settings.seize = false
    case "--rotate": settings.rotation = Int(next()) ?? 0
    case "--swap-xy": settings.swapXY = true
    case "--flip-x": settings.flipX = true
    case "--flip-y": settings.flipY = true
    case "--invert-scroll": settings.invertScroll = true
    case "--scroll-gain": settings.scrollGain = Double(next()) ?? 1.0
    case "--vid": settings.vid = parseInt(next())
    case "--pid": settings.pid = parseInt(next())
    case "--midi": settings.mode = .midi
    case "--layout":
        let v = next()
        guard let l = MIDILayoutPreset(rawValue: v) else { print("Unbekanntes Layout: \(v) (mixer|keyboard|performance)"); exit(1) }
        settings.midiLayout = l
    case "--no-mpe": settings.mpe = false
    case "--channel": settings.midiChannel = max(1, min(16, Int(next()) ?? 1))
    case "--base-note": settings.baseNote = max(0, min(108, Int(next()) ?? 48))
    case "--scale":
        let v = next()
        guard let sc = Scale(rawValue: v) else { print("Unbekannte Skala: \(v)"); exit(1) }
        settings.scale = sc
    case "--bend-range": settings.bendRange = max(1, min(96, Int(next()) ?? 48))
    case "--brightness", "--contrast", "--volume": ddcSet.append((String(a.dropFirst(2)), Int(next()) ?? -1))
    case "--get": ddcGet.append(next())
    case "-h", "--help": printUsage(); exit(0)
    default: print("Unbekannte Option: \(a)"); printUsage(); exit(1)
    }
}

let displays = Displays.all()
if let i = displayIndex, i >= 0, i < displays.count { settings.displayID = displays[i].id }

if listDisplays {
    for (i, d) in displays.enumerated() {
        print("[\(i)] id=\(d.id) \(d.name) \(Int(d.bounds.width))x\(Int(d.bounds.height)) @ (\(Int(d.bounds.minX)),\(Int(d.bounds.minY)))"
              + (d.isBuiltin ? " intern" : " extern") + (d.isMain ? " (Hauptbildschirm)" : ""))
    }
    exit(0)
}

if !ddcGet.isEmpty || !ddcSet.isEmpty {
    let ctl = DisplayControl(display: Displays.resolve(settings.displayID))
    guard ctl.hasDDC else { print("❌ Bildschirm antwortet nicht auf DDC (oder Intel-Mac: dort noch nicht unterstützt)."); exit(3) }
    func feature(_ s: String) -> DisplayControl.Feature? {
        ["brightness": .brightness, "contrast": .contrast, "volume": .volume][s]
    }
    var pending = ddcGet.count
    for (name, v) in ddcSet {
        guard let f = feature(name), (0...100).contains(v) else { print("Ungültig: --\(name) \(v)"); exit(1) }
        ctl.set(f, percent: v)
        print("\(f.title) -> \(v) %")
    }
    for name in ddcGet {
        guard let f = feature(name) else { print("Unbekannt: \(name)"); exit(1) }
        ctl.read(f) { v in
            print("\(f.title): " + (v.map { "\($0) %" } ?? "nicht unterstützt"))
            pending -= 1
            if pending == 0 { exit(0) }
        }
    }
    if pending == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) } }
    RunLoop.main.run()
}

let service = TouchService(settings: settings)
service.dumpMode = dump
if !dump && settings.mode == .gestures {
    Permissions.requestAccessibility()
    if !Permissions.accessibility {
        print("⚠️  Bitte unter Systemeinstellungen › Datenschutz & Sicherheit › Bedienungshilfen Zugriff geben und neu starten.")
    }
}
if !Permissions.inputMonitoring {
    Permissions.requestInputMonitoring()
    print("⚠️  Ggf. unter Datenschutz & Sicherheit › Eingabeüberwachung Zugriff erlauben und neu starten.")
}
service.start()
guard service.status.running else { exit(2) }
let b = CGDisplayBounds(service.targetDisplay)
print("🖥  Ziel-Bildschirm: \(Int(b.width))x\(Int(b.height)) @ (\(Int(b.minX)),\(Int(b.minY)))")
if settings.mode == .midi && !dump {
    print("🎛  MIDI-Modus – Layout \(settings.midiLayout.title), " + (settings.mpe ? "MPE" : "Kanal \(settings.midiChannel)")
          + ", MIDI-Port „TouchBridge“.")
    for (i, z) in settings.midiLayoutModel.zones.enumerated() {
        print(String(format: "   [%2d] %@  x %.2f–%.2f  y %.2f–%.2f", i, z.name, z.rect.x, z.rect.maxX, z.rect.y, z.rect.maxY))
    }
}
print(dump ? "Dump-Modus – berühre den Bildschirm. Ctrl+C beendet." : "Läuft. Ctrl+C beendet.")
// Ctrl+C: klingende Noten beenden, bevor der Prozess (und damit der MIDI-Port) verschwindet
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { service.stop(); exit(0) }
sigint.resume()
CFRunLoopRun()

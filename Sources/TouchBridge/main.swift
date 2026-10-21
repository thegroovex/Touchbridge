import CoreGraphics
import Foundation
import TouchBridgeCore
import TouchBridgeKit

// touchbridge – command-line version (diagnostics, scripts, autostart without the menu bar app).

var settings = TouchSettings()
var listDisplays = false
var dump = false
var displayIndex: Int? = nil
var ddcGet: [String] = []
var ddcSet: [(String, Int)] = []
var diagnoseSeconds: Double? = nil
var checkUpdate = false
var mtProbe = false
var touchProbe = false
var mtOptions = MultitouchExperiment.Options()

func parseInt(_ s: String) -> Int? {
    s.lowercased().hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
}

func printUsage() {
    print("""
    touchbridge – multitouch for USB touch monitors on the Mac

      --list-displays        list displays
      --display N            map touch to display N (default: first external)
      --dump                 print descriptor + contacts, send no events
      --check-update         look for a newer version on GitHub (incl. pre-releases), then exit
      --diagnose [SEC]       open all HID interfaces of the touch monitor non-exclusively, set Input Mode,
                             log raw reports (default 10 s), then exit
      --mt-probe             run the multitouch experiments (a–e), waiting 3 s each for report 13
                             (tap with 2 fingers meanwhile), then exit (exit 0 = multitouch found, 6 = not)
      --touch-probe          real touch experiment: plays tap, drag and 2-finger pinch on the touch display in 5
                             variants (synthetic events with an IOHIDEvent digitizer payload), logs what passes the
                             WindowServer, appends to ~/Desktop/TouchBridge-RealTouch-Probe.txt, then exits.
                             Open the app's Touch Test window on the touch display first to see what apps receive.
      --skip-reenumerate     with --mt-probe, skip step d (USB re-enumeration)
      --mt-sequence NAME     apply a multitouch sequence on connect: hid-input-get|hid-feature|
                             usb-linux-init|usb-interface-linux-init|usb-reenumerate-init|hid-set-value
      --no-seize             do not open the device exclusively
      --no-suppress          turn off system pointer suppression (event tap, when not exclusive)
      --seize-touch-only     seize only the touch (digitizer) interface, not mouse/vendor (test)
      --one-finger-scroll    1-finger drag scrolls instead of pointer/drag
      --key-zoom             pinch sends Cmd +/- instead of the trackpad zoom gesture
      --no-momentum          no momentum (coasting) after lifting the fingers while scrolling
      --show-pointer         do not hide the pointer while touching
      --rotate 0|90|180|270  panel rotation (clockwise)
      --swap-xy --flip-x --flip-y   adjust axes
      --invert-scroll        invert scroll direction
      --scroll-gain F        scroll factor (default 1.0)
      --vid 0x1234 --pid 0x5678     choose a specific device
      --midi                 MIDI mode: virtual MIDI port "TouchBridge" instead of mouse & gestures
      --digitizer            output to the nRF52840 digitizer dongle (USB 2fe3:0010): macOS handles touch,
                             TouchBridge posts no gestures or mouse events (firmware/nrf-digitizer)
      --digitizer-space touch|main|all   screen area the dongle covers (default: touch display)
      --layout mixer|keyboard|performance           MIDI layout (default: mixer)
      --no-mpe               without MPE, everything on one channel (--channel)
      --channel N            MIDI channel 1–16 (without MPE; default 1)
      --base-note N          base note for keyboard/pads (MIDI number, default 48 = C2)
      --scale NAME           keyboard scale: chromatic|major|minor|pentatonic|minorPentatonic|dorian|blues
      --bend-range N         MPE pitch bend range in semitones (default 48)
      --brightness N | --contrast N | --volume N    display control via DDC (0–100), then exit
      --get brightness|contrast|volume              read a value via DDC, then exit
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
    case "--check-update": checkUpdate = true
    case "--diagnose":
        diagnoseSeconds = 10
        if let n = args.first.flatMap(Double.init) { diagnoseSeconds = n; args.removeFirst() }
    case "--mt-probe": mtProbe = true
    case "--touch-probe": touchProbe = true
    case "--skip-reenumerate": mtOptions.reenumerate = false
    case "--mt-sequence":
        let v = next()
        guard MultitouchSequence(rawValue: v) != nil else { print("Unknown sequence: \(v)"); exit(1) }
        settings.mtSequence = v
    case "--no-seize": settings.seize = false
    case "--no-suppress": settings.suppressSystemPointer = false
    case "--seize-touch-only": settings.seizeTouchOnly = true
    case "--one-finger-scroll": settings.oneFingerScroll = true
    case "--key-zoom": settings.nativeZoom = false
    case "--no-momentum": settings.momentumScroll = false
    case "--show-pointer": settings.hidePointer = false
    case "--rotate": settings.rotation = Int(next()) ?? 0
    case "--swap-xy": settings.swapXY = true
    case "--flip-x": settings.flipX = true
    case "--flip-y": settings.flipY = true
    case "--invert-scroll": settings.invertScroll = true
    case "--scroll-gain": settings.scrollGain = Double(next()) ?? 1.0
    case "--vid": settings.vid = parseInt(next())
    case "--pid": settings.pid = parseInt(next())
    case "--midi": settings.mode = .midi
    case "--digitizer": settings.output = .digitizer
    case "--digitizer-space":
        switch next() {
        case "main": settings.digitizerSpace = .mainDisplay
        case "all": settings.digitizerSpace = .allDisplays
        default: settings.digitizerSpace = .touchDisplay
        }
    case "--layout":
        let v = next()
        guard let l = MIDILayoutPreset(rawValue: v) else { print("Unknown layout: \(v) (mixer|keyboard|performance)"); exit(1) }
        settings.midiLayout = l
    case "--no-mpe": settings.mpe = false
    case "--channel": settings.midiChannel = max(1, min(16, Int(next()) ?? 1))
    case "--base-note": settings.baseNote = max(0, min(108, Int(next()) ?? 48))
    case "--scale":
        let v = next()
        guard let sc = Scale(rawValue: v) else { print("Unknown scale: \(v)"); exit(1) }
        settings.scale = sc
    case "--bend-range": settings.bendRange = max(1, min(96, Int(next()) ?? 48))
    case "--brightness", "--contrast", "--volume": ddcSet.append((String(a.dropFirst(2)), Int(next()) ?? -1))
    case "--get": ddcGet.append(next())
    case "-h", "--help": printUsage(); exit(0)
    default: print("Unknown option: \(a)"); printUsage(); exit(1)
    }
}

let displays = Displays.all()
if let i = displayIndex, i >= 0, i < displays.count { settings.displayID = displays[i].id }

if listDisplays {
    for (i, d) in displays.enumerated() {
        print("[\(i)] id=\(d.id) \(d.name) \(Int(d.bounds.width))x\(Int(d.bounds.height)) @ (\(Int(d.bounds.minX)),\(Int(d.bounds.minY)))"
              + (d.isBuiltin ? " built-in" : " external") + (d.isMain ? " (main display)" : ""))
    }
    exit(0)
}

if checkUpdate {
    let cur = Updater.currentVersion
    print("Installed: \(cur)")
    Updater().check(includePrereleases: true, skipped: nil, current: cur) { r in
        switch r {
        case .success(let rel?):
            print("Update available: \(rel.versionString)" + (rel.prerelease ? " (pre-release)" : ""))
            if let a = UpdateLogic.dmgAsset(rel) { print("DMG: \(a.browserDownloadURL)") }
            if let h = rel.htmlURL { print("Release: \(h)") }
            print("To install: menu bar › Updates › Check for updates …")
            exit(0)
        case .success(nil): print("No update – up to date."); exit(0)
        case .failure(let e): print("❌ \(e.localizedDescription)"); exit(1)
        }
    }
    RunLoop.main.run()
}

if let secs = diagnoseSeconds {
    print("Input Monitoring: \(Permissions.inputMonitoringState)")
    if !Permissions.inputMonitoring { Permissions.requestInputMonitoring() }
    for l in SystemCheck.diagnosisLines(vid: settings.vid ?? HIDProbe.anmiteVID, pid: settings.pid ?? HIDProbe.anmitePID,
                                        bundle: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()) { print(l) }
    let probe = HIDProbe(vid: settings.vid ?? HIDProbe.anmiteVID, pid: settings.pid ?? HIDProbe.anmitePID) { print($0) }
    probe.run(seconds: secs) { s in exit(s.interfaces == 0 ? 4 : (s.reports == 0 ? 5 : 0)) }
    RunLoop.main.run()
}

if touchProbe {
    if !Permissions.accessibility { print("⚠️  Accessibility / Device control is missing – posted events may be dropped.") }
    let target = Displays.resolve(settings.displayID)
    var lines = ["touchbridge CLI \(Updater.currentVersion)"]
    let probe = RealTouchProbe(display: target) { line in print(line); lines.append(line) }
    print("Do not touch mouse or screen for about 20 s.")
    probe.run {
        RealTouchProbe.append(lines)
        print("Appended to \(RealTouchProbe.resultsURL.path)")
        exit(0)
    }
    withExtendedLifetime(probe) { RunLoop.main.run() }
}

if mtProbe {
    print("Input Monitoring: \(Permissions.inputMonitoringState)")
    if !Permissions.inputMonitoring { Permissions.requestInputMonitoring() }
    let svc = TouchService(settings: settings)
    svc.log = { print($0) }
    svc.start()
    guard svc.status.running else { print("❌ Touch service does not start"); exit(2) }
    svc.muted = true
    print("Starting shortly: please keep tapping/swiping with 2 fingers on the Anmite for about 40 s.")
    var experiment: MultitouchExperiment?
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        let e = MultitouchExperiment(service: svc, options: mtOptions) { print($0) }
        experiment = e
        e.run { seq in
            if let seq = seq {
                print("Sequence: \(seq.rawValue) – the app saves it via the menu; in the CLI use: --mt-sequence \(seq.rawValue)")
            }
            svc.stop()
            exit(seq == nil ? 6 : 0)
        }
    }
    withExtendedLifetime(experiment) {}
    RunLoop.main.run()
}

if !ddcGet.isEmpty || !ddcSet.isEmpty {
    let ctl = DisplayControl(display: Displays.resolve(settings.displayID))
    guard ctl.hasDDC else {
        print("❌ Display does not respond to DDC (or Intel Mac: not supported there yet).")
        for l in ctl.probeDetails { print("   " + l) }
        exit(3)
    }
    func feature(_ s: String) -> DisplayControl.Feature? {
        ["brightness": .brightness, "contrast": .contrast, "volume": .volume][s]
    }
    var pending = ddcGet.count
    for (name, v) in ddcSet {
        guard let f = feature(name), (0...100).contains(v) else { print("Invalid: --\(name) \(v)"); exit(1) }
        ctl.set(f, percent: v)
        print("\(f.title) -> \(v) %")
    }
    for name in ddcGet {
        guard let f = feature(name) else { print("Unknown: \(name)"); exit(1) }
        ctl.read(f) { v in
            print("\(f.title): " + (v.map { "\($0) %" } ?? "not supported"))
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
        print("⚠️  Please grant access under " + PermissionTexts.accessibilityPath + " and restart.")
    }
}
if !Permissions.inputMonitoring {
    Permissions.requestInputMonitoring()
    print("⚠️  If needed, allow access under Privacy & Security › Input Monitoring and restart.")
}
service.start()
guard service.status.running else { exit(2) }
let b = CGDisplayBounds(service.targetDisplay)
print("🖥  Target display: \(Int(b.width))x\(Int(b.height)) @ (\(Int(b.minX)),\(Int(b.minY)))")
if settings.mode == .midi && !dump {
    print("🎛  MIDI mode – layout \(settings.midiLayout.title), " + (settings.mpe ? "MPE" : "channel \(settings.midiChannel)")
          + ", MIDI port \"TouchBridge\".")
    for (i, z) in settings.midiLayoutModel.zones.enumerated() {
        print(String(format: "   [%2d] %@  x %.2f–%.2f  y %.2f–%.2f", i, z.name, z.rect.x, z.rect.maxX, z.rect.y, z.rect.maxY))
    }
}
print(dump ? "Dump mode – touch the screen. Ctrl+C quits." : "Running. Ctrl+C quits.")
// Ctrl+C: end sounding notes before the process (and with it the MIDI port) goes away
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { service.stop(); exit(0) }   // release the device (undo seize)
    src.resume()
    signalSources.append(src)
}
CFRunLoopRun()

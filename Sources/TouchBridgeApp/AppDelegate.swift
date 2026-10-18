import AppKit
import ServiceManagement
import TouchBridgeCore
import TouchBridgeKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var service: TouchService!
    private var settings = SettingsStore.load() {
        didSet { SettingsStore.save(settings); service.settings = settings; refreshControl(); updateOverlay(); updateIcon() }
    }
    private let overlay = MIDIOverlay()
    private var control: DisplayControl?
    private var controlDisplay: CGDirectDisplayID = 0
    private var ddcValues: [DisplayControl.Feature: Int] = [:]
    private var logLines: [String] = []
    private var diagnosing = false

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: - Start

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        service = TouchService(settings: settings)
        service.log = { [weak self] line in self?.appendLog(line) }
        service.onStatus = { [weak self] _ in self?.updateIcon() }
        service.onMIDIUpdate = { [weak self] in self?.refreshOverlayContent() }

        if !Permissions.accessibility { Permissions.requestAccessibility() }
        if !Permissions.inputMonitoring { Permissions.requestInputMonitoring() }
        service.start()
        updateIcon()
        refreshControl()
        updateOverlay()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        service.stop()
        DisplayControl.restoreAllGamma()
    }

    @objc private func screensChanged() {
        refreshControl()
        updateIcon()
        updateOverlay()
    }

    // MARK: - MIDI-Overlay

    /// Overlay nur im MIDI-Modus (und wenn eingeschaltet) auf dem Touch-Bildschirm zeigen.
    private func updateOverlay() {
        if settings.enabled && settings.mode == .midi && settings.showOverlay {
            overlay.show(on: Displays.resolve(settings.displayID))
            refreshOverlayContent()
        } else {
            overlay.hide()
        }
    }

    private func refreshOverlayContent() {
        guard overlay.isVisible else { return }
        overlay.update(layout: service.midiEngine?.layout ?? settings.midiLayoutModel, engine: service.midiEngine)
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let st = service.status
        let symbol: String
        if !settings.enabled { symbol = "hand.raised.slash" }
        else if settings.mode == .midi { symbol = "pianokeys" }
        else if st.running && !st.devices.isEmpty { symbol = "hand.point.up.left.fill" }
        else { symbol = "hand.point.up.left" }
        if #available(macOS 11.0, *) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TouchBridge")
        } else {
            button.title = "TB"
        }
        button.toolTip = "TouchBridge – " + statusText
    }

    private var statusText: String {
        let st = service.status
        if !settings.enabled { return "Touch aus" }
        if let e = st.lastError { return e }
        if st.devices.isEmpty { return "Kein Touch-Monitor gefunden" }
        return st.devices.joined(separator: ", ") + (st.exclusive ? "" : " (nicht exklusiv)")
            + (settings.mode == .midi ? " – MIDI" : "")
    }

    // MARK: - Bildsteuerung

    private func refreshControl() {
        let target = Displays.resolve(settings.displayID)
        guard target != controlDisplay || control == nil else { return }
        controlDisplay = target
        control = nil
        ddcValues = [:]
        DispatchQueue.global(qos: .userInitiated).async {
            let ctl = DisplayControl(display: target)
            DispatchQueue.main.async {
                guard self.controlDisplay == target else { return }
                self.control = ctl
                let sw = SettingsStore.softwareBrightness
                if sw < 0.999 { ctl.setSoftwareBrightness(sw) }
                if ctl.hasDDC {
                    for f in DisplayControl.Feature.allCases {
                        ctl.read(f) { v in self.ddcValues[f] = v ?? -1 }
                    }
                }
            }
        }
    }

    // MARK: - Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let head = NSMenuItem(title: "TouchBridge \(AppDelegate.version)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let st = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        menu.addItem(toggle("Touch aktiv", settings.enabled, #selector(toggleEnabled), key: "t"))
        menu.addItem(.separator())

        // Modus
        menu.addItem(sectionHeader("Modus"))
        for (i, m) in InputMode.allCases.enumerated() {
            menu.addItem(toggle(m.title, settings.mode == m, #selector(selectMode(_:)), tag: i))
        }
        menu.addItem(submenu("MIDI-Einstellungen", midiMenu()))
        menu.addItem(.separator())

        // Bild
        menu.addItem(sectionHeader("Bild"))
        if let ctl = control {
            if ctl.hasDDC {
                for f in DisplayControl.Feature.allCases {
                    let v = ddcValues[f]
                    let supported = v != -1
                    let view = SliderItemView(title: f.title + (supported ? "" : " (nicht unterstützt)"),
                                              symbol: symbol(for: f), value: max(0, v ?? 50), enabled: supported && v != nil)
                    view.onChange = { [weak self] p in self?.ddcValues[f] = p; ctl.set(f, percent: p) }
                    let item = NSMenuItem(); item.view = view
                    menu.addItem(item)
                }
            } else {
                let note = NSMenuItem(title: "Monitor antwortet nicht auf DDC – Software-Dimmen", action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
            let swView = SliderItemView(title: ctl.hasDDC ? "Zusätzlich abdunkeln (Software)" : "Helligkeit (Software)",
                                        symbol: "moon", value: Int((ctl.softwareBrightness * 100).rounded()))
            swView.slider.minValue = 20
            swView.onChange = { p in
                ctl.setSoftwareBrightness(Double(p) / 100)
                SettingsStore.softwareBrightness = Double(p) / 100
            }
            let swItem = NSMenuItem(); swItem.view = swView
            menu.addItem(swItem)
        } else {
            let wait = NSMenuItem(title: "Bildschirm wird abgefragt …", action: nil, keyEquivalent: "")
            wait.isEnabled = false
            menu.addItem(wait)
        }
        menu.addItem(.separator())

        // Touch-Einstellungen
        menu.addItem(sectionHeader("Touch"))
        menu.addItem(submenu("Bildschirm", displayMenu()))
        menu.addItem(submenu("Ausrichtung", orientationMenu()))
        menu.addItem(submenu("Scrollen", scrollMenu()))
        menu.addItem(toggle("Exklusiv übernehmen (empfohlen)", settings.seize, #selector(toggleSeize)))
        menu.addItem(.separator())

        // System
        menu.addItem(submenu("Berechtigungen", permissionsMenu()))
        if #available(macOS 13.0, *) {
            menu.addItem(toggle("Beim Anmelden starten", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        }
        menu.addItem(action(diagnosing ? "Diagnose läuft – Bildschirm berühren …" : "Diagnose aufzeichnen (10 s Touch)", #selector(runDiagnosis), enabled: !diagnosing))
        menu.addItem(action("Kommandozeilen-Tool installieren …", #selector(installCLI)))
        menu.addItem(action("Hilfe & Updates", #selector(openHelp)))
        menu.addItem(.separator())
        menu.addItem(action("TouchBridge beenden", #selector(quit), key: "q"))
    }

    private func symbol(for f: DisplayControl.Feature) -> String {
        switch f {
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .volume: return "speaker.wave.2"
        }
    }

    private func sectionHeader(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor])
        i.isEnabled = false
        return i
    }

    private func action(_ t: String, _ sel: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
        i.target = self
        i.isEnabled = enabled
        return i
    }

    private func toggle(_ t: String, _ on: Bool, _ sel: Selector, key: String = "", tag: Int = 0) -> NSMenuItem {
        let i = action(t, sel, key: key)
        i.state = on ? .on : .off
        i.tag = tag
        return i
    }

    private func submenu(_ t: String, _ m: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        m.autoenablesItems = false
        i.submenu = m
        return i
    }

    private func displayMenu() -> NSMenu {
        let m = NSMenu()
        let current = Displays.resolve(settings.displayID)
        m.addItem(toggle("Automatisch (erster externer)", settings.displayID == nil, #selector(selectDisplay(_:)), tag: 0))
        for d in Displays.all() {
            let i = toggle(d.summary, settings.displayID == d.id, #selector(selectDisplay(_:)), tag: Int(d.id))
            if settings.displayID == nil && d.id == current { i.state = .mixed }
            m.addItem(i)
        }
        return m
    }

    private func orientationMenu() -> NSMenu {
        let m = NSMenu()
        for r in [0, 90, 180, 270] {
            m.addItem(toggle(r == 0 ? "Normal" : "\(r)° gedreht", settings.rotation == r, #selector(selectRotation(_:)), tag: r))
        }
        m.addItem(.separator())
        m.addItem(toggle("Horizontal spiegeln", settings.flipX, #selector(toggleFlipX)))
        m.addItem(toggle("Vertikal spiegeln", settings.flipY, #selector(toggleFlipY)))
        return m
    }

    private func scrollMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(toggle("Richtung umkehren", settings.invertScroll, #selector(toggleInvert)))
        m.addItem(.separator())
        for (name, g) in [("Langsam", 0.6), ("Normal", 1.0), ("Schnell", 1.6), ("Sehr schnell", 2.4)] {
            m.addItem(toggle(name, abs(settings.scrollGain - g) < 0.01, #selector(selectGain(_:)), tag: Int(g * 10)))
        }
        return m
    }

    private func midiMenu() -> NSMenu {
        let m = NSMenu()
        let layout = NSMenu()
        for (i, p) in MIDILayoutPreset.allCases.enumerated() {
            layout.addItem(toggle(p.title, settings.midiLayout == p, #selector(selectLayout(_:)), tag: i))
        }
        m.addItem(submenu("Layout: " + settings.midiLayout.title, layout))
        m.addItem(toggle("MPE (Kanal 1 Master, 2–16 pro Note)", settings.mpe, #selector(toggleMPE)))

        let ch = NSMenu()
        for c in 1...16 { ch.addItem(toggle("Kanal \(c)", settings.midiChannel == c, #selector(selectChannel(_:)), tag: c)) }
        let chItem = submenu("MIDI-Kanal: \(settings.midiChannel)" + (settings.mpe ? " (nur ohne MPE)" : ""), ch)
        m.addItem(chItem)

        let base = NSMenu()
        for n in stride(from: 24, through: 84, by: 12) {
            base.addItem(toggle(midiNoteName(n), settings.baseNote == n, #selector(selectBaseNote(_:)), tag: n))
        }
        base.addItem(.separator())
        base.addItem(action("Einen Halbton höher", #selector(baseNoteUp), enabled: settings.baseNote < 108))
        base.addItem(action("Einen Halbton tiefer", #selector(baseNoteDown), enabled: settings.baseNote > 0))
        m.addItem(submenu("Grundnote: " + midiNoteName(settings.baseNote), base))

        let sc = NSMenu()
        for (i, s) in Scale.allCases.enumerated() {
            sc.addItem(toggle(s.title, settings.scale == s, #selector(selectScale(_:)), tag: i))
        }
        m.addItem(submenu("Skala (Keyboard): " + settings.scale.title, sc))

        let br = NSMenu()
        for r in [2, 12, 24, 48] {
            br.addItem(toggle("±\(r) Halbtöne", settings.bendRange == r, #selector(selectBendRange(_:)), tag: r))
        }
        m.addItem(submenu("Pitch-Bend-Bereich (MPE): ±\(settings.bendRange)", br))
        m.addItem(.separator())
        m.addItem(toggle("Layout auf dem Touch-Bildschirm anzeigen", settings.showOverlay, #selector(toggleOverlay)))
        let port = NSMenuItem(title: "MIDI-Port: „TouchBridge“", action: nil, keyEquivalent: "")
        port.isEnabled = false
        m.addItem(port)
        return m
    }

    private func permissionsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(toggle("Bedienungshilfen" + (Permissions.accessibility ? "" : " – fehlt"),
                         Permissions.accessibility, #selector(openAccessibility)))
        m.addItem(toggle("Eingabeüberwachung" + (Permissions.inputMonitoring ? "" : " – fehlt"),
                         Permissions.inputMonitoring, #selector(openInputMonitoring)))
        m.addItem(.separator())
        m.addItem(action("Touch neu starten", #selector(restartService)))
        return m
    }

    // MARK: - Aktionen

    @objc private func toggleEnabled() { settings.enabled.toggle(); updateIcon() }
    @objc private func toggleSeize() { settings.seize.toggle() }
    @objc private func toggleFlipX() { settings.flipX.toggle() }
    @objc private func toggleFlipY() { settings.flipY.toggle() }
    @objc private func toggleInvert() { settings.invertScroll.toggle() }
    @objc private func selectRotation(_ s: NSMenuItem) { settings.rotation = s.tag }
    @objc private func selectGain(_ s: NSMenuItem) { settings.scrollGain = Double(s.tag) / 10 }
    @objc private func selectDisplay(_ s: NSMenuItem) { settings.displayID = s.tag == 0 ? nil : UInt32(s.tag) }
    @objc private func selectMode(_ s: NSMenuItem) {
        let m = InputMode.allCases[s.tag]
        if m == .gestures, !Permissions.accessibility { Permissions.requestAccessibility() }
        settings.mode = m
    }
    @objc private func selectLayout(_ s: NSMenuItem) { settings.midiLayout = MIDILayoutPreset.allCases[s.tag] }
    @objc private func toggleMPE() { settings.mpe.toggle() }
    @objc private func selectChannel(_ s: NSMenuItem) { settings.midiChannel = s.tag }
    @objc private func selectBaseNote(_ s: NSMenuItem) { settings.baseNote = s.tag }
    @objc private func baseNoteUp() { settings.baseNote = min(108, settings.baseNote + 1) }
    @objc private func baseNoteDown() { settings.baseNote = max(0, settings.baseNote - 1) }
    @objc private func selectScale(_ s: NSMenuItem) { settings.scale = Scale.allCases[s.tag] }
    @objc private func selectBendRange(_ s: NSMenuItem) { settings.bendRange = s.tag }
    @objc private func toggleOverlay() { settings.showOverlay.toggle() }

    @objc private func restartService() {
        service.stop(); service.start(); updateIcon()
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Autostart konnte nicht geändert werden", error.localizedDescription)
        }
    }

    @objc private func openAccessibility() {
        Permissions.requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openInputMonitoring() {
        Permissions.requestInputMonitoring()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/thegroovex/Touchbridge#readme")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// 10 Sekunden Dump-Modus: Descriptor + Kontakte werden gesammelt, in die Zwischenablage
    /// kopiert und als Textdatei auf dem Schreibtisch gespeichert.
    @objc private func runDiagnosis() {
        diagnosing = true
        logLines.removeAll()
        appendLog("TouchBridge \(AppDelegate.version) – Diagnose \(Date())")
        appendLog("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        for (i, d) in Displays.all().enumerated() {
            appendLog("[\(i)] \(d.summary) id=\(d.id) @ (\(Int(d.bounds.minX)),\(Int(d.bounds.minY)))" + (d.isBuiltin ? " intern" : " extern"))
        }
        appendLog("DDC: " + ((control?.hasDDC ?? false) ? "ja" : "nein")
                  + "  Bedienungshilfen: \(Permissions.accessibility)  Eingabeüberwachung: \(Permissions.inputMonitoring)")
        service.stop()
        service.dumpMode = true
        service.start()
        statusItem.button?.title = " REC"
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            self.service.stop()
            self.service.dumpMode = false
            self.service.start()
            self.diagnosing = false
            self.statusItem.button?.title = ""
            let text = self.logLines.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TouchBridge-Diagnose.txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            self.alert("Diagnose fertig", "In die Zwischenablage kopiert und als „TouchBridge-Diagnose.txt“ auf dem Schreibtisch gespeichert.")
        }
    }

    /// Verlinkt das CLI aus dem App-Bundle nach /usr/local/bin/touchbridge (fragt nach dem Admin-Passwort).
    @objc private func installCLI() {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/touchbridge").path
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            alert("Nicht gefunden", "Das Kommandozeilen-Tool fehlt im App-Bundle."); return
        }
        let cmd = "mkdir -p /usr/local/bin && ln -sf '\(cli)' /usr/local/bin/touchbridge"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let e = err {
            if (e[NSAppleScript.errorNumber] as? Int) != -128 {
                alert("Installation fehlgeschlagen", (e[NSAppleScript.errorMessage] as? String) ?? "\(e)")
            }
        } else {
            alert("Installiert", "Im Terminal steht jetzt „touchbridge“ bereit, z. B. touchbridge --dump.")
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

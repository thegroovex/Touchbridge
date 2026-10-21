import AppKit
import TouchBridgeUSB
import ServiceManagement
import TouchBridgeCore
import TouchBridgeKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var service: TouchService!
    private var settings = SettingsStore.load() {
        didSet { SettingsStore.save(settings); applyEffective(); refreshControl(); updateOverlay(); updateIcon(); settingsWindow?.sync(settings) }
    }
    /// App profiles (0.4 phase 3); global `settings` = default profile
    private var profiles = SettingsStore.loadProfiles() {
        didSet {
            guard profiles != oldValue else { return }
            SettingsStore.saveProfiles(profiles)
            applyEffective()
            settingsWindow?.syncProfiles(profiles)
        }
    }
    /// Bundle ID of the frontmost app (other than TouchBridge itself)
    private var frontmostBundleID: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    /// Name of the profile last applied (for the log)
    private var lastProfileID: UUID??
    /// Global settings with the active profile applied – what the touch service and interaction use
    private var effectiveSettings: TouchSettings {
        profiles.effective(settings, frontmostBundleID: frontmostBundleID)
    }
    /// Settings window (created on first use)
    private var settingsWindow: SettingsWindowController?
    /// Touch context menu + smart target (GestureEngine delegate; the service only holds it weakly)
    private var interaction: TouchInteraction?
    private let overlay = MIDIOverlay()
    private var control: DisplayControl?
    private var controlDisplay: CGDirectDisplayID = 0
    private var ddcValues: [DisplayControl.Feature: Int] = [:]
    private var logLines: [String] = []
    private var diagnosing = false
    private var probe: HIDProbe?
    private var experiment: MultitouchExperiment?
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionTimer: Timer?
    private var hadInputMonitoring = Permissions.inputMonitoring
    private var hadAccessibility = Permissions.accessibility
    private lazy var updater = Updater { [weak self] in self?.appendLog($0) }
    private var availableUpdate: ReleaseInfo?
    private var updateBusy = false
    private var updateTimer: Timer?
    private lazy var touchTest = TouchTestController()
    private var realTouchProbe: RealTouchProbe?

    static var version: String {
        Updater.currentVersion
    }

    // MARK: - Start

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        if frontmostBundleID == Bundle.main.bundleIdentifier { frontmostBundleID = nil }
        service = TouchService(settings: effectiveSettings)
        service.log = { [weak self] line in self?.appendLog(line) }
        service.onStatus = { [weak self] _ in self?.updateIcon() }
        service.onMIDIUpdate = { [weak self] in self?.refreshOverlayContent() }
        let ti = TouchInteraction(settings: { [weak self] in self?.effectiveSettings ?? TouchSettings() },
                                  log: { [weak self] line in self?.appendLog(line) })
        interaction = ti
        service.gestureDelegate = ti
        installMainMenu()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        logActiveProfile()

        // Dialoge nur EINMAL (gemerkt); danach nur Hinweis im Menü – kein Prompt bei jedem Start
        Permissions.requestAccessibilityOnce()
        Permissions.requestInputMonitoringOnce()
        service.start()
        updateIcon()
        refreshControl()
        updateOverlay()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Beenden per kill/Abmelden: Gerät sauber schließen (Seize freigeben), sonst bleibt es bis zum Abstecken belegt
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.shutdown(); exit(0) }
            src.resume()
            signalSources.append(src)
        }

        // Eingabeüberwachung beobachten: sobald erteilt, Touch neu starten
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = Permissions.inputMonitoring
            if now != self.hadInputMonitoring {
                self.hadInputMonitoring = now
                self.appendLog("🔐 Input Monitoring now: \(Permissions.inputMonitoringState)")
                if now { self.restartService() } else { self.updateIcon() }
            }
            let ax = Permissions.accessibility
            if ax != self.hadAccessibility {
                self.hadAccessibility = ax
                self.appendLog("🔐 \(PermissionTexts.accessibilityName) now: \(ax ? "granted" : "missing")")
                self.updateIcon()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t

        // Updates: kurz nach dem Start und dann stündlich prüfen, ob die 24 h um sind
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.autoCheckForUpdates() }
        let u = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.autoCheckForUpdates() }
        RunLoop.main.add(u, forMode: .common)
        updateTimer = u
    }

    // MARK: - Updates

    private func autoCheckForUpdates() {
        guard SettingsStore.autoUpdateCheck, !updateBusy,
              UpdateLogic.isCheckDue(lastCheck: SettingsStore.lastUpdateCheck, now: Date()) else { return }
        checkForUpdates(interactive: false)
    }

    @objc private func checkForUpdatesAction() { checkForUpdates(interactive: true) }

    private func checkForUpdates(interactive: Bool) {
        guard !updateBusy else { return }
        updateBusy = true
        updater.check(includePrereleases: SettingsStore.includePrereleases,
                      skipped: interactive ? nil : SettingsStore.skippedVersion,
                      includeBetas: SettingsStore.includeBetas) { [weak self] result in
            guard let self = self else { return }
            self.updateBusy = false
            switch result {
            case .success(let r):
                SettingsStore.lastUpdateCheck = Date()
                self.availableUpdate = r
                self.updateIcon()
                if let r = r {
                    if interactive || SettingsStore.skippedVersion != r.versionString { self.offerUpdate(r) }
                } else if interactive {
                    self.alert(L("No update", "Kein Update"), L("TouchBridge \(Updater.currentVersion) is up to date.", "TouchBridge \(Updater.currentVersion) ist aktuell."))
                }
            case .failure(let e):
                self.appendLog("⚠️  Update check: \(e.localizedDescription)")
                if interactive { self.alert(L("Update check failed", "Update-Prüfung fehlgeschlagen"), e.localizedDescription) }
            }
        }
    }

    @objc private func showAvailableUpdate() { if let r = availableUpdate { offerUpdate(r) } }

    private func offerUpdate(_ r: ReleaseInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("TouchBridge \(r.versionString) is available", "TouchBridge \(r.versionString) ist verfügbar") + (r.prerelease ? L(" (pre-release)", " (Vorabversion)") : "")
        var notes = (r.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 1500 { notes = String(notes.prefix(1500)) + " …" }
        a.informativeText = L("Installed: \(Updater.currentVersion)\n\n", "Installiert: \(Updater.currentVersion)\n\n") + (notes.isEmpty ? L("No release notes.", "Keine Release-Notes.") : notes)
        a.addButton(withTitle: L("Install now", "Jetzt installieren"))
        a.addButton(withTitle: L("Later", "Später"))
        a.addButton(withTitle: L("Skip this version", "Diese Version überspringen"))
        switch a.runModal() {
        case .alertFirstButtonReturn: install(r)
        case .alertThirdButtonReturn:
            SettingsStore.skippedVersion = r.versionString
            availableUpdate = nil
            updateIcon()
        default: break
        }
    }

    private func install(_ r: ReleaseInfo) {
        updateBusy = true
        statusItem.button?.title = " ⬇︎"
        let target = Bundle.main.bundleURL
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let newApp = try self.updater.prepare(r)
                DispatchQueue.main.async {
                    do {
                        // HID-Gerät (Seize) und Gamma sauber freigeben, bevor die App ersetzt und neu gestartet wird
                        self.shutdown()
                        try self.updater.install(newApp: newApp, over: target)
                        Updater.relaunch(target)
                        NSApp.terminate(nil)
                    } catch {
                        self.updateBusy = false
                        self.statusItem.button?.title = ""
                        self.service.start()
                        self.alert(L("Update failed", "Update fehlgeschlagen"), error.localizedDescription)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateBusy = false
                    self.statusItem.button?.title = ""
                    self.updateIcon()
                    self.alert(L("Update failed", "Update fehlgeschlagen"), error.localizedDescription)
                }
            }
        }
    }

    @objc private func toggleAutoUpdate() { SettingsStore.autoUpdateCheck.toggle() }
    @objc private func togglePrereleases() { SettingsStore.includePrereleases.toggle() }
    @objc private func toggleBetas() { SettingsStore.includeBetas.toggle() }

    private func updatesMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(action(updateBusy ? L("Checking …", "Suche läuft …") : L("Check for updates …", "Nach Updates suchen …"), #selector(checkForUpdatesAction), enabled: !updateBusy))
        m.addItem(toggle(L("Check automatically (at launch and daily)", "Automatisch prüfen (beim Start und täglich)"), SettingsStore.autoUpdateCheck, #selector(toggleAutoUpdate)))
        m.addItem(toggle(L("Include pre-releases", "Vorabversionen einbeziehen"), SettingsStore.includePrereleases, #selector(togglePrereleases)))
        m.addItem(toggle(L("Include beta versions (e.g. 0.4.0-beta1)", "Beta-Versionen einbeziehen (z. B. 0.4.0-beta1)"), SettingsStore.includeBetas, #selector(toggleBetas)))
        if let d = SettingsStore.lastUpdateCheck {
            let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
            let i = NSMenuItem(title: L("Last checked: ", "Zuletzt geprüft: ") + f.string(from: d), action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        let v = NSMenuItem(title: L("Installed: \(Updater.currentVersion)", "Installiert: \(Updater.currentVersion)"), action: nil, keyEquivalent: "")
        v.isEnabled = false
        m.addItem(v)
        return m
    }

    func applicationWillTerminate(_ notification: Notification) { shutdown() }

    private func shutdown() {
        probe?.close(); probe = nil
        service.stop()
        DisplayControl.restoreAllGamma()
    }

    @objc private func screensChanged() {
        refreshControl()
        updateIcon()
        updateOverlay()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // DDC antwortet manchmal erst verzögert (Monitor/DCP noch nicht bereit): beim Öffnen erneut proben
        if let ctl = control, !ctl.probeOK, !ctl.probing { reprobeDDC(ctl) }
    }

    private func reprobeDDC(_ ctl: DisplayControl) {
        ctl.probe { [weak self] ok in
            guard let self = self, self.control === ctl else { return }
            if ok || ctl.hasDDC { self.readDDCValues(ctl) }
        }
    }

    private func readDDCValues(_ ctl: DisplayControl) {
        for f in DisplayControl.Feature.allCases {
            ctl.read(f) { [weak self] v in
                guard let self = self else { return }
                // Wert behalten, wenn eine Leseprobe fehlschlägt, aber früher einer da war
                if let v = v { self.ddcValues[f] = v } else if self.ddcValues[f] == nil { self.ddcValues[f] = -1 }
                self.menuNeedsUpdate(self.menu)
            }
        }
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

    /// Menüleisten-Glyph aus dem App-Bundle (Resources/MenuBarIcon.png + @2x), als Template-Bild,
    /// damit macOS es in heller/dunkler Menüleiste passend einfärbt. nil außerhalb eines App-Bundles.
    private lazy var menuBarGlyph: NSImage? = {
        guard let img = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        img.accessibilityDescription = "TouchBridge"
        return img
    }()

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let st = service.status
        let problem = service.inputMonitoringState.isProblem || st.lastError != nil
        if settings.enabled && !problem, let glyph = menuBarGlyph {
            // Multitouch-Glyph (App-Icon-Motiv); „verbunden“ voll, „wartet auf Gerät“ gedimmt
            button.image = glyph
            button.appearsDisabled = !(st.running && !st.devices.isEmpty) && settings.mode != .midi
        } else if #available(macOS 11.0, *) {
            button.appearsDisabled = false
            let symbol: String
            if !settings.enabled { symbol = "hand.raised.slash" }
            else if problem { symbol = "exclamationmark.triangle" }
            else if settings.mode == .midi { symbol = "pianokeys" }
            else if st.running && !st.devices.isEmpty { symbol = "hand.point.up.left.fill" }
            else { symbol = "hand.point.up.left" }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TouchBridge")
        } else {
            button.title = "TB"
        }
        // Punkt in der Menüleiste, wenn ein Update bereitsteht
        if !updateBusy && !diagnosing { button.title = availableUpdate != nil ? "•" : "" }
        button.toolTip = "TouchBridge – " + statusText + (availableUpdate.map { L(" – update \($0.versionString) available", " – Update \($0.versionString) verfügbar") } ?? "")
    }

    private var statusText: String {
        let st = service.status
        if !settings.enabled { return L("Touch off", "Touch aus") }
        let im = service.inputMonitoringState
        if im.isProblem { return im.statusText }
        if let e = st.lastError { return e }
        if st.devices.isEmpty { return L("Touch monitor not connected", "Touch-Monitor nicht angeschlossen") }
        return st.devices.joined(separator: ", ") + (st.exclusive ? L(" – exclusive", " – exklusiv") : L(" – not exclusive", " – nicht exklusiv"))
            + (st.source == .singleTouchPointer ? " – " + st.source.title : "")
            + (settings.mode == .midi ? " – MIDI" : "")
    }

    // MARK: - Bildsteuerung

    private func refreshControl() {
        let target = service.targetDisplay
        guard target != controlDisplay || control == nil else {
            // gleicher Bildschirm, aber neu konfiguriert: DDC erneut proben, falls es zuletzt nicht antwortete
            if let ctl = control, !ctl.probeOK, !ctl.probing { reprobeDDC(ctl) }
            return
        }
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
                if ctl.hasDDC { self.readDDCValues(ctl) }
                if !ctl.probeOK {
                    // verzögert erneut versuchen (Monitor nach Start/Anstecken noch nicht bereit)
                    for delay in [3.0, 10.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self = self, self.control === ctl, !ctl.probeOK, !ctl.probing else { return }
                            self.reprobeDDC(ctl)
                        }
                    }
                }
            }
        }
    }

    @objc private func reprobeDDCAction() {
        if let ctl = control { reprobeDDC(ctl) } else { refreshControl() }
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
        if let u = availableUpdate {
            let i = action(L("● Update to \(u.versionString) available …", "● Update auf \(u.versionString) verfügbar …"), #selector(showAvailableUpdate))
            i.attributedTitle = NSAttributedString(string: i.title, attributes: [.foregroundColor: NSColor.systemBlue,
                                                                                 .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            menu.addItem(i)
        }
        let im = service.inputMonitoringState
        if im.isProblem {
            menu.addItem(warning(im == .notDetermined ? L("⚠️ Input Monitoring not allowed yet – no touch data arrives", "⚠️ Eingabeüberwachung noch nicht erlaubt – es kommen keine Touch-Daten an")
                                                      : L("⚠️ \(im.statusText) – no touch data arrives", "⚠️ \(im.statusText) – es kommen keine Touch-Daten an"), color: .systemRed, bold: true))
            if im.suggestReset { menu.addItem(warning("   " + PermissionTexts.staleHint, color: .secondaryLabelColor)) }
            menu.addItem(action(L("Open System Settings › Input Monitoring …", "Systemeinstellungen › Eingabeüberwachung öffnen …"), #selector(openInputMonitoring)))
            if im.suggestReset { menu.addItem(action(L("Reset permissions …", "Berechtigungen zurücksetzen …"), #selector(resetPermissions))) }
        }
        if let ax = PermissionTexts.accessibility(trusted: Permissions.accessibility, asked: Permissions.askedAccessibility),
           settings.mode == .gestures {
            menu.addItem(warning("⚠️ " + ax, color: .systemOrange))
            if !im.suggestReset && Permissions.askedAccessibility { menu.addItem(action(L("Reset permissions …", "Berechtigungen zurücksetzen …"), #selector(resetPermissions))) }
        }
        if settings.enabled, !service.status.interfaces.isEmpty {
            menu.addItem(warning(InterfaceStatus.summary(service.status.interfaces), color: .secondaryLabelColor))
            menu.addItem(warning("Reports: " + service.reportSummary, color: .secondaryLabelColor))
            menu.addItem(warning(L("Source: ", "Quelle: ") + service.touchSource.title, color: .secondaryLabelColor))
        }
        if settings.enabled, let e = service.status.seizeError, !service.status.interfaces.isEmpty {
            menu.addItem(warning(L("⚠️ Not exclusive – \(e) – retrying every 2 s", "⚠️ Nicht exklusiv – \(e) – neuer Versuch alle 2 s"), color: .systemOrange))
            if service.status.suppressing {
                menu.addItem(warning(L("   System pointer suppressed via event tap", "   Systemzeiger wird per Event-Tap unterdrückt"), color: .secondaryLabelColor))
            }
        }
        if service.status.legacyAgent || SystemCheck.legacyAgentFilePresent {
            menu.addItem(warning(L("⚠️ Old LaunchAgent com.groovex.touchbridge (v0.1) found", "⚠️ Alter LaunchAgent com.groovex.touchbridge (v0.1) gefunden"), color: .systemOrange))
            menu.addItem(action(L("Remove old LaunchAgent", "Alten LaunchAgent entfernen"), #selector(removeLegacyAgent)))
        }
        menu.addItem(toggle(L("Touch enabled", "Touch aktiv"), settings.enabled, #selector(toggleEnabled), key: "t"))
        menu.addItem(action(L("Settings …", "Einstellungen …"), #selector(openSettings), key: ","))
        menu.addItem(.separator())

        // Modus
        menu.addItem(sectionHeader(L("Mode", "Modus")))
        for (i, m) in InputMode.allCases.enumerated() {
            menu.addItem(toggle(m.title, settings.mode == m, #selector(selectMode(_:)), tag: i))
        }
        menu.addItem(submenu(L("MIDI settings", "MIDI-Einstellungen"), midiMenu()))
        menu.addItem(.separator())

        // Bild
        menu.addItem(sectionHeader(L("Picture", "Bild")))
        if let ctl = control {
            if ctl.hasDDC {
                for f in DisplayControl.Feature.allCases {
                    let v = ddcValues[f]
                    let supported = v != -1
                    let view = SliderItemView(title: f.title + (supported ? "" : L(" (not supported)", " (nicht unterstützt)")),
                                              symbol: symbol(for: f), value: max(0, v ?? 50), enabled: supported && v != nil)
                    view.onChange = { [weak self] p in self?.ddcValues[f] = p; ctl.set(f, percent: p) }
                    let item = NSMenuItem(); item.view = view
                    menu.addItem(item)
                }
            } else {
                let note = NSMenuItem(title: ctl.probing ? L("Checking DDC …", "DDC wird geprüft …") : L("Monitor does not answer DDC – software dimming", "Monitor antwortet nicht auf DDC – Software-Dimmen"),
                                      action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
            let swView = SliderItemView(title: ctl.hasDDC ? L("Extra dimming (software)", "Zusätzlich abdunkeln (Software)") : L("Brightness (software)", "Helligkeit (Software)"),
                                        symbol: "moon", value: Int((ctl.softwareBrightness * 100).rounded()))
            swView.slider.minValue = 20
            swView.onChange = { p in
                ctl.setSoftwareBrightness(Double(p) / 100)
                SettingsStore.softwareBrightness = Double(p) / 100
            }
            let swItem = NSMenuItem(); swItem.view = swView
            menu.addItem(swItem)
            menu.addItem(action(ctl.probing ? L("Checking DDC …", "DDC wird geprüft …") : L("Check DDC again", "DDC erneut prüfen"), #selector(reprobeDDCAction), enabled: !ctl.probing))
        } else {
            let wait = NSMenuItem(title: L("Reading display …", "Bildschirm wird abgefragt …"), action: nil, keyEquivalent: "")
            wait.isEnabled = false
            menu.addItem(wait)
        }
        menu.addItem(.separator())

        // Touch-Einstellungen
        menu.addItem(sectionHeader("Touch"))
        menu.addItem(submenu(L("Screen", "Bildschirm"), displayMenu()))
        menu.addItem(submenu(L("Orientation", "Ausrichtung"), orientationMenu()))
        menu.addItem(submenu(L("Scrolling", "Scrollen"), scrollMenu()))
        menu.addItem(toggle(L("1-finger drag scrolls (instead of pointer/drag)", "1-Finger-Ziehen scrollt (statt Zeiger/Ziehen)"), settings.oneFingerScroll, #selector(toggleOneFingerScroll)))
        menu.addItem(toggle(L("Pinch = trackpad zoom (off: Cmd + / Cmd −)", "Pinch = Trackpad-Zoom (aus: Cmd + / Cmd −)"), settings.nativeZoom, #selector(toggleNativeZoom)))
        menu.addItem(toggle(L("Momentum scrolling", "Scrollen mit Nachlauf (Momentum)"), settings.momentumScroll, #selector(toggleMomentum)))
        menu.addItem(toggle(L("Hide pointer while touching", "Zeiger beim Berühren ausblenden"), settings.hidePointer, #selector(toggleHidePointer)))
        menu.addItem(submenu(L("Gestures", "Gesten"), gesturesMenu()))
        menu.addItem(submenu(profileMenuTitle, profilesMenu()))
        menu.addItem(toggle(L("Exclusive access (recommended)", "Exklusiv übernehmen (empfohlen)"), settings.seize, #selector(toggleSeize)))
        let touchOnly = toggle(L("Exclusive touch interface only (test: mouse/vendor not exclusive)", "Exklusiv nur Touch-Schnittstelle (Test: Maus/Vendor nicht exklusiv)"), settings.seizeTouchOnly,
                               #selector(toggleSeizeTouchOnly))
        touchOnly.isEnabled = settings.seize
        menu.addItem(touchOnly)
        menu.addItem(toggle(L("Suppress system pointer from touch (when not exclusive)", "Systemzeiger vom Touch unterdrücken (wenn nicht exklusiv)"), settings.suppressSystemPointer, #selector(toggleSuppress)))
        menu.addItem(.separator())

        // System
        menu.addItem(submenu(L("Permissions", "Berechtigungen"), permissionsMenu()))
        if #available(macOS 13.0, *) {
            menu.addItem(toggle(L("Launch at login", "Beim Anmelden starten"), SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        }
        menu.addItem(action(diagnosing ? L("Recording – touch the screen …", "Diagnose läuft – Bildschirm berühren …") : L("Record diagnostics (10 s touch)", "Diagnose aufzeichnen (10 s Touch)"), #selector(runDiagnosis), enabled: !diagnosing))
        menu.addItem(action(experiment != nil ? L("Multitouch experiments running – tap with 2 fingers …", "Multitouch-Experimente laufen – mit 2 Fingern tippen …") : L("Start multitouch experiments …", "Multitouch-Experimente starten …"),
                            #selector(runMTExperiments), enabled: experiment == nil && !diagnosing))
        menu.addItem(action(L("Touch test window …", "Touch-Testfenster …"), #selector(openTouchTest)))
        menu.addItem(action(realTouchProbe != nil ? L("Real touch experiment running – do not touch …", "Echtes-Touch-Experiment läuft – nicht berühren …")
                                                  : L("Real touch experiment …", "Echtes-Touch-Experiment …"),
                            #selector(runRealTouchExperiment), enabled: realTouchProbe == nil && experiment == nil && !diagnosing))
        menu.addItem(toggle(L("Bluetooth digitizer: let macOS handle it (no TouchBridge)", "Bluetooth-Digitizer: macOS überlassen (ohne TouchBridge)"),
                            service.releaseBluetoothDigitizer, #selector(toggleReleaseBluetooth)))
        if let seq = settings.multitouchSequence {
            menu.addItem(warning(L("Saved multitouch sequence: \(seq.title)", "Gespeicherte Multitouch-Sequenz: \(seq.title)"), color: .secondaryLabelColor))
            menu.addItem(action(L("Forget saved multitouch sequence", "Gespeicherte Multitouch-Sequenz vergessen"), #selector(forgetMTSequence)))
        }
        menu.addItem(action(L("Install command line tool …", "Kommandozeilen-Tool installieren …"), #selector(installCLI)))
        menu.addItem(submenu("Updates", updatesMenu()))
        let lang = NSMenu()
        for (i, l) in AppLanguage.allCases.enumerated() {
            lang.addItem(toggle(l.title, L10n.language == l, #selector(selectLanguage(_:)), tag: i))
        }
        menu.addItem(submenu(L("Language", "Sprache"), lang))
        menu.addItem(action(L("Help", "Hilfe"), #selector(openHelp)))
        menu.addItem(.separator())
        menu.addItem(action(L("Quit TouchBridge", "TouchBridge beenden"), #selector(quit), key: "q"))
    }

    private func symbol(for f: DisplayControl.Feature) -> String {
        switch f {
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .volume: return "speaker.wave.2"
        }
    }

    private func warning(_ t: String, color: NSColor, bold: Bool = false) -> NSMenuItem {
        let w = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if bold { attrs[.font] = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) }
        w.attributedTitle = NSAttributedString(string: t, attributes: attrs)
        w.isEnabled = false
        return w
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
        m.addItem(toggle(L("Automatic (first external)", "Automatisch (erster externer)"), settings.displayID == nil, #selector(selectDisplay(_:)), tag: 0))
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
            m.addItem(toggle(r == 0 ? "Normal" : L("Rotated \(r)°", "\(r)° gedreht"), settings.rotation == r, #selector(selectRotation(_:)), tag: r))
        }
        m.addItem(.separator())
        m.addItem(toggle(L("Flip horizontally", "Horizontal spiegeln"), settings.flipX, #selector(toggleFlipX)))
        m.addItem(toggle(L("Flip vertically", "Vertikal spiegeln"), settings.flipY, #selector(toggleFlipY)))
        return m
    }

    /// Current gesture mappings (read-only; the editor follows in phase 2)
    private func gesturesMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        func line(_ t: String) {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        line(L("Tap → Click", "Tippen → Klick"))
        line(L("2-finger drag → Scroll", "2-Finger-Ziehen → Scrollen"))
        line(L("2-finger pinch → Zoom", "2-Finger-Pinch → Zoomen"))
        m.addItem(.separator())
        for t in GestureTrigger.allCases {
            line("\(t.title) → \(effectiveSettings.gestures[t].title)")
        }
        m.addItem(.separator())
        m.addItem(action(L("Edit gestures …", "Gesten bearbeiten …"), #selector(openSettings)))
        return m
    }

    // MARK: - Profiles

    private var activeProfile: AppProfile? { profiles.active(frontmostBundleID: frontmostBundleID) }

    /// "Profile: Automatic (Ableton Live)" / "Profile: Default" / "Profile: <name>"
    private var profileMenuTitle: String {
        let current = activeProfile?.name ?? L("Default", "Standard")
        switch profiles.selection {
        case .automatic: return L("Profile: Automatic (\(current))", "Profil: Automatisch (\(current))")
        case .defaultProfile, .profile: return L("Profile: ", "Profil: ") + current
        }
    }

    private func profilesMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(toggle(L("Automatic (by frontmost app)", "Automatisch (nach aktiver App)"), profiles.selection == .automatic, #selector(selectProfile(_:)), tag: -1))
        m.addItem(toggle(L("Default", "Standard"), profiles.selection == .defaultProfile, #selector(selectProfile(_:)), tag: -2))
        if !profiles.profiles.isEmpty { m.addItem(.separator()) }
        for (i, p) in profiles.profiles.enumerated() {
            let item = toggle(p.name, profiles.selection == .profile(p.id), #selector(selectProfile(_:)), tag: i)
            if profiles.selection == .automatic, activeProfile?.id == p.id { item.state = .mixed }
            if p.isManual { item.toolTip = L("Manual profile (no app)", "Manuelles Profil (ohne App)") }
            else if let b = p.bundleID { item.toolTip = b }
            m.addItem(item)
        }
        if activeProfile != nil {
            m.addItem(.separator())
            m.addItem(warning(L("The menu shows and changes the default settings; the profile overrides gestures and some of them.",
                                "Das Menü zeigt und ändert die Standardeinstellungen; das Profil überschreibt Gesten und einige davon."), color: .secondaryLabelColor))
        }
        m.addItem(.separator())
        m.addItem(action(L("Edit profiles …", "Profile bearbeiten …"), #selector(openProfiles)))
        return m
    }

    @objc private func selectProfile(_ s: NSMenuItem) {
        switch s.tag {
        case -1: profiles.selection = .automatic
        case -2: profiles.selection = .defaultProfile
        default:
            guard profiles.profiles.indices.contains(s.tag) else { return }
            profiles.selection = .profile(profiles.profiles[s.tag].id)
        }
    }

    @objc private func appActivated(_ n: Notification) {
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let next = FrontmostApp.next(current: frontmostBundleID, activated: app?.bundleIdentifier, own: Bundle.main.bundleIdentifier)
        guard next != frontmostBundleID else { return }
        frontmostBundleID = next
        applyEffective()
    }

    /// Pushes the effective settings (global + active profile) to the touch service.
    private func applyEffective() {
        guard service != nil else { return }
        let e = effectiveSettings
        if service.settings != e { service.settings = e }
        logActiveProfile()
        settingsWindow?.activeProfileChanged(activeProfile?.id, frontmost: frontmostBundleID)
    }

    private func logActiveProfile() {
        let id = activeProfile?.id
        if let last = lastProfileID, last == id { return }
        lastProfileID = .some(id)
        appendLog("👤 Profile: \(activeProfile?.name ?? "Default")" + (frontmostBundleID.map { " (frontmost: \($0))" } ?? ""))
    }

    @objc private func openProfiles() {
        openSettings()
        settingsWindow?.showTab(.profiles)
    }

    private func scrollMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(toggle(L("Reverse direction", "Richtung umkehren"), settings.invertScroll, #selector(toggleInvert)))
        m.addItem(.separator())
        for (name, g) in [(L("Slow", "Langsam"), 0.6), ("Normal", 1.0), (L("Fast", "Schnell"), 1.6), (L("Very fast", "Sehr schnell"), 2.4)] {
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
        m.addItem(toggle(L("MPE (channel 1 master, 2–16 per note)", "MPE (Kanal 1 Master, 2–16 pro Note)"), settings.mpe, #selector(toggleMPE)))

        let ch = NSMenu()
        for c in 1...16 { ch.addItem(toggle(L("Channel \(c)", "Kanal \(c)"), settings.midiChannel == c, #selector(selectChannel(_:)), tag: c)) }
        let chItem = submenu(L("MIDI channel: \(settings.midiChannel)", "MIDI-Kanal: \(settings.midiChannel)") + (settings.mpe ? L(" (only without MPE)", " (nur ohne MPE)") : ""), ch)
        m.addItem(chItem)

        let base = NSMenu()
        for n in stride(from: 24, through: 84, by: 12) {
            base.addItem(toggle(midiNoteName(n), settings.baseNote == n, #selector(selectBaseNote(_:)), tag: n))
        }
        base.addItem(.separator())
        base.addItem(action(L("One semitone up", "Einen Halbton höher"), #selector(baseNoteUp), enabled: settings.baseNote < 108))
        base.addItem(action(L("One semitone down", "Einen Halbton tiefer"), #selector(baseNoteDown), enabled: settings.baseNote > 0))
        m.addItem(submenu(L("Base note: ", "Grundnote: ") + midiNoteName(settings.baseNote), base))

        let sc = NSMenu()
        for (i, s) in Scale.allCases.enumerated() {
            sc.addItem(toggle(s.title, settings.scale == s, #selector(selectScale(_:)), tag: i))
        }
        m.addItem(submenu(L("Scale (keyboard): ", "Skala (Keyboard): ") + settings.scale.title, sc))

        let br = NSMenu()
        for r in [2, 12, 24, 48] {
            br.addItem(toggle(L("±\(r) semitones", "±\(r) Halbtöne"), settings.bendRange == r, #selector(selectBendRange(_:)), tag: r))
        }
        m.addItem(submenu(L("Pitch bend range (MPE): ±\(settings.bendRange)", "Pitch-Bend-Bereich (MPE): ±\(settings.bendRange)"), br))
        m.addItem(.separator())
        m.addItem(toggle(L("Show layout on the touchscreen", "Layout auf dem Touch-Bildschirm anzeigen"), settings.showOverlay, #selector(toggleOverlay)))
        let port = NSMenuItem(title: L("MIDI port: \"TouchBridge\"", "MIDI-Port: „TouchBridge“"), action: nil, keyEquivalent: "")
        port.isEnabled = false
        m.addItem(port)
        return m
    }

    private func permissionsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(toggle(PermissionTexts.accessibilityName + (Permissions.accessibility ? "" : L(" – missing", " – fehlt")),
                         Permissions.accessibility, #selector(openAccessibility)))
        m.addItem(toggle(L("Input Monitoring", "Eingabeüberwachung") + (Permissions.inputMonitoring ? "" : L(" – missing", " – fehlt")),
                         Permissions.inputMonitoring, #selector(openInputMonitoring)))
        let im = service.inputMonitoringState
        let state = NSMenuItem(title: L("Effect: ", "Wirkung: ") + im.statusText, action: nil, keyEquivalent: "")
        state.isEnabled = false
        m.addItem(state)
        m.addItem(.separator())
        m.addItem(action(L("Reset permissions …", "Berechtigungen zurücksetzen …"), #selector(resetPermissions)))
        m.addItem(action(L("Restart touch", "Touch neu starten"), #selector(restartService)))
        return m
    }

    // MARK: - Aktionen

    @objc private func toggleEnabled() { settings.enabled.toggle(); updateIcon() }
    @objc private func toggleSeize() { settings.seize.toggle() }
    @objc private func toggleSeizeTouchOnly() { settings.seizeTouchOnly.toggle() }
    @objc private func toggleOneFingerScroll() { settings.oneFingerScroll.toggle() }
    @objc private func toggleNativeZoom() { settings.nativeZoom.toggle() }
    @objc private func toggleMomentum() { settings.momentumScroll.toggle() }
    @objc private func toggleHidePointer() { settings.hidePointer.toggle() }
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        L10n.set(AppLanguage.allCases[sender.tag]); updateIcon(); settingsWindow?.languageChanged()
    }
    @objc private func toggleSuppress() { settings.suppressSystemPointer.toggle() }
    @objc private func toggleFlipX() { settings.flipX.toggle() }
    @objc private func toggleFlipY() { settings.flipY.toggle() }
    @objc private func toggleInvert() { settings.invertScroll.toggle() }
    @objc private func selectRotation(_ s: NSMenuItem) { settings.rotation = s.tag }
    @objc private func selectGain(_ s: NSMenuItem) { settings.scrollGain = Double(s.tag) / 10 }
    @objc private func selectDisplay(_ s: NSMenuItem) { settings.displayID = s.tag == 0 ? nil : UInt32(s.tag) }
    @objc private func selectMode(_ s: NSMenuItem) {
        let m = InputMode.allCases[s.tag]
        if m == .gestures { Permissions.requestAccessibilityOnce() }
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
            alert(L("Could not change launch at login", "Autostart konnte nicht geändert werden"), error.localizedDescription)
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

    /// tccutil reset ListenEvent + Accessibility für com.groovex.touchbridge, dann neu anfragen
    @objc private func resetPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("Reset permissions?", "Berechtigungen zurücksetzen?")
        a.informativeText = L10n.language == .english ? "TouchBridge resets Input Monitoring and \(PermissionTexts.accessibilityName) for itself (tccutil reset) and asks again. Then allow TouchBridge in both dialogs or in System Settings. Helps when TouchBridge is enabled there but the permission has no effect (stale entry from an earlier build)." : "TouchBridge setzt Eingabeüberwachung und \(PermissionTexts.accessibilityName) für sich zurück (tccutil reset) und fragt danach neu. "
            + "Erlaube TouchBridge anschließend in beiden Dialogen bzw. in den Systemeinstellungen. "
            + "Hilft, wenn TouchBridge dort aktiviert ist, die Berechtigung aber nicht greift (veralteter Eintrag eines früheren Builds)."
        a.addButton(withTitle: L("Reset", "Zurücksetzen"))
        a.addButton(withTitle: L("Cancel", "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for l in SystemCheck.resetPermissions() { appendLog("🔐 " + l) }
        Permissions.forgetAsked()
        Permissions.requestInputMonitoring()
        Permissions.requestAccessibility()
        hadInputMonitoring = Permissions.inputMonitoring
        hadAccessibility = Permissions.accessibility
        restartService()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func removeLegacyAgent() {
        let log = SystemCheck.removeLegacyAgent()
        for l in log { appendLog("🧹 " + l) }
        restartService()
        alert(L("Old LaunchAgent", "Alter LaunchAgent"), log.joined(separator: "\n"))
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/thegroovex/Touchbridge#readme")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Settings window

    @objc private func openSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(settings: settings,
                                      apply: { [weak self] s in
                                          guard let self = self, self.settings != s else { return }
                                          self.settings = s
                                      },
                                      onLanguage: { [weak self] _ in self?.updateIcon(); self?.settingsWindow?.languageChanged() },
                                      openAccessibility: { [weak self] in self?.openAccessibility() },
                                      profiles: profiles,
                                      applyProfiles: { [weak self] p in
                                          guard let self = self, self.profiles != p else { return }
                                          self.profiles = p
                                      })
            model.activeProfileID = activeProfile?.id
            model.frontmostBundleID = frontmostBundleID
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsWindow?.show()
    }

    /// Invisible main menu (accessory app): gives the settings window Cmd-, / Cmd-W / Cmd-Q and Edit shortcuts
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Settings …", "Einstellungen …"), action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit TouchBridge", "TouchBridge beenden"), action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    /// 10-Sekunden-Diagnose: Touch-Dienst läuft weiter (stumm); bereits geöffnete Interfaces werden nur mitbeobachtet,
    /// alle übrigen HID-Interfaces des Touch-Monitors nicht exklusiv geöffnet, Input Mode gesetzt und Rohreports protokolliert; dazu DDC-Probe.
    /// Ergebnis in die Zwischenablage und als Textdatei auf den Schreibtisch.
    @objc private func runDiagnosis() {
        diagnosing = true
        logLines.removeAll()
        appendLog("TouchBridge \(AppDelegate.version) – diagnostics \(Date())")
        appendLog("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        for (i, d) in Displays.all().enumerated() {
            appendLog("[\(i)] \(d.summary) id=\(d.id) @ (\(Int(d.bounds.minX)),\(Int(d.bounds.minY)))" + (d.isBuiltin ? " built-in" : " external"))
        }
        let tb = CGDisplayBounds(service.targetDisplay)
        appendLog("Touch target: id=\(service.targetDisplay) \(Int(tb.width))×\(Int(tb.height)) @ (\(Int(tb.minX)),\(Int(tb.minY)))  mode: \(settings.mode.title)")
        appendLog("\(PermissionTexts.accessibilityName): \(Permissions.accessibility)  Input Monitoring: \(Permissions.inputMonitoringState)  effective: \(service.inputMonitoringState.statusText)")
        appendLog("— Touch service before diagnostics —")
        appendLog("Status: \(statusText)  reports so far: \(service.reportCount)  (\(service.reportSummary))  source: \(service.touchSource.title)")
        appendLog(InterfaceStatus.summary(service.status.interfaces) + (service.status.seizeError.map { "  – \($0)" } ?? ""))
        appendLog(service.suppressor.statsLine)
        for l in service.suppressor.samples { appendLog("   " + l) }
        for l in service.openLog { appendLog(l) }
        // ioreg-Halter, solange der Touch-Dienst die Schnittstellen noch hält (eigene doppelte Clients = Fehler)
        for l in SystemCheck.diagnosisLines(vid: settings.vid ?? HIDProbe.anmiteVID, pid: settings.pid ?? HIDProbe.anmitePID) { appendLog(l) }
        // Touch-Dienst läuft weiter (keine zweite Registrierung/kein Neu-Öffnen); die Diagnose beobachtet mit.
        // Während der Messung keine Klicks/Gesten senden.
        service.muted = true
        statusItem.button?.title = " REC"

        let ctl = control
        let p = HIDProbe(vid: settings.vid ?? HIDProbe.anmiteVID, pid: settings.pid ?? HIDProbe.anmitePID) { [weak self] in self?.appendLog($0) }
        probe = p
        p.run(seconds: 10) { [weak self] summary in
            guard let self = self else { return }
            self.probe = nil
            let finish = {
                if let c = ctl { for l in c.probeDetails { self.appendLog(l) } } else { self.appendLog("DDC: no display object") }
                self.service.muted = false
                self.appendLog("— Touch service after diagnostics —")
                self.appendLog("Reports: \(self.service.reportSummary)  source: \(self.service.touchSource.title)")
                for l in self.service.openLog.suffix(40) { self.appendLog(l) }
                self.diagnosing = false
                self.statusItem.button?.title = ""
                self.updateIcon()
                let text = self.logLines.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("TouchBridge-Diagnostics.txt")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                let head = summary.interfaces == 0 ? L("No touch interface found.", "Kein Touch-Interface gefunden.")
                    : (summary.reports == 0 ? L("Attention: NO touch reports arrived in 10 s.", "Achtung: In 10 s kamen KEINE Touch-Reports an.")
                                            : L("\(summary.reports) touch reports received.", "\(summary.reports) Touch-Reports empfangen."))
                self.alert(L("Diagnostics done", "Diagnose fertig"), head + L(" Copied to the clipboard and saved as \"TouchBridge-Diagnostics.txt\" on the desktop.", " In die Zwischenablage kopiert und als „TouchBridge-Diagnostics.txt“ auf dem Schreibtisch gespeichert."))
            }
            if let c = ctl { c.probe { _ in finish() } } else { finish() }
        }
    }

    /// Multitouch-Experimente (a–e): jeder Schritt protokolliert, danach 3 s Warten auf Report 13 vom Digitizer.
    /// Erfolgreiche Sequenz wird gespeichert und künftig beim Verbinden angewendet.
    @objc private func runMTExperiments() {
        guard service.status.running, settings.enabled else {
            alert(L("Touch is off", "Touch ist aus"), L("Please turn on \"Touch enabled\" first – the experiments need the open interfaces.", "Bitte zuerst „Touch aktiv“ einschalten – die Experimente brauchen die geöffneten Schnittstellen.")); return
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("Start multitouch experiments?", "Multitouch-Experimente starten?")
        a.informativeText = L10n.language == .english ? "TouchBridge tries 5 ways in a row to switch the Anmite into multitouch mode (GetReport, feature reports, direct USB requests like Linux/Android, finally a short USB reconnect).\n\nAfter \"Start\", keep tapping and swiping with 2 fingers on the Anmite for about 40 seconds until \"Experiments done\" appears. No clicks are sent meanwhile.\n\nNothing is written to the vendor channel (read only). The log is copied to the clipboard and saved as \"TouchBridge-MT-Experiments.txt\" on the desktop." : "TouchBridge probiert nacheinander 5 Wege, den Anmite in den Multitouch-Modus zu schalten "
            + "(GetReport, Feature-Reports, direkte USB-Requests wie unter Linux/Android, zuletzt kurzes Neu-Verbinden des Touch-USB).\n\n"
            + "Bitte nach „Start“ ca. 40 Sekunden lang immer wieder mit 2 Fingern auf den Anmite tippen und wischen, "
            + "bis die Meldung „Experimente fertig“ erscheint. Klicks werden währenddessen nicht ausgelöst.\n\n"
            + "Am Vendor-Kanal wird nichts geschrieben (nur gelesen). Das Protokoll landet in der Zwischenablage und als "
            + "„TouchBridge-MT-Experiments.txt“ auf dem Schreibtisch."
        a.addButton(withTitle: "Start")
        a.addButton(withTitle: L("Cancel", "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        logLines.removeAll()
        appendLog("TouchBridge \(AppDelegate.version) – macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        statusItem.button?.title = " MT"
        let e = MultitouchExperiment(service: service) { [weak self] in self?.appendLog($0) }
        experiment = e
        e.run { [weak self] seq in
            guard let self = self else { return }
            self.experiment = nil
            if let seq = seq { self.settings.mtSequence = seq.rawValue }
            self.statusItem.button?.title = ""
            self.updateIcon()
            let text = self.logLines.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TouchBridge-MT-Experiments.txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            self.alert(L("Experiments done", "Experimente fertig"),
                       (seq.map { L("Multitouch active with \"\($0.title)\" – saved, applied on every connect.", "Multitouch aktiv mit „\($0.title)“ – gespeichert, wird künftig beim Verbinden angewendet.") }
                        ?? L("No method enabled multitouch – single touch stays active.", "Kein Weg brachte Multitouch – Single-Touch bleibt aktiv."))
                       + L(" Log copied to the clipboard and saved on the desktop.", " Protokoll in der Zwischenablage und auf dem Schreibtisch."))
        }
    }

    @objc private func forgetMTSequence() { settings.mtSequence = nil }

    // MARK: - Real touch experiment / Touch test (0.4 beta)

    private func prepareTouchTest() {
        touchTest.extraInfo = { [weak self] in
            guard let self = self else { return [] }
            return ["TouchBridge source: \(self.service.touchSource.title) – status: \(self.statusText)",
                    "Bluetooth digitizer left to macOS: " + (self.service.releaseBluetoothDigitizer ? "yes" : "no"),
                    HIDEventBridge.summary]
        }
        touchTest.onRunProbe = { [weak self] in self?.startRealTouchProbe() }
    }

    @objc private func openTouchTest() {
        NSLog("TouchBridge: open Touch Test window")
        // Run after the status menu has finished tracking – showing windows from inside the menu action can silently fail
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let err = tb_try({
                self.prepareTouchTest()
                self.touchTest.show(on: self.service.targetDisplay)
            }) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(err, forType: .string)
                self.alert(L("Touch Test window failed", "Touch-Testfenster fehlgeschlagen"),
                           L("The error was copied to the clipboard – please paste it into the chat.\n\n", "Der Fehler ist in der Zwischenablage – bitte in den Chat einfügen.\n\n") + err)
            }
        }
    }

    @objc private func runRealTouchExperiment() {
        NSLog("TouchBridge: real touch experiment requested")
        DispatchQueue.main.async { [weak self] in self?.confirmRealTouchExperiment() }
    }

    private func confirmRealTouchExperiment() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("Start real touch experiment?", "Echtes-Touch-Experiment starten?")
        a.informativeText = L(
            "TouchBridge opens the Touch Test window on the touch display and then plays a tap, a drag and a 2-finger pinch in 5 variants (about 20 s), using synthetic events with an attached HID digitizer payload. Please do not touch the mouse or screen meanwhile. The pointer moves and the test window may receive clicks.\n\nResults are appended to \"TouchBridge-RealTouch-Probe.txt\" on the desktop.",
            "TouchBridge öffnet das Touch-Testfenster auf dem Touch-Bildschirm und spielt dann Tippen, Ziehen und 2-Finger-Pinch in 5 Varianten ab (ca. 20 s) – synthetische Events mit angehängtem HID-Digitizer-Payload. Bitte währenddessen Maus und Bildschirm nicht berühren. Der Zeiger bewegt sich, das Testfenster kann Klicks bekommen.\n\nDie Ergebnisse werden an „TouchBridge-RealTouch-Probe.txt“ auf dem Schreibtisch angehängt.")
        a.addButton(withTitle: "Start")
        a.addButton(withTitle: L("Cancel", "Abbrechen"))
        a.window.level = .modalPanel
        guard a.runModal() == .alertFirstButtonReturn else { return }
        openTouchTest()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.startRealTouchProbe() }
    }

    private func startRealTouchProbe() {
        guard realTouchProbe == nil else { return }
        if !touchTest.isVisible { openTouchTest() }
        var lines: [String] = []
        let display = service.targetDisplay
        let p = RealTouchProbe(display: display, region: touchTest.touchRegionCG) { [weak self] line in
            lines.append(line)
            self?.appendLog(line)
        }
        p.onVariant = { [weak self] v in self?.touchTest.setPhase(v) }
        realTouchProbe = p
        let wasMuted = service.muted
        service.muted = true          // real touches must not interfere
        touchTest.probeRunning = true
        statusItem.button?.title = " RT"
        p.run { [weak self] in
            guard let self = self else { return }
            self.service.muted = wasMuted
            self.touchTest.probeRunning = false
            self.realTouchProbe = nil
            self.statusItem.button?.title = ""
            self.updateIcon()
            let report = ["TouchBridge \(AppDelegate.version)"] + lines + self.touchTest.report(title: "Touch Test window counters after the experiment")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report.joined(separator: "\n"), forType: .string)
            let err = RealTouchProbe.append(report)
            self.alert(L("Real touch experiment done", "Echtes-Touch-Experiment fertig"),
                       (err == nil ? "" : L("Could not save the file (\(err!)) – the results are on the clipboard, just paste them into the chat.\n\n", "Datei konnte nicht gesichert werden (\(err!)) – die Ergebnisse sind in der Zwischenablage, einfach in den Chat einfügen.\n\n")) +
                       L("The counters per variant are shown in the Touch Test window. Results were appended to \"TouchBridge-RealTouch-Probe.txt\" on the desktop – please send that file.",
                         "Die Zähler je Variante stehen im Touch-Testfenster. Die Ergebnisse wurden an „TouchBridge-RealTouch-Probe.txt“ auf dem Schreibtisch angehängt – bitte diese Datei schicken."))
        }
    }

    @objc private func toggleReleaseBluetooth() {
        service.releaseBluetoothDigitizer.toggle()
        updateIcon()
        if touchTest.isVisible { touchTest.setPhase(service.releaseBluetoothDigitizer ? "BT digitizer → macOS" : "BT digitizer → TouchBridge") }
    }

    /// Verlinkt das CLI aus dem App-Bundle nach /usr/local/bin/touchbridge (fragt nach dem Admin-Passwort).
    @objc private func installCLI() {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/touchbridge").path
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            alert(L("Not found", "Nicht gefunden"), L("The command line tool is missing from the app bundle.", "Das Kommandozeilen-Tool fehlt im App-Bundle.")); return
        }
        let cmd = "mkdir -p /usr/local/bin && ln -sf '\(cli)' /usr/local/bin/touchbridge"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let e = err {
            if (e[NSAppleScript.errorNumber] as? Int) != -128 {
                alert(L("Installation failed", "Installation fehlgeschlagen"), (e[NSAppleScript.errorMessage] as? String) ?? "\(e)")
            }
        } else {
            alert(L("Installed", "Installiert"), L("\"touchbridge\" is now available in Terminal, e.g. touchbridge --dump.", "Im Terminal steht jetzt „touchbridge“ bereit, z. B. touchbridge --dump."))
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

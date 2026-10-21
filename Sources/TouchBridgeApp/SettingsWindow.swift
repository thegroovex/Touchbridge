import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TouchBridgeCore
import TouchBridgeKit

/// Shared state between the settings window and the AppDelegate
final class SettingsModel: ObservableObject {
    @Published var settings: TouchSettings {
        didSet { if settings != oldValue { apply(settings) } }
    }
    @Published var language: AppLanguage = L10n.language
    @Published var accessibilityTrusted = Permissions.accessibility
    /// App profiles (0.4 phase 3)
    @Published var profiles: ProfileStore {
        didSet { if profiles != oldValue { applyProfiles(profiles) } }
    }
    /// Profile currently in effect (nil = default) and the app driving it
    @Published var activeProfileID: UUID?
    @Published var frontmostBundleID: String?
    @Published var tab: SettingsTab = .general
    let apply: (TouchSettings) -> Void
    let onLanguage: (AppLanguage) -> Void
    let openAccessibility: () -> Void
    let applyProfiles: (ProfileStore) -> Void

    init(settings: TouchSettings, apply: @escaping (TouchSettings) -> Void,
         onLanguage: @escaping (AppLanguage) -> Void, openAccessibility: @escaping () -> Void,
         profiles: ProfileStore, applyProfiles: @escaping (ProfileStore) -> Void) {
        self.settings = settings
        self.apply = apply
        self.onLanguage = onLanguage
        self.openAccessibility = openAccessibility
        self.profiles = profiles
        self.applyProfiles = applyProfiles
    }

    func setLanguage(_ l: AppLanguage) {
        guard l != L10n.language else { return }
        L10n.set(l)
        language = l
        onLanguage(l)
    }
}

/// Settings window (SwiftUI in an NSWindow); one instance, reopened on demand.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) { self.model = model }

    func show() {
        model.accessibilityTrusted = Permissions.accessibility
        model.language = L10n.language
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 840, height: 600))
            w.center()
            window = w
        }
        window?.title = L("TouchBridge Settings", "TouchBridge-Einstellungen")
        if let w = window { WindowFront.bring(w) }
    }

    /// Settings changed elsewhere (menu)
    func sync(_ s: TouchSettings) {
        if model.settings != s { model.settings = s }
    }

    /// Profiles changed elsewhere (menu)
    func syncProfiles(_ p: ProfileStore) {
        if model.profiles != p { model.profiles = p }
    }

    func activeProfileChanged(_ id: UUID?, frontmost: String?) {
        if model.activeProfileID != id { model.activeProfileID = id }
        if model.frontmostBundleID != frontmost { model.frontmostBundleID = frontmost }
    }

    func showTab(_ t: SettingsTab) { model.tab = t }

    func languageChanged() {
        model.language = L10n.language
        window?.title = L("TouchBridge Settings", "TouchBridge-Einstellungen")
    }
}

// MARK: - Views

enum SettingsTab: Hashable { case general, gestures, profiles, touch, about }

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralTab(model: model)
                .tabItem { Text(L("General", "Allgemein")) }
                .tag(SettingsTab.general)
            GesturesTab(model: model)
                .tabItem { Text(L("Gestures", "Gesten")) }
                .tag(SettingsTab.gestures)
            ProfilesTab(model: model)
                .tabItem { Text(L("Profiles", "Profile")) }
                .tag(SettingsTab.profiles)
            TouchTab(model: model)
                .tabItem { Text("Touch") }
                .tag(SettingsTab.touch)
            AboutTab()
                .tabItem { Text(L("About", "Über")) }
                .tag(SettingsTab.about)
        }
        .padding(16)
        .frame(width: 840, height: 600)
        .id(model.language)   // rebuild all L() strings after a language switch
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
    }
}

struct Hint: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionBox(title: L("Touch", "Touch")) {
                    Toggle(L("Touch enabled", "Touch aktiv"), isOn: $model.settings.enabled)
                    Toggle(L("Momentum scrolling", "Scrollen mit Nachlauf (Momentum)"), isOn: $model.settings.momentumScroll)
                    Toggle(L("Hide pointer while touching", "Zeiger beim Berühren ausblenden"), isOn: $model.settings.hidePointer)
                    Toggle(L("Pinch = trackpad zoom (off: Cmd + / Cmd −)", "Pinch = Trackpad-Zoom (aus: Cmd + / Cmd −)"), isOn: $model.settings.nativeZoom)
                    Toggle(L("1-finger drag scrolls (instead of pointer/drag)", "1-Finger-Ziehen scrollt (statt Zeiger/Ziehen)"), isOn: $model.settings.oneFingerScroll)
                    Toggle(L("Reverse scroll direction", "Scrollrichtung umkehren"), isOn: $model.settings.invertScroll)
                }
                SectionBox(title: L("Output", "Ausgabe")) {
                    Picker(L("Output", "Ausgabe"), selection: $model.settings.output) {
                        ForEach(TouchOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(maxWidth: 420)
                    if model.settings.output == .digitizer {
                        Picker(L("Dongle covers", "Dongle deckt ab"), selection: $model.settings.digitizerSpace) {
                            ForEach(DigitizerSpace.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .frame(maxWidth: 420)
                    }
                    Hint(L("Digitizer dongle: an nRF52840 board with the TouchBridge Digitizer firmware reports the touches to macOS as a real USB touch screen. TouchBridge then posts no gestures or mouse events of its own; macOS handles touch. See firmware/nrf-digitizer in the repository.",
                           "Digitizer-Dongle: Ein nRF52840-Board mit der TouchBridge-Digitizer-Firmware meldet die Berührungen als echten USB-Touchscreen an macOS. TouchBridge sendet dann keine eigenen Gesten oder Mausereignisse; macOS verarbeitet Touch selbst. Siehe firmware/nrf-digitizer im Repository."))
                }
                SectionBox(title: L("Language", "Sprache")) {
                    Picker(L("Language", "Sprache"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                Hint(L("All other options stay in the menu bar menu.", "Alle weiteren Optionen bleiben im Menüleisten-Menü."))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GesturesTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Hint(L("Tap = click, 1-finger drag = drag, 2-finger drag = scroll and pinch = zoom are fixed. Choose what the other gestures do:",
                   "Tippen = Klick, 1-Finger-Ziehen = Ziehen, 2-Finger-Ziehen = Scrollen und Pinch = Zoomen sind fest. Wähle, was die übrigen Gesten tun:"))
            ScrollView {
                GestureList(map: $model.settings.gestures)
            }
            HStack {
                Hint(L("These are the gestures of the default profile. App profiles: Profiles tab.",
                       "Das sind die Gesten des Standardprofils. App-Profile: Reiter „Profile“."))
                Spacer()
                Button(L("Reset to defaults", "Auf Standard zurücksetzen")) { model.settings.gestures = GestureMap.defaults }
                    .disabled(model.settings.gestures.isDefault)
            }
        }
    }
}

/// The gesture editor: one row per slot (used by the Gestures tab and the profile editor)
struct GestureList: View {
    @Binding var map: GestureMap

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(GestureTrigger.allCases, id: \.self) { t in
                GestureRow(trigger: t, action: Binding(get: { map[t] }, set: { map[t] = $0 }))
                Divider()
            }
        }
        .padding(.trailing, 8)
    }
}

struct GestureRow: View {
    let trigger: GestureTrigger
    @Binding var action: GestureAction

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(trigger.title).frame(width: 190, alignment: .leading)
            Picker("", selection: Binding(get: { action.kind }, set: { k in
                action = GestureAction.make(k, keeping: action)
                if k == .openApp, case .openApp(let p) = action, p.isEmpty { DispatchQueue.main.async { chooseApp() } }
            })) {
                ForEach(trigger.allowedKinds, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 200)
            detail
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var detail: some View {
        switch action {
        case .shortcut(let k):
            ShortcutRecorder(combo: k) { action = .shortcut($0) }
                .frame(width: 150, height: 24)
        case .openApp(let p):
            Button(p.isEmpty ? L("Choose app …", "App wählen …") : URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent) { chooseApp() }
                .frame(maxWidth: 160)
        default:
            EmptyView()
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = L("Choose an app", "App auswählen")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { action = .openApp(url.path) }
    }
}

struct TouchTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.accessibilityTrusted {
                    HStack {
                        Text(L("⚠️ Smart target and the touch menu need the \(PermissionTexts.accessibilityName) permission.",
                               "⚠️ Smart Target und das Touch-Menü brauchen die Berechtigung \(PermissionTexts.accessibilityName)."))
                            .foregroundColor(.orange)
                        Spacer()
                        Button(L("Open …", "Öffnen …")) { model.openAccessibility() }
                    }
                }
                SectionBox(title: "Smart Target") {
                    Toggle(L("Snap taps onto the nearest control", "Tippen rastet auf das nächste Bedienelement ein"), isOn: $model.settings.smartTarget)
                    HStack {
                        Text(L("Search radius", "Suchradius"))
                        Slider(value: $model.settings.smartTargetRadius, in: 4...30, step: 1)
                            .frame(width: 220)
                        Text("\(Int(model.settings.smartTargetRadius)) pt").frame(width: 50, alignment: .leading)
                    }
                    .disabled(!model.settings.smartTarget)
                    Hint(L("If a tap lands next to a button, checkbox, link, tab or text field, TouchBridge clicks it anyway (Accessibility hit test).",
                           "Landet ein Tipp knapp neben einem Knopf, Häkchen, Link, Tab oder Textfeld, klickt TouchBridge trotzdem darauf (Accessibility-Hit-Test)."))
                }
                SectionBox(title: L("Long press", "Lange halten")) {
                    Toggle(L("Touch context menu (off: right click)", "Touch-Kontextmenü (aus: Rechtsklick)"), isOn: $model.settings.contextMenu)
                    HStack {
                        Text(L("Hold time", "Haltedauer"))
                        Slider(value: $model.settings.longPressDuration, in: 0.3...1.5, step: 0.05)
                            .frame(width: 220)
                        Text(String(format: "%.2f s", model.settings.longPressDuration)).frame(width: 60, alignment: .leading)
                    }
                    Hint(L("Holding a finger still opens the element's own context menu, or large touch rows with its actions plus Copy, Paste and Right click. The \"Long press\" gesture slot can also be set to another action.",
                           "Finger ruhig halten öffnet das Kontextmenü des Elements oder große Touch-Zeilen mit seinen Aktionen sowie Kopieren, Einsetzen und Rechtsklick. Der Gesten-Platz „Lange halten“ kann auch eine andere Aktion bekommen."))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            }
            Text("TouchBridge").font(.title)
            Text(L("Version ", "Version ") + Updater.currentVersion).foregroundColor(.secondary)
            Text(L("Multitouch for USB touch monitors on the Mac", "Multitouch für USB-Touchmonitore am Mac"))
            Button("github.com/thegroovex/Touchbridge") {
                if let u = URL(string: "https://github.com/thegroovex/Touchbridge") { NSWorkspace.shared.open(u) }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorder: NSViewRepresentable {
    var combo: KeyCombo
    var onChange: (KeyCombo) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let b = ShortcutRecorderButton(frame: .zero)
        b.combo = combo
        b.onChange = onChange
        return b
    }

    func updateNSView(_ b: ShortcutRecorderButton, context: Context) {
        b.onChange = onChange
        if b.combo != combo { b.combo = combo }
    }
}

/// Click, then press the key combination; Esc cancels.
final class ShortcutRecorderButton: NSButton {
    var combo: KeyCombo = .unset { didSet { refresh() } }
    var onChange: (KeyCombo) -> Void = { _ in }
    private var recording = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func toggleRecording() {
        recording.toggle()
        if recording { window?.makeFirstResponder(self) }
    }

    private func refresh() {
        if recording { title = L("Type shortcut …", "Tasten drücken …") }
        else { title = combo.isSet ? combo.displayString : L("Record shortcut", "Kürzel aufnehmen") }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option, .function, .numericPad])
        if event.keyCode == 53 && mods.subtracting([.function, .numericPad]).isEmpty { recording = false; return }  // Esc
        let k = KeyCombo(keyCode: event.keyCode, modifiers: UInt64(mods.rawValue), label: event.charactersIgnoringModifiers)
        recording = false
        combo = k
        onChange(k)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording && event.type == .keyDown { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }
}

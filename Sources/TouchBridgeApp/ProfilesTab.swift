import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TouchBridgeCore
import TouchBridgeKit

/// Settings › Profiles: per-app gesture profiles (0.4 phase 3)
struct ProfilesTab: View {
    @ObservedObject var model: SettingsModel
    /// "default" or a profile UUID string
    @State private var selection: String? = "default"

    private static let defaultTag = "default"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selection) {
                    ProfileListRow(name: L("Default", "Standard"), detail: L("All other apps", "Alle anderen Apps"),
                                   appPath: nil, active: model.activeProfileID == nil)
                        .tag(Self.defaultTag)
                    ForEach(model.profiles.profiles) { p in
                        ProfileListRow(name: p.name,
                                       detail: p.bundleID ?? L("Manual (menu only)", "Manuell (nur Menü)"),
                                       appPath: p.appPath, active: model.activeProfileID == p.id)
                            .tag(p.id.uuidString)
                    }
                }
                .frame(width: 210)
                .border(Color(NSColor.separatorColor))
                HStack(spacing: 4) {
                    addMenu
                    Button(L("Duplicate", "Duplizieren")) { duplicate() }.disabled(selectedID == nil)
                    Button("−") { delete() }.disabled(selectedID == nil)
                        .help(L("Delete profile", "Profil löschen"))
                }
                HStack(spacing: 4) {
                    Button(L("Import …", "Importieren …")) { importProfiles() }
                    Button(L("Export …", "Exportieren …")) { exportProfiles() }.disabled(model.profiles.profiles.isEmpty)
                }
                selectionPicker
            }
            .frame(width: 210)

            if let id = selectedID, model.profiles[id] != nil {
                ProfileEditor(model: model, id: id)
            } else {
                defaultInfo
            }
        }
        .onAppear { if let id = model.activeProfileID { selection = id.uuidString } }
    }

    private var selectedID: UUID? { selection.flatMap(UUID.init(uuidString:)) }

    // MARK: Selection (menu "Profile: …")

    private var selectionPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Active profile", "Aktives Profil")).font(.caption).foregroundColor(.secondary)
            Picker("", selection: Binding(get: { model.profiles.selection.rawValue },
                                          set: { model.profiles.selection = ProfileSelection(rawValue: $0) })) {
                Text(L("Automatic", "Automatisch")).tag(ProfileSelection.automatic.rawValue)
                Text(L("Default", "Standard")).tag(ProfileSelection.defaultProfile.rawValue)
                ForEach(model.profiles.profiles) { p in
                    Text(p.name).tag(ProfileSelection.profile(p.id).rawValue)
                }
            }
            .labelsHidden()
        }
    }

    private var defaultInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Default profile", "Standardprofil")).font(.title2)
            Hint(L("The default profile is TouchBridge's normal settings (General, Gestures and Touch tabs). It is used for every app without a profile of its own.",
                   "Das Standardprofil sind die normalen TouchBridge-Einstellungen (Reiter Allgemein, Gesten und Touch). Es gilt für jede App ohne eigenes Profil."))
            Hint(L("Add a profile for an app with +. While that app is in front, its gestures and settings are used automatically. Manual profiles (no app) can be chosen in the menu under \"Profile\".",
                   "Mit + ein Profil für eine App anlegen. Solange diese App vorne ist, gelten automatisch ihre Gesten und Einstellungen. Manuelle Profile (ohne App) lassen sich im Menü unter „Profil“ wählen."))
            if let b = model.frontmostBundleID {
                Hint(L("Frontmost app: ", "Aktive App: ") + b)
            }
            Button(L("Edit default gestures …", "Standardgesten bearbeiten …")) { model.tab = .gestures }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Add

    private var addMenu: some View {
        Menu("+") {
            Section(header: Text(L("Running apps", "Laufende Apps"))) {
                ForEach(Self.runningApps(), id: \.bundleID) { app in
                    Button(app.name) { add(name: app.name, bundleID: app.bundleID, path: app.path) }
                }
            }
            Divider()
            Button(L("Choose app file …", "App-Datei wählen …")) { chooseAppFile() }
            Button(L("Manual profile (no app)", "Manuelles Profil (ohne App)")) {
                add(name: L("Profile", "Profil"), bundleID: nil, path: nil)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Add profile", "Profil hinzufügen"))
    }

    struct RunningApp { let name: String; let bundleID: String; let path: String? }

    static func runningApps() -> [RunningApp] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { a -> RunningApp? in
            guard a.activationPolicy == .regular, let b = a.bundleIdentifier, b != own, !seen.contains(b) else { return nil }
            seen.insert(b)
            return RunningApp(name: a.localizedName ?? b, bundleID: b, path: a.bundleURL?.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func add(name: String, bundleID: String?, path: String?) {
        var s = model.profiles
        // a new profile starts with the default profile's gestures
        let p = s.add(name: name, bundleID: bundleID, appPath: path, gestures: model.settings.gestures)
        model.profiles = s
        selection = p.id.uuidString
        NSLog("TouchBridge: profile '%@' added (%@)", p.name, p.bundleID ?? "manual")
    }

    private func chooseAppFile() {
        let panel = NSOpenPanel()
        panel.title = L("Choose an app", "App auswählen")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let b = Bundle(url: url)?.bundleIdentifier else {
            alert(L("This app has no bundle identifier.", "Diese App hat keine Bundle-ID."))
            return
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        add(name: name, bundleID: b, path: url.path)
    }

    // MARK: Duplicate / delete

    private func duplicate() {
        guard let id = selectedID else { return }
        var s = model.profiles
        if let p = s.duplicate(id) {
            model.profiles = s
            selection = p.id.uuidString
        }
    }

    private func delete() {
        guard let id = selectedID, let p = model.profiles[id] else { return }
        let a = NSAlert()
        a.messageText = L("Delete profile \"\(p.name)\"?", "Profil „\(p.name)“ löschen?")
        a.informativeText = L("This cannot be undone.", "Das lässt sich nicht rückgängig machen.")
        a.addButton(withTitle: L("Delete", "Löschen"))
        a.addButton(withTitle: L("Cancel", "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var s = model.profiles
        s.delete(id)
        model.profiles = s
        selection = Self.defaultTag
    }

    // MARK: Export / import

    private func exportProfiles() {
        let panel = NSSavePanel()
        panel.title = L("Export profiles", "Profile exportieren")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TouchBridge Profiles.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.profiles.exportData().write(to: url, options: .atomic)
            NSLog("TouchBridge: %d profiles exported to %@", model.profiles.profiles.count, url.path)
        } catch {
            alert(L("Export failed: ", "Export fehlgeschlagen: ") + error.localizedDescription)
        }
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.title = L("Import profiles", "Profile importieren")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            var s = model.profiles
            let r = try s.importData(data)
            model.profiles = s
            NSLog("TouchBridge: profiles imported from %@ (%d added, %d replaced)", url.path, r.added, r.replaced)
            alert(L("\(r.added) profile(s) added, \(r.replaced) replaced.", "\(r.added) Profil(e) hinzugefügt, \(r.replaced) ersetzt."))
        } catch let e as ProfileStore.ImportError {
            alert(L("Import failed: ", "Import fehlgeschlagen: ") + e.description)
        } catch {
            alert(L("Import failed: ", "Import fehlgeschlagen: ") + error.localizedDescription)
        }
    }

    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

private struct ProfileListRow: View {
    let name: String
    let detail: String
    let appPath: String?
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let p = appPath, FileManager.default.fileExists(atPath: p) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "hand.point.up.left").frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(detail).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if active {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                    .help(L("Active now", "Gerade aktiv"))
            }
        }
    }
}

/// Edits one profile: name, overrides and its gesture map (same editor as the Gestures tab)
private struct ProfileEditor: View {
    @ObservedObject var model: SettingsModel
    let id: UUID

    private var profile: Binding<AppProfile> {
        Binding(get: { model.profiles[id] ?? AppProfile(id: id, name: "") },
                set: { p in
                    var s = model.profiles
                    s.update(p)
                    model.profiles = s
                })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Name", "Name"))
                    TextField("", text: profile.name).frame(maxWidth: 260)
                    if model.activeProfileID == id {
                        Text(L("● active", "● aktiv")).foregroundColor(.green).font(.caption)
                    }
                }
                Hint(profile.wrappedValue.bundleID.map { L("Switches automatically when this app is in front: ", "Schaltet automatisch um, wenn diese App vorne ist: ") + $0 }
                     ?? L("Manual profile: choose it in the menu under \"Profile\".", "Manuelles Profil: im Menü unter „Profil“ wählen."))
                SectionBox(title: L("Settings", "Einstellungen")) {
                    BoolOverrideRow(title: L("Pinch = trackpad zoom", "Pinch = Trackpad-Zoom"),
                                    value: profile.overrides.nativeZoom, global: model.settings.nativeZoom)
                    BoolOverrideRow(title: L("Reverse scroll direction", "Scrollrichtung umkehren"),
                                    value: profile.overrides.invertScroll, global: model.settings.invertScroll)
                    GainOverrideRow(value: profile.overrides.scrollGain, global: model.settings.scrollGain)
                    BoolOverrideRow(title: L("1-finger drag scrolls", "1-Finger-Ziehen scrollt"),
                                    value: profile.overrides.oneFingerScroll, global: model.settings.oneFingerScroll)
                    BoolOverrideRow(title: L("Momentum scrolling", "Scrollen mit Nachlauf"),
                                    value: profile.overrides.momentumScroll, global: model.settings.momentumScroll)
                    BoolOverrideRow(title: "Smart Target",
                                    value: profile.overrides.smartTarget, global: model.settings.smartTarget)
                    BoolOverrideRow(title: L("Touch context menu on long press", "Touch-Kontextmenü bei langem Halten"),
                                    value: profile.overrides.contextMenu, global: model.settings.contextMenu)
                    LongPressOverrideRow(value: profile.overrides.longPressDuration, global: model.settings.longPressDuration)
                    Hint(L("\"Default\" uses the value of the default profile.", "„Standard“ übernimmt den Wert des Standardprofils."))
                }
                SectionBox(title: L("Gestures", "Gesten")) {
                    GestureList(map: profile.gestures)
                    HStack {
                        Spacer()
                        Button(L("Copy from default profile", "Vom Standardprofil übernehmen")) {
                            profile.wrappedValue.gestures = model.settings.gestures
                        }
                        .disabled(profile.wrappedValue.gestures == model.settings.gestures)
                        Button(L("Reset to defaults", "Auf Standard zurücksetzen")) { profile.wrappedValue.gestures = GestureMap.defaults }
                            .disabled(profile.wrappedValue.gestures.isDefault)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private let labelWidth: CGFloat = 250

/// Default / On / Off
private struct BoolOverrideRow: View {
    let title: String
    @Binding var value: Bool?
    let global: Bool

    var body: some View {
        HStack {
            Text(title).frame(width: labelWidth, alignment: .leading)
            Picker("", selection: Binding(get: { value.map { $0 ? 1 : 2 } ?? 0 },
                                          set: { (v: Int) in value = v == 0 ? nil : (v == 1) })) {
                Text(L("Default (\(global ? "on" : "off"))", "Standard (\(global ? "an" : "aus"))")).tag(0)
                Text(L("On", "An")).tag(1)
                Text(L("Off", "Aus")).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
        }
    }
}

private func gainName(_ g: Double) -> String {
    switch g {
    case ..<0.8: return L("Slow", "Langsam")
    case ..<1.3: return "Normal"
    case ..<2.0: return L("Fast", "Schnell")
    default: return L("Very fast", "Sehr schnell")
    }
}

private struct GainOverrideRow: View {
    @Binding var value: Double?
    let global: Double

    /// -1 = default, else index into ProfileOverrides.scrollGains
    private var index: Int {
        guard let v = value else { return -1 }
        let gains = ProfileOverrides.scrollGains
        return gains.firstIndex(where: { abs($0 - v) < 0.01 }) ?? 1
    }

    var body: some View {
        HStack {
            Text(L("Scroll speed", "Scrollgeschwindigkeit")).frame(width: labelWidth, alignment: .leading)
            Picker("", selection: Binding(get: { index }, set: { (i: Int) in value = i < 0 ? nil : ProfileOverrides.scrollGains[i] })) {
                Text(L("Default (\(gainName(global)))", "Standard (\(gainName(global)))")).tag(-1)
                ForEach(ProfileOverrides.scrollGains.indices, id: \.self) { i in
                    Text(gainName(ProfileOverrides.scrollGains[i])).tag(i)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }
}

private struct LongPressOverrideRow: View {
    @Binding var value: Double?
    let global: Double

    var body: some View {
        HStack {
            Text(L("Hold time", "Haltedauer")).frame(width: labelWidth, alignment: .leading)
            Toggle(L("Own value", "Eigener Wert"), isOn: Binding(get: { value != nil },
                                                                 set: { value = $0 ? (value ?? global) : nil }))
            Slider(value: Binding(get: { value ?? global }, set: { value = $0 }), in: 0.3...1.5, step: 0.05)
                .frame(width: 140)
                .disabled(value == nil)
            Text(String(format: "%.2f s", value ?? global)).frame(width: 60, alignment: .leading)
        }
    }
}

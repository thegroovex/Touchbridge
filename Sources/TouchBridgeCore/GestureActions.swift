import CoreGraphics
import Foundation

// MARK: - Key combination

/// A recorded keyboard shortcut (virtual key code + modifier flags as CGEventFlags raw value).
public struct KeyCombo: Equatable, Hashable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    /// Key cap as typed when recording (layout-correct, e.g. "Z" on a German keyboard); nil = use the key table
    public var label: String?

    public init(keyCode: UInt16, modifiers: UInt64, label: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers & KeyCombo.modifierMask
        self.label = KeyCombo.sanitizedLabel(label)
    }

    /// Not recorded yet (picker switched to "Keyboard shortcut", recorder not used yet)
    public static let unset = KeyCombo(keyCode: UInt16.max, modifiers: 0)
    public var isSet: Bool { keyCode != UInt16.max }

    /// Command, Shift, Control, Option, fn and numeric pad (arrow keys carry fn + numeric pad on real keyboards).
    /// Same bit positions in CGEventFlags and NSEvent.ModifierFlags.
    public static let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskNumericPad.rawValue

    public var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    /// Keys that carry fn / numeric pad by themselves (no "fn" shown for them)
    static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    /// US-ANSI key caps (fallback when no label was recorded)
    static let ansiKeys: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 50: "`",
    ]

    public static func keyName(_ code: UInt16) -> String {
        specialKeys[code] ?? ansiKeys[code] ?? "#\(code)"
    }

    /// Keeps a printable key cap; drops control characters and the private-use characters AppKit
    /// reports for arrows / function keys (U+F700…U+F8FF).
    public static func sanitizedLabel(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= 2 else { return nil }
        for u in s.unicodeScalars {
            if u.value < 0x20 || u.value == 0x7F || (0xF700...0xF8FF).contains(u.value) { return nil }
        }
        return s.uppercased()
    }

    /// e.g. "⌃⌥⇧⌘K"
    public var displayString: String {
        guard isSet else { return "" }
        var s = ""
        let f = flags
        let special = KeyCombo.specialKeys[keyCode] != nil
        if f.contains(.maskSecondaryFn) && !special { s += "fn " }
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s + (special ? KeyCombo.keyName(keyCode) : (label ?? KeyCombo.keyName(keyCode)))
    }

    /// "code:modifiers:label"
    public var encoded: String { "\(keyCode):\(modifiers):\(label ?? "")" }

    public init?(encoded: String) {
        let parts = encoded.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let code = UInt16(parts[0]), let mods = UInt64(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: mods, label: parts.count == 3 ? String(parts[2]) : nil)
    }
}

// MARK: - Actions

/// What a gesture does. Stored as a string (see rawValue) so old saved mappings keep working.
public enum GestureAction: Equatable, Hashable, Codable {
    case none, missionControl, appExpose, previousSpace, nextSpace, launchpad, showDesktop, smartZoom
    /// Native trackpad rotation (only meaningful for the rotate slot)
    case rotate
    case leftClick, rightClick, middleClick
    /// Touch context menu (long press only); falls back to a right click
    case contextMenu
    case shortcut(KeyCombo)
    /// Path of an .app bundle
    case openApp(String)

    /// Picker entries (one per case, payload-free)
    public enum Kind: String, CaseIterable {
        case none, contextMenu, rightClick, leftClick, middleClick, smartZoom, rotate
        case missionControl, appExpose, previousSpace, nextSpace, launchpad, showDesktop
        case shortcut, openApp

        public var title: String {
            switch self {
            case .none: return L("Nothing", "Nichts")
            case .contextMenu: return L("Touch context menu", "Touch-Kontextmenü")
            case .rightClick: return L("Right click", "Rechtsklick")
            case .leftClick: return L("Click", "Klick")
            case .middleClick: return L("Middle click", "Mittelklick")
            case .smartZoom: return L("Smart zoom", "Intelligentes Zoomen")
            case .rotate: return L("Rotate (trackpad)", "Drehen (Trackpad)")
            case .missionControl: return "Mission Control"
            case .appExpose: return L("App Exposé", "App-Exposé")
            case .previousSpace: return L("Space to the left", "Space links davon")
            case .nextSpace: return L("Space to the right", "Space rechts davon")
            case .launchpad: return L("Launchpad / Apps", "Launchpad / Apps")
            case .showDesktop: return L("Show desktop", "Schreibtisch anzeigen")
            case .shortcut: return L("Keyboard shortcut", "Tastenkombination")
            case .openApp: return L("Open app", "App öffnen")
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .none: return .none
        case .missionControl: return .missionControl
        case .appExpose: return .appExpose
        case .previousSpace: return .previousSpace
        case .nextSpace: return .nextSpace
        case .launchpad: return .launchpad
        case .showDesktop: return .showDesktop
        case .smartZoom: return .smartZoom
        case .rotate: return .rotate
        case .leftClick: return .leftClick
        case .rightClick: return .rightClick
        case .middleClick: return .middleClick
        case .contextMenu: return .contextMenu
        case .shortcut: return .shortcut
        case .openApp: return .openApp
        }
    }

    /// Action for a picker choice; keeps the payload of `current` when the kind does not change.
    public static func make(_ kind: Kind, keeping current: GestureAction? = nil) -> GestureAction {
        if let c = current, c.kind == kind { return c }
        switch kind {
        case .none: return .none
        case .missionControl: return .missionControl
        case .appExpose: return .appExpose
        case .previousSpace: return .previousSpace
        case .nextSpace: return .nextSpace
        case .launchpad: return .launchpad
        case .showDesktop: return .showDesktop
        case .smartZoom: return .smartZoom
        case .rotate: return .rotate
        case .leftClick: return .leftClick
        case .rightClick: return .rightClick
        case .middleClick: return .middleClick
        case .contextMenu: return .contextMenu
        case .shortcut: return .shortcut(.unset)
        case .openApp: return .openApp("")
        }
    }

    /// "none", "missionControl", …, "shortcut:<code>:<mods>:<label>", "app:<path>"
    public var rawValue: String {
        switch self {
        case .shortcut(let k): return "shortcut:" + k.encoded
        case .openApp(let p): return "app:" + p
        default: return kind.rawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix("shortcut:") {
            guard let k = KeyCombo(encoded: String(rawValue.dropFirst("shortcut:".count))) else { return nil }
            self = .shortcut(k)
        } else if rawValue.hasPrefix("app:") {
            self = .openApp(String(rawValue.dropFirst("app:".count)))
        } else {
            guard let k = Kind(rawValue: rawValue), k != .shortcut, k != .openApp else { return nil }
            self = GestureAction.make(k)
        }
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let a = GestureAction(rawValue: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown action \(s)"))
        }
        self = a
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var title: String {
        switch self {
        case .shortcut(let k): return k.isSet ? L("Shortcut ", "Tasten ") + k.displayString : Kind.shortcut.title
        case .openApp(let p):
            guard !p.isEmpty else { return Kind.openApp.title }
            let name = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
            return L("Open \(name)", "\(name) öffnen")
        default: return kind.title
        }
    }
}

// MARK: - Triggers

/// Which gesture was recognised. Declaration order = order in the gesture editor.
public enum GestureTrigger: String, Codable, CaseIterable {
    case twoFingerTap, twoFingerDoubleTap, rotate, longPress
    case threeFingerSwipeUp, threeFingerSwipeDown, threeFingerSwipeLeft, threeFingerSwipeRight
    case fourFingerSwipeUp, fourFingerSwipeDown, fourFingerSwipeLeft, fourFingerSwipeRight
    case fourFingerPinchIn, fourFingerSpread

    public var title: String {
        switch self {
        case .twoFingerTap: return L("2-finger tap", "2-Finger-Tippen")
        case .twoFingerDoubleTap: return L("2-finger double tap", "2-Finger-Doppeltippen")
        case .rotate: return L("2-finger rotate", "2-Finger-Drehen")
        case .longPress: return L("Long press", "Lange halten")
        case .threeFingerSwipeUp: return L("3-finger swipe up", "3-Finger-Wischen nach oben")
        case .threeFingerSwipeDown: return L("3-finger swipe down", "3-Finger-Wischen nach unten")
        case .threeFingerSwipeLeft: return L("3-finger swipe left", "3-Finger-Wischen nach links")
        case .threeFingerSwipeRight: return L("3-finger swipe right", "3-Finger-Wischen nach rechts")
        case .fourFingerSwipeUp: return L("4-finger swipe up", "4-Finger-Wischen nach oben")
        case .fourFingerSwipeDown: return L("4-finger swipe down", "4-Finger-Wischen nach unten")
        case .fourFingerSwipeLeft: return L("4-finger swipe left", "4-Finger-Wischen nach links")
        case .fourFingerSwipeRight: return L("4-finger swipe right", "4-Finger-Wischen nach rechts")
        case .fourFingerPinchIn: return L("4/5-finger pinch", "4/5-Finger zusammenziehen")
        case .fourFingerSpread: return L("4/5-finger spread", "4/5-Finger spreizen")
        }
    }

    /// Actions offered in the editor for this slot
    public var allowedKinds: [GestureAction.Kind] {
        GestureAction.Kind.allCases.filter { k in
            switch k {
            case .contextMenu: return self == .longPress
            case .rotate: return self == .rotate
            default: return true
            }
        }
    }
}

/// Trigger → action table. Stored as a [String: String] dictionary; unknown or missing keys fall back to the defaults.
public struct GestureMap: Codable, Equatable {
    public var actions: [GestureTrigger: GestureAction]

    public static let defaults = GestureMap(actions: [
        .twoFingerTap: .rightClick,
        .twoFingerDoubleTap: .smartZoom,
        .rotate: .rotate,
        .longPress: .contextMenu,
        .threeFingerSwipeUp: .missionControl,
        .threeFingerSwipeDown: .appExpose,
        // like the trackpad: swipe left -> the space to the right
        .threeFingerSwipeLeft: .nextSpace,
        .threeFingerSwipeRight: .previousSpace,
        .fourFingerSwipeUp: .missionControl,
        .fourFingerSwipeDown: .appExpose,
        .fourFingerSwipeLeft: .nextSpace,
        .fourFingerSwipeRight: .previousSpace,
        .fourFingerPinchIn: .launchpad,
        .fourFingerSpread: .showDesktop,
    ])

    public init(actions: [GestureTrigger: GestureAction]) { self.actions = actions }

    public subscript(_ t: GestureTrigger) -> GestureAction {
        get { actions[t] ?? GestureMap.defaults.actions[t] ?? GestureAction.none }
        set { actions[t] = newValue }
    }

    public var isDefault: Bool { GestureTrigger.allCases.allSatisfy { self[$0] == GestureMap.defaults[$0] } }

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode([String: String].self)) ?? [:]
        var a = GestureMap.defaults.actions
        for (k, v) in raw {
            if let t = GestureTrigger(rawValue: k), let act = GestureAction(rawValue: v) { a[t] = act }
        }
        actions = a
    }

    public func encode(to encoder: Encoder) throws {
        var raw: [String: String] = [:]
        for (k, v) in actions { raw[k.rawValue] = v.rawValue }
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

/// Carries out an action through an EventSink using public routes (system shortcuts, opening apps).
public enum GestureActionRunner {
    /// Arrow keys carry the fn/numeric-pad flags like on a real keyboard – without them macOS sometimes ignores
    /// synthetic Ctrl+arrow for Spaces / Mission Control.
    static let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
    public static let f11: CGKeyCode = 103

    /// Launchpad until macOS 15; macOS 26+ replaced it with the Apps app.
    public static let launchpadCandidates = ["/System/Applications/Launchpad.app", "/System/Applications/Apps.app"]

    /// `.rotate` is continuous and handled by the engine; `.contextMenu` needs the engine's delegate –
    /// run directly it falls back to a right click.
    public static func run(_ action: GestureAction, on sink: EventSink, at point: CGPoint) {
        switch action {
        case .none, .rotate: break
        case .missionControl: sink.key(Key.up, flags: arrowFlags)
        case .appExpose: sink.key(Key.down, flags: arrowFlags)
        case .previousSpace: sink.key(Key.left, flags: arrowFlags)
        case .nextSpace: sink.key(Key.right, flags: arrowFlags)
        case .launchpad: sink.openApp(launchpadCandidates)
        case .showDesktop: sink.key(f11, flags: .maskSecondaryFn)   // default "Show Desktop" shortcut F11
        case .smartZoom: sink.smartZoom(at: point)
        case .leftClick: sink.click(point, right: false, clicks: 1)
        case .rightClick, .contextMenu: sink.click(point, right: true, clicks: 1)
        case .middleClick: sink.middleClick(point)
        case .shortcut(let k): if k.isSet { sink.key(CGKeyCode(k.keyCode), flags: k.flags) }
        case .openApp(let p): if !p.isEmpty { sink.openApp([p]) }
        }
    }
}

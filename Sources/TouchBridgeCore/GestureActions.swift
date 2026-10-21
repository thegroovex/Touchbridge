import CoreGraphics
import Foundation

/// What a multi-finger gesture does. Codable so the phase-2 gesture editor can remap triggers.
public enum GestureAction: String, Codable, CaseIterable {
    case none, missionControl, appExpose, previousSpace, nextSpace, launchpad, showDesktop, smartZoom

    public var title: String {
        switch self {
        case .none: return L("Nothing", "Nichts")
        case .missionControl: return "Mission Control"
        case .appExpose: return L("App Exposé", "App-Exposé")
        case .previousSpace: return L("Space to the left", "Space links davon")
        case .nextSpace: return L("Space to the right", "Space rechts davon")
        case .launchpad: return L("Launchpad / Apps", "Launchpad / Apps")
        case .showDesktop: return L("Show desktop", "Schreibtisch anzeigen")
        case .smartZoom: return L("Smart zoom", "Intelligentes Zoomen")
        }
    }
}

/// Which gesture was recognised.
public enum GestureTrigger: String, Codable, CaseIterable {
    case threeFingerSwipeUp, threeFingerSwipeDown, threeFingerSwipeLeft, threeFingerSwipeRight
    case fourFingerSwipeUp, fourFingerSwipeDown, fourFingerSwipeLeft, fourFingerSwipeRight
    case fourFingerPinchIn, fourFingerSpread
    case twoFingerDoubleTap

    public var title: String {
        switch self {
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
        case .twoFingerDoubleTap: return L("2-finger double tap", "2-Finger-Doppeltippen")
        }
    }
}

/// Trigger → action table. Stored as a [String: String] dictionary; unknown or missing keys fall back to the defaults.
public struct GestureMap: Codable, Equatable {
    public var actions: [GestureTrigger: GestureAction]

    public static let defaults = GestureMap(actions: [
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
        .twoFingerDoubleTap: .smartZoom,
    ])

    public init(actions: [GestureTrigger: GestureAction]) { self.actions = actions }

    public subscript(_ t: GestureTrigger) -> GestureAction {
        get { actions[t] ?? GestureMap.defaults.actions[t] ?? GestureAction.none }
        set { actions[t] = newValue }
    }

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

    public static func run(_ action: GestureAction, on sink: EventSink, at point: CGPoint) {
        switch action {
        case .none: break
        case .missionControl: sink.key(Key.up, flags: arrowFlags)
        case .appExpose: sink.key(Key.down, flags: arrowFlags)
        case .previousSpace: sink.key(Key.left, flags: arrowFlags)
        case .nextSpace: sink.key(Key.right, flags: arrowFlags)
        case .launchpad: sink.openApp(launchpadCandidates)
        case .showDesktop: sink.key(f11, flags: .maskSecondaryFn)   // default "Show Desktop" shortcut F11
        case .smartZoom: sink.smartZoom(at: point)
        }
    }
}

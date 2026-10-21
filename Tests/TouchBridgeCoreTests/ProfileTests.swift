import XCTest
@testable import TouchBridgeCore

/// App profiles: resolution, editing, export/import (0.4 phase 3)
final class ProfileTests: XCTestCase {
    override func setUp() { L10n.language = .english }

    struct Settings: ProfileTunable, Equatable {
        var gestures = GestureMap.defaults
        var nativeZoom = true
        var invertScroll = false
        var scrollGain = 1.0
        var oneFingerScroll = false
        var momentumScroll = true
        var smartTarget = true
        var contextMenu = true
        var longPressDuration = 0.5
    }

    private func midiMap() -> GestureMap {
        var m = GestureMap.defaults
        m[.threeFingerSwipeUp] = .none
        m[.twoFingerTap] = .shortcut(KeyCombo(keyCode: 49, modifiers: 0))
        return m
    }

    func testApplyOverridesOnlySetValues() {
        let p = AppProfile(name: "Live", bundleID: "com.ableton.live", gestures: midiMap(),
                           overrides: ProfileOverrides(nativeZoom: false, scrollGain: 2.4, longPressDuration: 9))
        let base = Settings(invertScroll: true, momentumScroll: false)
        let r = p.apply(to: base)
        XCTAssertEqual(r.gestures, midiMap())
        XCTAssertFalse(r.nativeZoom)
        XCTAssertEqual(r.scrollGain, 2.4)
        XCTAssertEqual(r.longPressDuration, 2, "clamped")
        XCTAssertTrue(r.invertScroll, "not overridden: global value")
        XCTAssertFalse(r.momentumScroll, "not overridden: global value")
        XCTAssertEqual(p.overrides.count, 3)
    }

    func testAutomaticResolutionByBundleID() {
        var s = ProfileStore()
        let live = s.add(name: "Live", bundleID: "com.ableton.live", gestures: midiMap())
        s.add(name: "Manual", bundleID: nil)
        XCTAssertEqual(s.active(frontmostBundleID: "com.ableton.live")?.id, live.id)
        XCTAssertEqual(s.active(frontmostBundleID: "COM.Ableton.Live")?.id, live.id, "case-insensitive")
        XCTAssertNil(s.active(frontmostBundleID: "com.apple.Safari"))
        XCTAssertNil(s.active(frontmostBundleID: nil))
        let g = Settings()
        XCTAssertEqual(s.effective(g, frontmostBundleID: "com.apple.Safari"), g, "default profile = global settings")
        XCTAssertEqual(s.effective(g, frontmostBundleID: "com.ableton.live").gestures, midiMap())
    }

    func testManualSelectionWins() {
        var s = ProfileStore()
        let live = s.add(name: "Live", bundleID: "com.ableton.live")
        let manual = s.add(name: "Presentation", bundleID: nil)
        s.selection = .profile(manual.id)
        XCTAssertEqual(s.active(frontmostBundleID: "com.ableton.live")?.id, manual.id)
        s.selection = .defaultProfile
        XCTAssertNil(s.active(frontmostBundleID: "com.ableton.live"))
        s.selection = .automatic
        XCTAssertEqual(s.active(frontmostBundleID: "com.ableton.live")?.id, live.id)
        // dangling manual selection falls back to automatic
        s.selection = .profile(UUID())
        XCTAssertEqual(s.active(frontmostBundleID: "com.ableton.live")?.id, live.id)
    }

    func testSelectionRawValues() {
        let id = UUID()
        for sel in [ProfileSelection.automatic, .defaultProfile, .profile(id)] {
            XCTAssertEqual(ProfileSelection(rawValue: sel.rawValue), sel)
        }
        XCTAssertEqual(ProfileSelection(rawValue: "garbage"), .automatic)
        XCTAssertEqual(ProfileSelection(rawValue: "profile:not-a-uuid"), .automatic)
    }

    func testAddDuplicateDelete() {
        var s = ProfileStore()
        let a = s.add(name: "Live", bundleID: "com.ableton.live")
        let again = s.add(name: "Other", bundleID: "com.ableton.live")
        XCTAssertEqual(again.id, a.id, "one automatic profile per app")
        XCTAssertEqual(s.profiles.count, 1)
        let m1 = s.add(name: "Manual", bundleID: nil)
        let m2 = s.add(name: "Manual", bundleID: "  ")
        XCTAssertEqual(m1.name, "Manual")
        XCTAssertEqual(m2.name, "Manual 2")
        XCTAssertNil(m2.bundleID, "blank bundle id = manual")
        let d = s.duplicate(a.id)
        XCTAssertEqual(d?.name, "Live copy")
        XCTAssertNil(d?.bundleID, "copy is manual so the app keeps one automatic profile")
        XCTAssertEqual(s.profiles.map { $0.name }, ["Live", "Live copy", "Manual", "Manual 2"])
        s.selection = .profile(m1.id)
        s.delete(m1.id)
        XCTAssertEqual(s.selection, .automatic)
        XCTAssertNil(s[m1.id])
        XCTAssertEqual(s.profiles.count, 3)
    }

    func testUpdateKeepsOneProfilePerApp() {
        var s = ProfileStore()
        s.add(name: "Live", bundleID: "com.ableton.live")
        var m = s.add(name: "Manual", bundleID: nil)
        m.bundleID = "com.ableton.live"
        s.update(m)
        XCTAssertNil(s[m.id]?.bundleID, "second profile for the same app becomes manual")
    }

    func testPersistenceRoundTrip() throws {
        var s = ProfileStore()
        let p = s.add(name: "Live", bundleID: "com.ableton.live", appPath: "/Applications/Ableton Live 12 Suite.app", gestures: midiMap())
        var q = p
        q.overrides = ProfileOverrides(invertScroll: true, smartTarget: false)
        s.update(q)
        s.selection = .profile(p.id)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ProfileStore.self, from: data)
        XCTAssertEqual(back, s)
    }

    func testTolerantDecoding() throws {
        let json = #"{"profiles":[{"name":"X","bundleID":"a.b","gestures":{"twoFingerTap":"middleClick"}}],"selection":"profile:00000000-0000-0000-0000-000000000000"}"#
        let s = try JSONDecoder().decode(ProfileStore.self, from: Data(json.utf8))
        XCTAssertEqual(s.profiles.count, 1)
        XCTAssertEqual(s.profiles[0].gestures[.twoFingerTap], .middleClick)
        XCTAssertEqual(s.profiles[0].gestures[.threeFingerSwipeUp], .missionControl, "missing slots = defaults")
        XCTAssertEqual(s.profiles[0].overrides, ProfileOverrides())
        XCTAssertEqual(s.selection, .automatic, "selection of an unknown profile is dropped")
        XCTAssertEqual(try JSONDecoder().decode(ProfileStore.self, from: Data("{}".utf8)), ProfileStore())
    }

    func testExportIsVersioned() throws {
        var s = ProfileStore()
        s.add(name: "Live", bundleID: "com.ableton.live", gestures: midiMap())
        let data = try s.exportData()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["format"] as? String, "touchbridge-profiles")
        XCTAssertEqual(obj?["version"] as? Int, 1)
        XCTAssertEqual(try ProfileStore.decodeExport(data), s.profiles)
    }

    func testImportErrors() {
        XCTAssertThrowsError(try ProfileStore.decodeExport(Data("[1,2]".utf8))) {
            XCTAssertEqual($0 as? ProfileStore.ImportError, .notAProfileFile)
        }
        XCTAssertThrowsError(try ProfileStore.decodeExport(Data(#"{"format":"other","version":1,"profiles":[]}"#.utf8))) {
            XCTAssertEqual($0 as? ProfileStore.ImportError, .notAProfileFile)
        }
        XCTAssertThrowsError(try ProfileStore.decodeExport(Data(#"{"format":"touchbridge-profiles","version":99,"profiles":[]}"#.utf8))) {
            XCTAssertEqual($0 as? ProfileStore.ImportError, .unsupportedVersion(99))
        }
        XCTAssertThrowsError(try ProfileStore.decodeExport(Data(#"{"format":"touchbridge-profiles","version":1,"profiles":[]}"#.utf8))) {
            XCTAssertEqual($0 as? ProfileStore.ImportError, .empty)
        }
        XCTAssertEqual(ProfileStore.ImportError.unsupportedVersion(2).description,
                       "Profile file version 2 is newer than this TouchBridge supports – please update.")
    }

    func testImportReplacesSameAppAndAddsOthers() throws {
        var mine = ProfileStore()
        let live = mine.add(name: "Live", bundleID: "com.ableton.live")
        mine.add(name: "Manual", bundleID: nil)

        var theirs = ProfileStore()
        theirs.add(name: "Live (shared)", bundleID: "com.ableton.live", gestures: midiMap())
        theirs.add(name: "Manual", bundleID: nil)
        theirs.add(name: "Logic", bundleID: "com.apple.logic10")

        let r = try mine.importData(try theirs.exportData())
        XCTAssertEqual(r.added, 2)
        XCTAssertEqual(r.replaced, 1)
        XCTAssertEqual(mine[live.id]?.name, "Live (shared)", "replaced in place, local id kept")
        XCTAssertEqual(mine[live.id]?.gestures, midiMap())
        XCTAssertEqual(mine.profiles.map { $0.name }, ["Live (shared)", "Manual", "Manual 2", "Logic"])
        XCTAssertEqual(Set(mine.profiles.map { $0.id }).count, 4)
    }

    func testImportSameFileTwiceGetsNewIDs() throws {
        var s = ProfileStore()
        s.add(name: "Manual", bundleID: nil)
        let data = try s.exportData()
        try s.importData(data)
        XCTAssertEqual(s.profiles.count, 2)
        XCTAssertNotEqual(s.profiles[0].id, s.profiles[1].id)
    }

    func testFrontmostIgnoresOwnApp() {
        let own = "com.groovex.touchbridge.app"
        XCTAssertEqual(FrontmostApp.next(current: "com.ableton.live", activated: own, own: own), "com.ableton.live")
        XCTAssertEqual(FrontmostApp.next(current: "com.ableton.live", activated: "com.apple.Safari", own: own), "com.apple.Safari")
        XCTAssertEqual(FrontmostApp.next(current: "com.ableton.live", activated: nil, own: own), "com.ableton.live")
        XCTAssertEqual(FrontmostApp.next(current: nil, activated: "com.apple.finder", own: nil), "com.apple.finder")
    }

    func testGermanTexts() {
        L10n.language = .german
        defer { L10n.language = .english }
        var s = ProfileStore()
        let p = s.add(name: "Live", bundleID: nil)
        XCTAssertEqual(s.duplicate(p.id)?.name, "Live Kopie")
        XCTAssertEqual(ProfileStore.ImportError.empty.description, "Die Datei enthält keine Profile.")
    }
}

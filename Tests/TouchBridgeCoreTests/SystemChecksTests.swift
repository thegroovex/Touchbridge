import XCTest
@testable import TouchBridgeCore

final class SystemChecksTests: XCTestCase {
    func testInstanceScanIsCaseInsensitiveAndSkipsSelf() {
        let out = "100 TouchBridgeApp\n200 touchbridge\n300 TOUCHBRIDGE-helper\n 400 Finder\nfoo\n"
        let r = InstanceScan.parse(out, ownPID: 100)
        XCTAssertEqual(r, [OtherInstance(pid: 200, name: "touchbridge"), OtherInstance(pid: 300, name: "TOUCHBRIDGE-helper")])
        XCTAssertTrue(InstanceScan.parse("", ownPID: 1).isEmpty)
    }

    func testSeizeMessageOnlyBlamesDuplicateWhenOneExists() {
        let ex = HIDReturnCode.exclusiveAccess
        let dup = HIDOpenMessages.seizeFailure(rc: ex, others: [OtherInstance(pid: 7, name: "touchbridge")], legacyAgent: false)
        XCTAssertTrue(dup.contains("doppelt"), dup)
        XCTAssertTrue(dup.contains("0xE00002C5"), dup)
        let agent = HIDOpenMessages.seizeFailure(rc: ex, others: [], legacyAgent: true)
        XCTAssertTrue(agent.contains("LaunchAgent"), agent)
        let sys = HIDOpenMessages.seizeFailure(rc: ex, others: [], legacyAgent: false)
        XCTAssertFalse(sys.contains("doppelt"), sys)
        XCTAssertTrue(sys.contains("macOS"), sys)
        let perm = HIDOpenMessages.seizeFailure(rc: HIDReturnCode.notPermitted, others: [OtherInstance(pid: 7, name: "x")], legacyAgent: true)
        XCTAssertTrue(perm.contains("Keine Berechtigung"), perm)
        XCTAssertTrue(perm.contains("0xE00002E2"), perm)
        XCTAssertFalse(perm.contains("doppelt"))
        XCTAssertTrue(HIDOpenMessages.openFailure(rc: 0xE00002BC, others: [], legacyAgent: false).contains("0xE00002BC"))
    }

    func testInputMonitoringStateUsesActualResult() {
        // Reports kommen an → wirksam, auch wenn IOHIDCheckAccess etwas anderes meldet
        XCTAssertEqual(InputMonitoringState.evaluate(check: .denied, openRCs: [], reports: 3, asked: true), .working)
        // erteilt, aber Öffnen scheitert mit NotPermitted → veralteter Eintrag
        let stale = InputMonitoringState.evaluate(check: .granted, openRCs: [HIDReturnCode.notPermitted], reports: 0, asked: false)
        XCTAssertEqual(stale, .stale)
        XCTAssertTrue(stale.suggestReset)
        XCTAssertEqual(InputMonitoringState.evaluate(check: .granted, openRCs: [], reports: 0, asked: false), .granted)
        XCTAssertFalse(InputMonitoringState.granted.isProblem)
        XCTAssertEqual(InputMonitoringState.evaluate(check: .unknown, openRCs: [], reports: 0, asked: false), .notDetermined)
        XCTAssertEqual(InputMonitoringState.evaluate(check: .unknown, openRCs: [], reports: 0, asked: true), .missing)
        XCTAssertEqual(InputMonitoringState.evaluate(check: .denied, openRCs: [], reports: 0, asked: false), .missing)
        // Exklusiv-Fehler ist kein Berechtigungsproblem
        XCTAssertEqual(InputMonitoringState.evaluate(check: .granted, openRCs: [HIDReturnCode.exclusiveAccess], reports: 0, asked: true), .granted)
        XCTAssertNil(PermissionTexts.accessibility(trusted: true, asked: true))
        XCTAssertTrue(PermissionTexts.accessibility(trusted: false, asked: true)!.contains("Stale entry"))
    }

    func testSigningPolicy() {
        let leaf = "88:1B:B1:36:49:53:18:26:15:A2:36:96:4E:3A:E7:D6:51:EF:EF:72"
        XCTAssertEqual(SigningPolicy.normalize(leaf), "881BB1364953182615A236964E3AE7D651EFEF72")
        let dr = SigningPolicy.designatedRequirement(identifier: SigningPolicy.appIdentifier, leafSHA1: leaf)
        XCTAssertEqual(dr, "designated => identifier \"com.groovex.touchbridge\" and certificate leaf = H\"881bb1364953182615a236964e3ae7d651efef72\"")
        XCTAssertEqual(SigningPolicy.leafHash(fromRequirement: "Executable=/x\n" + dr), "881BB1364953182615A236964E3AE7D651EFEF72")
        XCTAssertNil(SigningPolicy.leafHash(fromRequirement: "designated => cdhash H\"0123\""))
        XCTAssertTrue(SigningPolicy.checkUpdate(currentLeaf: nil, newLeaf: nil).isAllowed)
        XCTAssertTrue(SigningPolicy.checkUpdate(currentLeaf: nil, newLeaf: "AB").isAllowed)
        XCTAssertTrue(SigningPolicy.checkUpdate(currentLeaf: "881bb1", newLeaf: "881BB1").isAllowed)
        XCTAssertFalse(SigningPolicy.checkUpdate(currentLeaf: "881BB1", newLeaf: nil).isAllowed)
        XCTAssertFalse(SigningPolicy.checkUpdate(currentLeaf: "881BB1", newLeaf: "DEADBE").isAllowed)
    }

    func testOpenTrackerAndDedupe() {
        var t = HIDOpenTracker()
        XCTAssertFalse(t.mustCloseBeforeOpen(1))
        t.opened(1, exclusive: false)
        XCTAssertTrue(t.isOpen(1))
        XCTAssertFalse(t.isExclusive(1))
        XCTAssertTrue(t.mustCloseBeforeOpen(1), "Retry darf kein zweites Open auf ein offenes Interface machen")
        t.closed(1)
        t.opened(1, exclusive: true)
        XCTAssertTrue(t.isExclusive(1))
        // dieselbe Registry-ID aus CopyDevices + Matching-Callback + zweitem Matching-Dict nur einmal
        XCTAssertEqual(HIDOpenTracker.dedupe([0xA, 0xB, 0xA, 0xC, 0xB], known: [0xC]), [0xA, 0xB])
    }

    func testInterfaceRolesAndSummary() {
        XCTAssertEqual(InterfaceRole.classify(usagePairs: [(0x01, 0x02)], hasTouchLayout: true), .touch)
        XCTAssertEqual(InterfaceRole.classify(usagePairs: [(0x0D, 0x04)], hasTouchLayout: false), .touch)
        XCTAssertEqual(InterfaceRole.classify(usagePairs: [(0x01, 0x02), (0x01, 0x01)], hasTouchLayout: false), .mouse)
        XCTAssertEqual(InterfaceRole.classify(usagePairs: [(0xFF00, 0x01)], hasTouchLayout: false), .vendor)
        XCTAssertEqual(InterfaceRole.classify(usagePairs: [(0x0C, 0x01)], hasTouchLayout: false), .other)
        let s = InterfaceStatus.summary([InterfaceStatus(registryID: 3, role: .vendor, exclusive: true),
                                         InterfaceStatus(registryID: 1, role: .mouse, exclusive: false),
                                         InterfaceStatus(registryID: 2, role: .touch, exclusive: true)])
        XCTAssertEqual(s, "3 interfaces: Touch exclusive, Mouse NOT exclusive, Vendor exclusive")
        XCTAssertEqual(InterfaceStatus.summary([]), "no interface open")
    }

    /// Nachbau des ioreg-Befunds am Gerät: drei Interfaces, A doppelt von TouchBridge geöffnet, C mit WindowServer-Event-Pfad.
    func testHolderReportFromIORegPlist() throws {
        func dev(_ id: UInt64, _ children: [[String: Any]], usage: [(Int, Int)]) -> [String: Any] {
            ["IOObjectClass": "AppleUserUSBHostHIDDevice", "IORegistryEntryID": id, "VendorID": 10176, "ProductID": 0x0859,
             "Product": "ANMITE Touch", "PrimaryUsagePage": usage[0].0, "Transport": "USB", "Built-In": false,
             "DeviceUsagePairs": usage.map { ["DeviceUsagePage": $0.0, "DeviceUsage": $0.1] },
             "IORegistryEntryChildren": children]
        }
        let a = dev(0x100098679, [
            ["IOObjectClass": "IOHIDLibUserClient", "IORegistryEntryID": UInt64(1), "IOUserClientCreator": "pid 63268, TouchBridgeApp"],
            ["IOObjectClass": "IOHIDLibUserClient", "IORegistryEntryID": UInt64(2), "IOUserClientCreator": "pid 63268, TouchBridgeApp"],
        ], usage: [(0x0D, 0x04)])
        let b = dev(0x100098677, [], usage: [(0xFF00, 0x01)])
        let c = dev(0x100098675, [
            ["IOObjectClass": "AppleUserHIDEventDriver", "IORegistryEntryID": UInt64(10), "IORegistryEntryChildren": [
                ["IOObjectClass": "AppleUserHIDEventService", "IORegistryEntryID": UInt64(11), "IORegistryEntryChildren": [
                    ["IOObjectClass": "IOHIDEventServiceUserClient", "IORegistryEntryID": UInt64(12), "IOUserClientCreator": "pid 400, WindowServer"]
                ]]
            ]]
        ], usage: [(0x01, 0x02)])
        let other: [String: Any] = ["IOObjectClass": "AppleUserUSBHostHIDDevice", "VendorID": 0x05AC, "ProductID": 1, "PrimaryUsagePage": 1]
        let data = try PropertyListSerialization.data(fromPropertyList: [a, b, c, other], format: .xml, options: 0)
        let r = HIDHolderReport.analyze(plist: data, vid: 0x27C0, pid: 0x0859)
        XCTAssertEqual(r.interfaces.count, 3)
        XCTAssertEqual(r.duplicateOwnClients(ownPID: 63268).map(\.registryID), [0x100098679])
        let ci = r.interfaces[2]
        XCTAssertEqual(ci.drivers, ["AppleUserHIDEventDriver", "AppleUserHIDEventService"])
        XCTAssertEqual(ci.userClients, ["pid 400, WindowServer <IOHIDEventServiceUserClient>"])
        XCTAssertEqual(Set(ci.descendantIDs), [0x100098675, 10, 11, 12])
        XCTAssertEqual(r.interfaces[1].usagePairs, ["0xFF00/0x01"])
        let holders = r.likelyHolders(ownPID: 63268)
        XCTAssertTrue(holders.contains("pid 400, WindowServer <IOHIDEventServiceUserClient>"))
        XCTAssertTrue(holders.contains("AppleUserHIDEventDriver"))
        XCTAssertFalse(holders.contains { $0.contains("63268") })
        let lines = r.lines(ownPID: 63268).joined(separator: "\n")
        XCTAssertTrue(lines.contains("❌ FEHLER: TouchBridge hält 2 Clients"), lines)
        XCTAssertTrue(lines.contains("(TouchBridge selbst)"))
        XCTAssertTrue(HIDHolderReport.analyze(plist: Data("kaputt".utf8), vid: 1, pid: 1).interfaces.isEmpty)
    }

    func testSystemPointerFilter() {
        let f = SystemPointerFilter()
        let ids: Set<UInt64> = [10, 11]
        func ev(_ ud: Int64 = 0, pid: Int64 = 0, sender: UInt64? = nil, t: Double = 100) -> SystemPointerFilter.EventInfo {
            .init(userData: ud, sourcePID: pid, senderID: sender, time: t)
        }
        XCTAssertEqual(f.verdict(ev(SystemPointerFilter.marker, sender: 11), deviceIDs: ids, lastReport: 100, touching: true), .pass)
        XCTAssertEqual(f.verdict(ev(pid: 123), deviceIDs: ids, lastReport: 100, touching: true), .pass)
        XCTAssertEqual(f.verdict(ev(sender: 11), deviceIDs: ids, lastReport: nil, touching: false), .dropSender)
        XCTAssertEqual(f.verdict(ev(sender: 99), deviceIDs: ids, lastReport: 100, touching: true), .pass, "andere Maus geht durch")
        XCTAssertEqual(f.verdict(ev(t: 100.05), deviceIDs: ids, lastReport: 100, touching: false), .dropCorrelated)
        XCTAssertEqual(f.verdict(ev(t: 101), deviceIDs: ids, lastReport: 100, touching: false), .pass)
        XCTAssertEqual(f.verdict(ev(t: 101), deviceIDs: ids, lastReport: 100, touching: true), .dropCorrelated)
        XCTAssertEqual(f.verdict(ev(t: 101), deviceIDs: ids, lastReport: nil, touching: false), .pass)
    }
}

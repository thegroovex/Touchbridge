import XCTest
@testable import TouchBridgeCore

final class UpdateTests: XCTestCase {
    func testSemVerParsingAndOrder() {
        XCTAssertEqual(SemVer("v0.2.0")?.description, "0.2.0")
        XCTAssertEqual(SemVer("1.2")?.description, "1.2.0")
        XCTAssertEqual(SemVer("0.3.0-preview.1+abc")?.description, "0.3.0-preview.1")
        XCTAssertNil(SemVer("dev"))
        XCTAssertNil(SemVer("1.2.3.4"))
        XCTAssertNil(SemVer("1.x"))
        XCTAssertNil(SemVer("1.0.0-"))
        let order = ["0.1.0", "0.2.0-alpha", "0.2.0-alpha.1", "0.2.0-alpha.beta", "0.2.0-beta.2", "0.2.0-beta.11",
                     "0.2.0-rc.1", "0.2.0", "0.2.1", "0.10.0", "1.0.0"].map { SemVer($0)! }
        XCTAssertEqual(order, order.sorted())
        for (a, b) in zip(order, order.dropFirst()) { XCTAssertLessThan(a, b, "\(a) < \(b)") }
        XCTAssertEqual(SemVer("v1.0.0"), SemVer("1.0.0+build7"))
    }

    func rel(_ tag: String, pre: Bool = false, draft: Bool = false, dmg: Bool = true) -> ReleaseInfo {
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        var assets = [ReleaseAsset(name: "SHA256SUMS.txt", url: "https://x/\(tag)/SHA256SUMS.txt")]
        if dmg { assets.append(ReleaseAsset(name: "TouchBridge-\(v).dmg", url: "https://x/\(tag)/TouchBridge-\(v).dmg", size: 1)) }
        return ReleaseInfo(tagName: tag, body: "Notes \(tag)", prerelease: pre, draft: draft, assets: assets)
    }

    func testPickUpdate() {
        let list = [rel("v0.1.0", pre: true), rel("v0.2.0", pre: true), rel("v0.3.0", pre: true),
                    rel("v0.4.0", draft: true), rel("v0.3.5", pre: true, dmg: false), rel("v0.2.5")]
        XCTAssertEqual(UpdateLogic.pickUpdate(list, current: "0.2.0", includePrereleases: true)?.tagName, "v0.3.0")
        XCTAssertEqual(UpdateLogic.pickUpdate(list, current: "0.2.0", includePrereleases: false)?.tagName, "v0.2.5")
        XCTAssertNil(UpdateLogic.pickUpdate(list, current: "0.3.0", includePrereleases: true))
        XCTAssertEqual(UpdateLogic.pickUpdate(list, current: "0.2.0", includePrereleases: true, skipped: "0.3.0")?.tagName, "v0.2.5")
        XCTAssertEqual(UpdateLogic.pickUpdate(list, current: "dev", includePrereleases: true)?.tagName, "v0.3.0")
        // Tag mit Pre-Release-Suffix gilt als Vorabversion, auch wenn das Flag fehlt
        XCTAssertNil(UpdateLogic.pickUpdate([rel("v0.9.0-beta.1")], current: "0.2.0", includePrereleases: false))
        XCTAssertEqual(UpdateLogic.pickUpdate([rel("v0.3.0-preview.2"), rel("v0.3.0-preview.10")],
                                              current: "0.3.0-preview.2", includePrereleases: true)?.tagName, "v0.3.0-preview.10")
    }

    func testAssetSelection() {
        let r = ReleaseInfo(tagName: "v0.3.0", assets: [ReleaseAsset(name: "TouchBridge-0.3.0.dmg", url: "u1"),
                                                         ReleaseAsset(name: "TouchBridge-0.2.0.dmg", url: "u0"),
                                                         ReleaseAsset(name: "SHA256SUMS.txt", url: "s")])
        XCTAssertEqual(UpdateLogic.dmgAsset(r)?.browserDownloadURL, "u1")
        XCTAssertEqual(UpdateLogic.sumsAsset(r)?.browserDownloadURL, "s")
        let single = ReleaseInfo(tagName: "v1.0.0", assets: [ReleaseAsset(name: "TouchBridge-1.0.0-universal.dmg", url: "u")])
        XCTAssertEqual(UpdateLogic.dmgAsset(single)?.browserDownloadURL, "u")
        XCTAssertNil(UpdateLogic.sumsAsset(single))
        XCTAssertNil(UpdateLogic.dmgAsset(ReleaseInfo(tagName: "v1.0.0")))
    }

    func testSHA256SumsParsing() {
        let h1 = String(repeating: "a", count: 64), h2 = String(repeating: "B", count: 64)
        let text = """
        \(h1)  TouchBridge-0.3.0.dmg
        \(h2) *dist/SHA-test.zip
        # Kommentar
        kaputt  datei
        """
        let m = UpdateLogic.parseSHA256Sums(text)
        XCTAssertEqual(m["TouchBridge-0.3.0.dmg"], h1)
        XCTAssertEqual(m["SHA-test.zip"], h2.lowercased())
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(UpdateLogic.hex([0x00, 0xAB, 0x10]), "00ab10")
    }

    func testDecodeGitHubJSON() throws {
        let json = """
        [{"tag_name":"v0.2.0","name":"TouchBridge 0.2.0 Preview","body":"- MIDI","prerelease":true,"draft":false,
          "html_url":"https://github.com/thegroovex/Touchbridge/releases/tag/v0.2.0",
          "assets":[{"name":"TouchBridge-0.2.0.dmg","size":123,"browser_download_url":"https://github.com/d/TouchBridge-0.2.0.dmg"},
                    {"name":"SHA256SUMS.txt","size":90,"browser_download_url":"https://github.com/d/SHA256SUMS.txt"}]}]
        """
        let r = try UpdateLogic.decodeReleases(Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].version, SemVer("0.2.0"))
        XCTAssertTrue(r[0].prerelease)
        XCTAssertEqual(UpdateLogic.dmgAsset(r[0])?.size, 123)
    }

    func testCheckDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdateLogic.isCheckDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateLogic.isCheckDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateLogic.isCheckDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
    }
}

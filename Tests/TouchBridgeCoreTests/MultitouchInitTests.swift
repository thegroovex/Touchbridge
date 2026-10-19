import XCTest
@testable import TouchBridgeCore

final class USBControlRequestTests: XCTestCase {
    func testSetIdleSetup() {
        let r = USBControlRequest.setIdle(interface: 2)
        XCTAssertEqual(r.setupBytes, [0x21, 0x0A, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
        XCTAssertFalse(r.isIn)
        XCTAssertEqual(r.interfaceNumber, 2)
        XCTAssertEqual(USBControlRequest.setIdle(interface: 0, duration: 4, reportID: 7).wValue, 0x0407)
    }

    func testFeatureReports() {
        let set = USBControlRequest.setReport(.feature, id: 0x21, interface: 0, data: [0x21, 0x02, 0x00])
        XCTAssertEqual(set.setupBytes, [0x21, 0x09, 0x21, 0x03, 0x00, 0x00, 0x03, 0x00])   // wValue 0x0321
        XCTAssertEqual(set.data, [0x21, 0x02, 0x00])
        let get = USBControlRequest.getReport(.feature, id: 0x21, interface: 1, length: 3)
        XCTAssertEqual(get.setupBytes, [0xA1, 0x01, 0x21, 0x03, 0x01, 0x00, 0x03, 0x00])
        XCTAssertTrue(get.isIn)
        XCTAssertEqual(USBControlRequest.getReport(.input, id: 13, interface: 0, length: 64).wValue, 0x010D)
        XCTAssertEqual(USBControlRequest.setProtocol(interface: 1).setupBytes, [0x21, 0x0B, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00])
        XCTAssertTrue(set.summary.contains("SET_REPORT Feature 0x21 IF 0 [21 02 00]"))
    }
}

final class LinuxInitTests: XCTestCase {
    let d = HIDDescriptor(bytes: Fixtures.anmite)

    func testSequenceOrderLikeLinux() {
        // SET_IDLE je Interface (aufsteigend), dann Contact Count Max lesen, Input Mode lesen, Input Mode 2 setzen
        let seq = LinuxHIDInit.sequence(interfaces: [2, 0, 1], digitizer: 0, descriptor: d)
        XCTAssertEqual(seq.map(\.bRequest), [0x0A, 0x0A, 0x0A, 0x01, 0x01, 0x09])
        XCTAssertEqual(seq.prefix(3).map(\.interfaceNumber), [0, 1, 2])
        XCTAssertEqual(seq[3].wValue, 0x030A)
        XCTAssertEqual(seq[3].wLength, 2)          // [0A max]
        XCTAssertEqual(seq[4].wValue, 0x0321)
        XCTAssertEqual(seq[4].wLength, 3)          // [21 mode index]
        XCTAssertEqual(seq[5].data, [0x21, 0x02, 0x00])
        XCTAssertTrue(seq.dropFirst(3).allSatisfy { $0.interfaceNumber == 0 })
    }

    func testInputModePreservesPlausibleAnswer() {
        // Device Identifier aus der Antwort bleibt erhalten (wie hid-multitouch)
        let m = d.inputModeReport(mode: 2, preserving: [0x21, 0x01, 0x05])
        XCTAssertEqual(m?.bytes, [0x21, 0x02, 0x05])
        XCTAssertEqual(m?.preserved, true)
        XCTAssertEqual(LinuxHIDInit.inputModeSet(digitizer: 0, descriptor: d, current: [0x21, 0x00, 0x03])?.data, [0x21, 0x02, 0x03])
    }

    func testInputModeRejectsGarbage() {
        // Antwort der Anmite-Firmware über IOHID: Descriptor-Bytes statt Report
        XCTAssertFalse(d.isPlausibleFeature([0xA1, 0x01, 0x21], reportID: 0x21, length: 3))
        let m = d.inputModeReport(mode: 2, preserving: [0xA1, 0x01, 0x21])
        XCTAssertEqual(m?.bytes, [0x21, 0x02, 0x00])
        XCTAssertEqual(m?.preserved, false)
        XCTAssertFalse(d.isPlausibleFeature([0x21, 0x02], reportID: 0x21, length: 3))        // zu kurz
        XCTAssertFalse(d.isPlausibleFeature([0x21, 0x02, 0x30], reportID: 0x21, length: 3))  // Index > 10
        XCTAssertTrue(d.isPlausibleFeature([0x0A, 0x0F], reportID: 0x0A, length: 2))         // Contact Count Max 15
    }

    func testNoInputModeNoSet() {
        let plain = HIDDescriptor(bytes: Fixtures.touchScreen(fingers: 2))
        XCTAssertNil(LinuxHIDInit.inputModeSet(digitizer: 0, descriptor: plain, current: nil))
        XCTAssertEqual(LinuxHIDInit.sequence(interfaces: [0], digitizer: 0, descriptor: plain).map(\.bRequest), [0x0A])
    }
}

final class MultitouchSequenceTests: XCTestCase {
    func testVerdict() {
        XCTAssertEqual(MultitouchVerdict.evaluate(digitizerReports: 3, pointerReports: 40), .multitouch)
        XCTAssertEqual(MultitouchVerdict.evaluate(digitizerReports: 0, pointerReports: 40), .pointerOnly)
        XCTAssertEqual(MultitouchVerdict.evaluate(digitizerReports: 0, pointerReports: 0), .noTouch)
    }

    func testRawValuesStable() {
        // gespeichert in den Einstellungen – Werte dürfen sich nicht ändern
        XCTAssertEqual(MultitouchSequence.allCases.map(\.rawValue),
                       ["hid-input-get", "hid-feature", "usb-linux-init", "usb-interface-linux-init", "usb-reenumerate-init"])
        XCTAssertEqual(MultitouchSequence(rawValue: "usb-linux-init"), .usbLinuxInit)
        XCTAssertTrue(MultitouchSequence.usbReenumerateInit.reconnects)
        XCTAssertFalse(MultitouchSequence.hidFeature.reconnects)
    }
}

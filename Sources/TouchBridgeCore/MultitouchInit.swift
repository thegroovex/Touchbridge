import Foundation

// Multitouch-Experimente: USB-Control-Requests (HID-Klasse) und die Init-Reihenfolge von Linux
// (usbhid + hid-multitouch), plattformneutral und testbar. Die Ausführung liegt in TouchBridgeKit.

/// Ein USB-Control-Request auf dem Default-Endpoint (Setup-Paket + ggf. Daten).
public struct USBControlRequest: Equatable {
    public enum HIDReportType: UInt8 { case input = 1, output = 2, feature = 3 }

    public let name: String
    public let bmRequestType: UInt8
    public let bRequest: UInt8
    public let wValue: UInt16
    public let wIndex: UInt16
    public let wLength: UInt16
    /// Daten für OUT-Requests (SET_REPORT); bei IN-Requests leer
    public let data: [UInt8]

    public init(name: String, bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, wLength: UInt16, data: [UInt8] = []) {
        self.name = name; self.bmRequestType = bmRequestType; self.bRequest = bRequest
        self.wValue = wValue; self.wIndex = wIndex; self.wLength = wLength; self.data = data
    }

    /// Richtung Gerät -> Host
    public var isIn: Bool { bmRequestType & 0x80 != 0 }
    /// Interface-Nummer bei Klassen-Requests an ein Interface
    public var interfaceNumber: UInt8 { UInt8(wIndex & 0xFF) }

    // HID-Klassen-Requests (HID 1.11, 7.2): bmRequestType 0x21 = Class|Interface|OUT, 0xA1 = Class|Interface|IN
    public static let hidGetReport: UInt8 = 0x01
    public static let hidSetReport: UInt8 = 0x09
    public static let hidSetIdle: UInt8 = 0x0A
    public static let hidSetProtocol: UInt8 = 0x0B

    /// SET_IDLE(duration) – Linux usbhid sendet SET_IDLE(0) an jedes HID-Interface (usbhid_parse → hid_set_idle)
    public static func setIdle(interface: UInt8, duration: UInt8 = 0, reportID: UInt8 = 0) -> USBControlRequest {
        USBControlRequest(name: "SET_IDLE(\(duration)) IF \(interface)", bmRequestType: 0x21, bRequest: hidSetIdle,
                          wValue: UInt16(duration) << 8 | UInt16(reportID), wIndex: UInt16(interface), wLength: 0)
    }

    /// SET_PROTOCOL (0 = Boot, 1 = Report)
    public static func setProtocol(interface: UInt8, report: Bool = true) -> USBControlRequest {
        USBControlRequest(name: "SET_PROTOCOL(\(report ? "Report" : "Boot")) IF \(interface)", bmRequestType: 0x21,
                          bRequest: hidSetProtocol, wValue: report ? 1 : 0, wIndex: UInt16(interface), wLength: 0)
    }

    /// GET_REPORT – `length` inkl. Report-ID-Byte
    public static func getReport(_ type: HIDReportType, id: UInt8, interface: UInt8, length: Int) -> USBControlRequest {
        USBControlRequest(name: "GET_REPORT \(type.label) 0x\(hex2(id)) IF \(interface)", bmRequestType: 0xA1, bRequest: hidGetReport,
                          wValue: UInt16(type.rawValue) << 8 | UInt16(id), wIndex: UInt16(interface),
                          wLength: UInt16(clamping: max(1, length)))
    }

    /// SET_REPORT – `data` inkl. Report-ID-Byte (bei Geräten mit Report-IDs ist es Teil der Daten)
    public static func setReport(_ type: HIDReportType, id: UInt8, interface: UInt8, data: [UInt8]) -> USBControlRequest {
        USBControlRequest(name: "SET_REPORT \(type.label) 0x\(hex2(id)) IF \(interface) [\(data.map(hex2).joined(separator: " "))]",
                          bmRequestType: 0x21, bRequest: hidSetReport,
                          wValue: UInt16(type.rawValue) << 8 | UInt16(id), wIndex: UInt16(interface),
                          wLength: UInt16(clamping: data.count), data: data)
    }

    /// Setup-Paket als 8 Bytes (Little Endian), z. B. für das Protokoll
    public var setupBytes: [UInt8] {
        [bmRequestType, bRequest, UInt8(wValue & 0xFF), UInt8(wValue >> 8), UInt8(wIndex & 0xFF), UInt8(wIndex >> 8),
         UInt8(wLength & 0xFF), UInt8(wLength >> 8)]
    }

    public var summary: String { "\(name)  {\(setupBytes.map(hex2).joined(separator: " "))}" }
}

extension USBControlRequest.HIDReportType {
    public var label: String {
        switch self { case .input: return "Input"; case .output: return "Output"; case .feature: return "Feature" }
    }
}

func hex2(_ b: UInt8) -> String { String(format: "%02X", b) }

// MARK: - Input-Mode-Daten

public extension HIDDescriptor {
    /// Input-Mode-Report mit Modus `mode`; ist `current` ein plausibler GetReport-Inhalt (gleiche Länge, erstes Byte =
    /// Report-ID, alle Felder im logischen Bereich), wird er übernommen und nur das Mode-Feld ersetzt – so wie
    /// hid-multitouch es macht (Device Identifier bleibt erhalten). Sonst die Vorlage aus dem Descriptor.
    func inputModeReport(mode: Int64, preserving current: [UInt8]?) -> (reportID: UInt8, bytes: [UInt8], preserved: Bool)? {
        guard let template = inputModeReport(mode: mode),
              let f = featureFields.first(where: { $0.usagePage == Usage.pageDigitizer && $0.usage == Usage.inputMode && !$0.isConstant })
        else { return nil }
        guard let cur = current, isPlausibleFeature(cur, reportID: template.reportID, length: template.bytes.count) else {
            return (template.reportID, template.bytes, false)
        }
        var out = cur
        f.write(max(f.logicalMin, min(f.logicalMax, mode)), into: &out, base: usesReportIDs ? 1 : 0)
        return (template.reportID, out, true)
    }

    /// Antwort eines Feature-GetReports plausibel? Länge stimmt, Report-ID vorne, alle Felder des Reports im
    /// logischen Bereich. (Die Anmite-Firmware lieferte über IOHID [A1 01 21] – Descriptor-Bytes, nicht plausibel.)
    func isPlausibleFeature(_ bytes: [UInt8], reportID: UInt8, length: Int) -> Bool {
        guard bytes.count == length, length > 0 else { return false }
        if usesReportIDs && bytes[0] != reportID { return false }
        let base = usesReportIDs ? 1 : 0
        for f in featureFields where f.reportID == reportID && !f.isConstant {
            let v = bytes.withUnsafeBufferPointer { f.read($0, base: base) }
            if v < f.logicalMin || v > f.logicalMax { return false }
        }
        return true
    }
}

// MARK: - Linux-Init-Reihenfolge

/// Init-Reihenfolge von Linux beim Einstecken (Android nutzt denselben Kernel-Pfad):
/// 1. usbhid_parse: SET_IDLE(0) an jedes HID-Interface (in Interface-Reihenfolge)
/// 2. hid-multitouch mt_feature_mapping: GET_REPORT Feature „Contact Count Maximum“ (0x0D/0x55)
/// 3. mt_set_modes: Input-Mode-Feature lesen (GET_REPORT), Mode = 2 setzen, ganzen Report zurückschreiben (SET_REPORT)
public enum LinuxHIDInit {
    /// Schritte 1–2 und das Lesen des Input Mode (der SET_REPORT hängt von der Antwort ab: `inputModeSet`).
    public static func prelude(interfaces: [UInt8], digitizer: UInt8, descriptor d: HIDDescriptor) -> [USBControlRequest] {
        var r = interfaces.sorted().map { USBControlRequest.setIdle(interface: $0) }
        if let ccm = d.contactCountMaximumField {
            r.append(.getReport(.feature, id: ccm.reportID, interface: digitizer, length: d.featureReportLength(ccm.reportID)))
        }
        if let im = d.inputModeReport(mode: 2) {
            r.append(.getReport(.feature, id: im.reportID, interface: digitizer, length: im.bytes.count))
        }
        return r
    }

    /// SET_REPORT Input Mode 2; `current` = Antwort des vorherigen GET_REPORT (falls plausibel übernommen)
    public static func inputModeSet(digitizer: UInt8, descriptor d: HIDDescriptor, current: [UInt8]?) -> USBControlRequest? {
        guard let im = d.inputModeReport(mode: 2, preserving: current) else { return nil }
        return .setReport(.feature, id: im.reportID, interface: digitizer, data: im.bytes)
    }

    /// Komplette Sequenz ohne Antwort (Vorlage aus dem Descriptor)
    public static func sequence(interfaces: [UInt8], digitizer: UInt8, descriptor d: HIDDescriptor) -> [USBControlRequest] {
        prelude(interfaces: interfaces, digitizer: digitizer, descriptor: d)
            + [inputModeSet(digitizer: digitizer, descriptor: d, current: nil)].compactMap { $0 }
    }
}

// MARK: - Experimente und gemerkte Sequenz

/// Eine Sequenz, mit der der Multitouch-Modus eingeschaltet werden kann. Die erfolgreiche wird gespeichert und
/// künftig beim Verbinden automatisch angewendet.
public enum MultitouchSequence: String, Codable, CaseIterable {
    /// a) IOHIDDeviceGetReport Input (Linux usbhid_init_reports nachgebildet)
    case hidInputGet = "hid-input-get"
    /// b) GetReport Feature 0x0A/0x21, SetReport 0x21 über IOHID
    case hidFeature = "hid-feature"
    /// c) Linux-Sequenz als direkte USB-Control-Requests (Device-User-Client)
    case usbLinuxInit = "usb-linux-init"
    /// c') dieselbe Sequenz über den Interface-User-Client (Default-Pipe)
    case usbInterfaceLinuxInit = "usb-interface-linux-init"
    /// d) USB-Neu-Enumeration, sofort danach die Linux-Sequenz
    case usbReenumerateInit = "usb-reenumerate-init"
    /// e) IOHIDDeviceSetValue auf das Element Digitizer/Device Mode (0x0D/0x52) = 2 auf jeder Schnittstelle
    ///    (Ansatz aus Shadowhusky/xeneon-toolbox, gleicher Controller 27C0:0859; dort ohne Nachweis als funktionierend beschrieben)
    case hidSetValue = "hid-set-value"

    public var title: String {
        switch self {
        case .hidInputGet: return L("a) GetReport Input (Linux init)", "a) GetReport Input (Linux-Init)")
        case .hidFeature: return L("b) Feature 0x0A/0x21 via IOHID", "b) Feature 0x0A/0x21 über IOHID")
        case .usbLinuxInit: return L("c) USB control: SET_IDLE + Input Mode (device)", "c) USB-Control: SET_IDLE + Input Mode (Gerät)")
        case .usbInterfaceLinuxInit: return L("c') USB control via interface client", "c') USB-Control über Interface-Client")
        case .usbReenumerateInit: return L("d) Re-enumeration + immediate Linux init", "d) Neu-Enumeration + sofort Linux-Init")
        case .hidSetValue: return L("e) IOHIDDeviceSetValue Device Mode = 2 (Xeneon Toolbox approach)", "e) IOHIDDeviceSetValue Device Mode = 2 (Xeneon-Toolbox-Ansatz)")
        }
    }

    /// Darf beim Verbinden automatisch laufen, ohne eine Schleife auszulösen (d nur einmal je Verbindung)
    public var reconnects: Bool { self == .usbReenumerateInit }
}

/// Bewertung eines Schritts anhand der Report-Zähler während der Wartezeit
public enum MultitouchVerdict: Equatable {
    case multitouch          // Report 13 (Digitizer) kam an
    case pointerOnly         // berührt (Maus-Reports), aber kein Digitizer-Report
    case noTouch             // gar nichts – Nutzer hat nicht getippt

    public static func evaluate(digitizerReports: Int, pointerReports: Int) -> MultitouchVerdict {
        if digitizerReports > 0 { return .multitouch }
        return pointerReports > 0 ? .pointerOnly : .noTouch
    }

    public var text: String {
        switch self {
        case .multitouch: return "✅ Digitizer reports (report 13) received – multitouch mode active"
        case .pointerOnly: return "✗ mouse reports only (report 7) – still in mouse mode"
        case .noTouch: return "– no reports (not touched?)"
        }
    }
}

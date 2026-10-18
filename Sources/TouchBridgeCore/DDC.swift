/// DDC/CI-Pakete (VESA MCCS) für Helligkeit, Kontrast, Lautstärke über I²C-Adresse 0x37.
/// Die Pakete sind so aufgebaut, wie sie an IOAVServiceWriteI2C(service, 0x37, 0x51, …) übergeben werden.
public enum DDC {
    public enum VCP: UInt8 {
        case brightness = 0x10
        case contrast = 0x12
        case inputSource = 0x60
        case volume = 0x62
    }

    public static let chipAddress: UInt32 = 0x37
    public static let dataAddress: UInt32 = 0x51
    static let destination: UInt8 = 0x6E   // 0x37 << 1
    static let hostAddress: UInt8 = 0x50

    /// "Set VCP Feature": 6 Bytes inkl. Prüfsumme.
    public static func setPacket(vcp: UInt8, value: UInt16) -> [UInt8] {
        var p: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
        p.append(p.reduce(destination ^ UInt8(dataAddress), ^))
        return p
    }

    /// "Get VCP Feature": 4 Bytes inkl. Prüfsumme.
    public static func getPacket(vcp: UInt8) -> [UInt8] {
        var p: [UInt8] = [0x82, 0x01, vcp]
        p.append(p.reduce(destination ^ UInt8(dataAddress), ^))
        return p
    }

    /// Antwort auf "Get VCP Feature". Erwartet [0x6E] 0x88 0x02 result vcp type maxH maxL curH curL chk;
    /// das führende Quelladress-Byte darf fehlen (je nach I²C-Treiber).
    public static func parseReply(_ b: [UInt8], vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard b.count >= 10 else { return nil }
        for i in 0...(b.count - 10) where b[i] == 0x88 && b[i + 1] == 0x02 && b[i + 3] == vcp {
            guard b[i + 2] == 0x00 else { return nil }   // 0x01 = VCP nicht unterstützt
            let chk = b[i..<(i + 9)].reduce(hostAddress ^ destination, ^)
            guard chk == b[i + 9] else { return nil }
            let maxV = UInt16(b[i + 5]) << 8 | UInt16(b[i + 6])
            let cur = UInt16(b[i + 7]) << 8 | UInt16(b[i + 8])
            return (cur, maxV)
        }
        return nil
    }

    /// Hilfsfunktion für Tests / Simulatoren: gültige Antwort erzeugen.
    public static func makeReply(vcp: UInt8, current: UInt16, max: UInt16) -> [UInt8] {
        var b: [UInt8] = [destination, 0x88, 0x02, 0x00, vcp, 0x00,
                          UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
        b.append(b.reduce(hostAddress, ^))
        return b
    }
}

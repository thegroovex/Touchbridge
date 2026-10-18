import CoreGraphics

/// Abbildung roher Digitizer-Koordinaten auf den Bildschirm: Normalisieren, Drehen, Spiegeln, Skalieren.
public struct TouchMapping: Equatable {
    /// Drehung des Panels im Uhrzeigersinn in Grad (0, 90, 180, 270) – passend zur macOS-Bildschirmdrehung.
    public var rotation: Int
    public var flipX: Bool
    public var flipY: Bool
    /// Achsen vor der Drehung tauschen (für exotische Panels, CLI --swap-xy).
    public var swapXY: Bool

    public init(rotation: Int = 0, flipX: Bool = false, flipY: Bool = false, swapXY: Bool = false) {
        self.rotation = rotation; self.flipX = flipX; self.flipY = flipY; self.swapXY = swapXY
    }

    public static func normalize(_ v: Int64, min lo: Int64, max hi: Int64) -> CGFloat {
        let span = Double(hi - lo)
        guard span > 0 else { return 0 }
        return CGFloat(Swift.min(1, Swift.max(0, Double(v - lo) / span)))
    }

    /// Normalisierter Panelpunkt (0…1) -> normalisierter Bildschirmpunkt (0…1).
    public func apply(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
        var x = nx, y = ny
        if swapXY { swap(&x, &y) }
        switch ((rotation % 360) + 360) % 360 {
        case 90: (x, y) = (1 - y, x)
        case 180: (x, y) = (1 - x, 1 - y)
        case 270: (x, y) = (y, 1 - x)
        default: break
        }
        if flipX { x = 1 - x }
        if flipY { y = 1 - y }
        return CGPoint(x: x, y: y)
    }

    /// Normalisierter Panelpunkt -> globale Bildschirmkoordinaten innerhalb von `rect`.
    public func screenPoint(_ nx: CGFloat, _ ny: CGFloat, in rect: CGRect) -> CGPoint {
        let p = apply(nx, ny)
        return CGPoint(x: rect.minX + p.x * (rect.width - 1), y: rect.minY + p.y * (rect.height - 1))
    }
}

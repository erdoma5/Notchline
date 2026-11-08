import CoreGraphics

/// The destination is a verified caret/field point, not an assumed text range.
/// A short, asymmetric sheen opens along that point's baseline and then fades.
struct ParticleLineLanding {
    static let preferredWidth: CGFloat = 88
    static let feather: CGFloat = 12
    let anchor: CGPoint
    let left: CGFloat
    let right: CGFloat
    let baseline: CGFloat

    init(destination: CGPoint, screen: CGRect? = nil) {
        anchor = destination
        var left = destination.x - 72, right = destination.x + 16
        var y = destination.y - 7
        if let screen, !screen.isNull, !screen.isInfinite, screen.width > 0, screen.height > 0,
           screen.contains(destination) {
            // Use the destination display; the source can be on another screen.
            let minX = min(destination.x, screen.minX + 6)
            let maxX = max(destination.x, screen.maxX - 6)
            let width = min(Self.preferredWidth, maxX - minX)
            left = min(max(left, minX), maxX - width)
            right = left + width
            y = min(screen.maxY - 2, max(screen.minY + 2, y))
        }
        self.left = left
        self.right = right
        baseline = y
    }

    /// Includes the soft halo and feathering, not only the thin bright core.
    var bounds: CGRect {
        CGRect(x: left - Self.feather, y: baseline - 9,
               width: right - left + Self.feather * 2, height: 18)
    }

    func point(at fraction: CGFloat) -> CGPoint {
        CGPoint(x: left + (right - left) * Hologram.unit(fraction), y: baseline)
    }

    struct Band {
        let rect: CGRect
        let opacity: CGFloat
        let glintOpacity: CGFloat
    }

    func band(at progress: CGFloat) -> Band {
        let t = Hologram.unit(progress)
        let spread = Hologram.ease(t / 0.44)
        let a = anchor.x + (left - anchor.x) * spread
        let b = anchor.x + (right - anchor.x) * spread
        let opacity = Hologram.ease(t / 0.14) * (1 - Hologram.ease((t - 0.38) / 0.62))
        return Band(rect: CGRect(x: a, y: baseline - 0.5, width: max(0, b - a), height: 1),
                    opacity: opacity, glintOpacity: opacity * (1 - Hologram.ease((t - 0.28) / 0.38)))
    }
}

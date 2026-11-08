import SwiftUI
import AppKit

enum LineTheme: String, CaseIterable {
    // Keep the saved raw value so existing selections adopt the replacement.
    case clothesline, hologram
    static let preferenceKey = "appearanceTheme"
    static var current: Self {
        get { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .clothesline }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }
    var title: String {
        switch self {
        case .clothesline: L("Clothesline")
        case .hologram: L("Particle emergence")
        }
    }
    var hideDuration: Double { self == .hologram ? ParticleMotion.hideDuration : 0.3 }
}

enum Hologram {
    static let light = Color(red: 0.52, green: 0.89, blue: 0.82)
    static let white = Color(red: 0.86, green: 0.99, blue: 0.95)
    static let ink = Color(red: 0.035, green: 0.11, blue: 0.12)
    static let color = NSColor(srgbRed: 0.52, green: 0.89, blue: 0.82, alpha: 1)

    static func unit(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    static func ease(_ x: CGFloat) -> CGFloat { let t = unit(x); return t * t * (3 - 2 * t) }

    /// Shared geometry for SwiftUI frames, detached cards and preview bezels.
    static func brackets(in rect: CGRect, length: CGFloat = 10) -> CGPath {
        let p = CGMutablePath(), d = min(length, rect.width / 4, rect.height / 4)
        for (x, dx) in [(rect.minX, CGFloat(1)), (rect.maxX, CGFloat(-1))] {
            for (y, dy) in [(rect.minY, CGFloat(1)), (rect.maxY, CGFloat(-1))] {
                p.move(to: CGPoint(x: x, y: y + d * dy))
                p.addLine(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x + d * dx, y: y))
            }
        }
        return p
    }

    static func bezel(in ctx: CGContext, rect: CGRect, strength: CGFloat = 1) {
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.66 * strength).cgColor)
        ctx.setLineWidth(0.8)
        ctx.setShadow(offset: .zero, blur: 5, color: color.withAlphaComponent(0.24 * strength).cgColor)
        ctx.addPath(brackets(in: rect.insetBy(dx: 1, dy: 1)))
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func dissolve(image: CGImage, in ctx: CGContext, size: CGSize, progress: CGFloat) {
        ParticleRendering.dissolve(image: image, in: ctx, size: size, progress: progress)
    }

    static func transmission(image: CGImage, in ctx: CGContext, size: CGSize, progress: CGFloat) {
        ParticleRendering.transmission(image: image, in: ctx, size: size, progress: progress)
    }
}

struct HolographicCardEdge: View {
    var active: Bool = false
    var pulse: Double = 0
    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size).insetBy(dx: -2, dy: -2)
            ZStack {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Hologram.light.opacity(active ? 0.45 : 0.10), lineWidth: 0.7)
                Path(Hologram.brackets(in: rect, length: active ? 8 : 4))
                    .stroke(Hologram.white.opacity(active ? 0.65 : 0.25), lineWidth: 0.85)
                if pulse > 0 {
                    RoundedRectangle(cornerRadius: 10).stroke(Hologram.light.opacity(min(1, pulse) * 0.7), lineWidth: 1)
                        .padding(-3 - (1 - min(1, pulse)) * 8)
                }
            }
            .shadow(color: Hologram.light.opacity(active ? 0.22 : 0.05), radius: active ? 7 : 3)
        }.allowsHitTesting(false)
    }
}

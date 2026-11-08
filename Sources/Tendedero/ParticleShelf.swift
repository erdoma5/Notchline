import SwiftUI

/// A shallow recess in the screen surface. The back pass supplies a dark
/// opening and contact shadows; the front pass overlaps the bottom 2.2 points
/// of each card, making it read as inserted into a thin glass retaining lip.
/// Its fixed horizontal geometry is shared with the drop-back target in Layout.
struct ParticleShelf: View, Animatable {
    var progress: CGFloat
    let frame: CGRect
    let cards: [CGRect]
    let pull: LinePull
    var foreground: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            guard frame.width > 1, frame.height > 0, progress > 0 else { return }
            let alpha = ParticleMotion.phase(progress, 0, 0.30)
            let baseline = Layout.particleBaseline
            let dark = colorScheme == .dark
            let strong = contrast == .increased
            let inset: CGFloat = 1.5
            let left = frame.minX + inset, right = frame.maxX - inset
            guard right > left else { return }
            context.opacity = alpha

            if foreground {
                // This is the only surface drawn above the cards. Its top
                // bevel hides just their last 2.2pt, without covering content.
                let lip = CGRect(x: left, y: baseline - 2.2,
                                 width: right - left, height: 7.4)
                let shape = Path(roundedRect: lip, cornerRadius: 3.2)
                let top = reduceTransparency ? Hologram.white.opacity(0.88)
                    : Hologram.white.opacity(dark ? 0.32 : 0.49)
                let middle = reduceTransparency ? Hologram.ink.opacity(0.96)
                    : Hologram.light.opacity(dark ? 0.12 : 0.16)
                let bottom = reduceTransparency ? Hologram.ink
                    : Hologram.ink.opacity(dark ? 0.66 : 0.34)
                context.fill(shape, with: .linearGradient(
                    Gradient(stops: [.init(color: top, location: 0),
                                     .init(color: middle, location: 0.32),
                                     .init(color: bottom, location: 1)]),
                    startPoint: CGPoint(x: left, y: lip.minY),
                    endPoint: CGPoint(x: left, y: lip.maxY)))

                horizontal(in: &context, from: left + 3, to: right - 3,
                           y: lip.minY + 0.35,
                           color: Hologram.white.opacity(strong ? 0.90 : (dark ? 0.57 : 0.72)),
                           width: strong ? 0.95 : 0.6)
                horizontal(in: &context, from: left + 3, to: right - 3,
                           y: lip.maxY - 0.35,
                           color: Color.black.opacity(dark ? 0.36 : 0.22), width: 0.65)
                horizontal(in: &context, from: left + 5, to: right - 5,
                           y: lip.maxY + 0.55,
                           color: Hologram.white.opacity(dark ? 0.12 : 0.30), width: 0.45)

                // Local contact highlights stay horizontal even when a short
                // landscape photo is next to a tall clipping or portrait.
                for card in cards where card.maxX > left && card.minX < right {
                    let x1 = max(left + 3, card.minX + 4)
                    let x2 = min(right - 3, card.maxX - 4)
                    if x2 > x1 {
                        horizontal(in: &context, from: x1, to: x2,
                                   y: baseline - 1.65,
                                   color: Hologram.white.opacity(dark ? 0.25 : 0.34), width: 0.55)
                    }
                }

                if pull.id != nil {
                    let anchor = min(right - 3, max(left + 3, pull.anchor * size.width))
                    let nearest = cards.min { abs($0.midX - anchor) < abs($1.midX - anchor) }
                    let span = min(116, max(34, (nearest?.width ?? 80) * 0.78))
                    let x1 = max(left + 3, anchor - span / 2)
                    let x2 = min(right - 3, anchor + span / 2)
                    let tint = pull.armed ? Hologram.light : Hologram.white
                    horizontal(in: &context, from: x1, to: x2, y: baseline - 2.1,
                               color: tint.opacity(pull.armed ? 0.50 : 0.95), width: 1.15)
                    for x in [x1, x2] {
                        var marker = Path()
                        marker.move(to: CGPoint(x: x, y: baseline - 5))
                        marker.addLine(to: CGPoint(x: x, y: baseline + 1.7))
                        context.stroke(marker, with: .color(tint.opacity(0.7)), lineWidth: 0.75)
                    }
                }
            } else {
                // The upper dark seam and the brighter lower bevel form an
                // inset, rather than a glowing rail floating above the screen.
                let opening = CGRect(x: frame.minX, y: baseline - 6.5,
                                     width: frame.width, height: 11.8)
                let shape = Path(roundedRect: opening, cornerRadius: 5.2)
                let base = reduceTransparency
                    ? (dark ? Hologram.ink : Color(red: 0.69, green: 0.75, blue: 0.74))
                    : Hologram.ink.opacity(dark ? 0.56 : 0.22)
                context.fill(shape, with: .color(base))
                context.fill(shape, with: .linearGradient(
                    Gradient(stops: [.init(color: .black.opacity(dark ? 0.38 : 0.18), location: 0),
                                     .init(color: .clear, location: 0.46),
                                     .init(color: Hologram.light.opacity(dark ? 0.10 : 0.12), location: 1)]),
                    startPoint: CGPoint(x: left, y: opening.minY),
                    endPoint: CGPoint(x: left, y: opening.maxY)))
                horizontal(in: &context, from: left + 2, to: right - 2,
                           y: opening.minY + 0.7,
                           color: Color.black.opacity(strong ? 0.66 : (dark ? 0.40 : 0.26)),
                           width: strong ? 1 : 0.75)
                horizontal(in: &context, from: left + 4, to: right - 4,
                           y: opening.minY - 0.45,
                           color: Hologram.white.opacity(dark ? 0.11 : 0.28), width: 0.45)

                var shadows = context
                shadows.clip(to: shape)
                for card in cards where card.maxX > left && card.minX < right {
                    let width = max(2, min(card.width * 0.91, frame.width - 4))
                    var shadow = shadows
                    shadow.translateBy(x: card.midX, y: baseline - 1)
                    shadow.scaleBy(x: width / 2, y: 3.4)
                    shadow.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                                with: .radialGradient(
                                    Gradient(colors: [.black.opacity(dark ? 0.45 : 0.34), .clear]),
                                    center: .zero, startRadius: 0, endRadius: 1))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func horizontal(in context: inout GraphicsContext, from left: CGFloat,
                            to right: CGFloat, y: CGFloat, color: Color, width: CGFloat) {
        guard right > left else { return }
        var edge = Path()
        edge.move(to: CGPoint(x: left, y: y))
        edge.addLine(to: CGPoint(x: right, y: y))
        context.stroke(edge, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

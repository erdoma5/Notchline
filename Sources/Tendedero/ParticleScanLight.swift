import SwiftUI

/// Two surface-facing light curtains read the collection from its ends. They
/// share their exact clock and x positions with the card's material mask.
/// The background pass remains as projection light; the foreground pass is
/// transient and never becomes a mouse responder or a continuously running scan.
struct ParticleScanLight: View, Animatable {
    var progress: CGFloat
    let span: CGRect
    let shelf: CGRect
    let cards: [CGRect]
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
            guard progress > 0, span.width > 1, shelf.height > 0 else { return }
            let geometry = ParticleScanGeometry(span: span)
            let state = geometry.frame(at: progress)
            let visible = cards.filter { $0.maxX > span.minX && $0.minX < span.maxX }
            let baseline = shelf.minY + 7
            let top = max(3, (visible.map(\.minY).min() ?? baseline - 76) - 12)
            let bottom = max(top + 16, min(size.height - 2, baseline + 2))
            let dark = colorScheme == .dark

            if foreground {
                guard state.beamOpacity > 0 || state.mergeOpacity > 0 else { return }
                // The two cores crossfade into one at the midpoint, avoiding a
                // doubled white stripe exactly where the cards finish forming.
                let separation = max(0, state.rightX - state.leftX)
                let opacity = state.beamOpacity * (0.60 + 0.40 * min(1, separation / 22))
                if separation > 1.5 {
                    beam(in: &context, x: state.leftX, top: top, bottom: bottom,
                         tailDirection: -1, opacity: opacity, dark: dark)
                    beam(in: &context, x: state.rightX, top: top, bottom: bottom,
                         tailDirection: 1, opacity: opacity, dark: dark)
                } else {
                    beam(in: &context, x: span.midX, top: top, bottom: bottom,
                         tailDirection: 0, opacity: opacity, dark: dark)
                }
                fusion(in: &context, center: span.midX, top: top, baseline: baseline,
                       opacity: state.mergeOpacity)
            } else {
                // The upper-center source is drawn before the material mask:
                // it remains connected to both sweeping surface lights.
                stageLighting(in: &context, width: size.width, top: top, bottom: bottom,
                              cards: visible, state: state, dark: dark)
                // The illuminated surface remains behind the original colors.
                var light = context
                var passed = Path()
                passed.addRect(CGRect(x: span.minX, y: top,
                                      width: max(0, state.leftX - span.minX), height: bottom - top + 5))
                passed.addRect(CGRect(x: state.rightX, y: top,
                                      width: max(0, span.maxX - state.rightX), height: bottom - top + 5))
                light.clip(to: passed)
                let strength = state.projection * (reduceTransparency ? 0.55 : 1)
                for card in visible {
                    let crown = max(top, card.minY - 7)
                    let extent = max(12, baseline - crown)
                    let x = card.midX
                    glow(in: &light, at: CGPoint(x: x, y: crown + extent * 0.64),
                         radiusX: card.width * 0.70 + 12, radiusY: extent * 0.64,
                         color: Hologram.light.opacity(strength * (dark ? 0.14 : 0.10)))
                    glow(in: &light, at: CGPoint(x: x, y: baseline - 2),
                         radiusX: card.width * 0.56 + 9, radiusY: 9,
                         color: Hologram.white.opacity(strength * (dark ? 0.13 : 0.10)))

                    // Faint edge rays lend the settled image a projected depth
                    // without putting a wash over its text or original colors.
                    for side: CGFloat in [-1, 1] {
                        let foot = CGPoint(x: x + side * card.width * 0.38, y: baseline - 1)
                        let edge = CGPoint(x: x + side * (card.width / 2 + 5), y: crown + 7)
                        var ray = Path(); ray.move(to: foot); ray.addLine(to: edge)
                        light.stroke(ray, with: .linearGradient(
                            Gradient(colors: [Hologram.light.opacity(0.13 * strength), .clear]),
                            startPoint: foot, endPoint: edge), lineWidth: 0.55)
                    }
                }
                if visible.isEmpty {
                    glow(in: &light, at: CGPoint(x: span.midX, y: baseline - 26),
                         radiusX: min(180, span.width / 2), radiusY: 48,
                         color: Hologram.light.opacity(0.10 * strength))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func stageLighting(in context: inout GraphicsContext, width: CGFloat, top: CGFloat,
                               bottom: CGFloat, cards: [CGRect], state: ParticleScanGeometry.Frame, dark: Bool) {
        let origin = CGPoint(x: width / 2, y: 1.5)
        let material: CGFloat = reduceTransparency ? 0.55 : 1
        let separation = max(0, state.rightX - state.leftX)
        let compensation = 0.52 + 0.48 * min(1, separation / 48)
        let active = state.beamOpacity * material
        if separation > 2 {
            stageRay(in: &context, from: origin, to: CGPoint(x: state.leftX, y: bottom - 1),
                     spread: 15, strength: active * compensation, dark: dark)
            stageRay(in: &context, from: origin, to: CGPoint(x: state.rightX, y: bottom - 1),
                     spread: 15, strength: active * compensation, dark: dark)
        } else {
            stageRay(in: &context, from: origin, to: CGPoint(x: span.midX, y: bottom - 1),
                     spread: 16, strength: active * 0.86, dark: dark)
        }

        // A faint settled fan connects the same source to each projection;
        // no continuously moving beam is needed once the scan is complete.
        let settled = ParticleMotion.phase(progress, 0.78, 1) * state.projection * material
        let rays = cards.isEmpty ? [CGRect(x: span.midX - 15, y: top, width: 30, height: bottom - top)] : cards
        let soft = settled * 0.20 / sqrt(CGFloat(max(1, rays.count)))
        for card in rays {
            stageRay(in: &context, from: origin,
                     to: CGPoint(x: card.midX, y: card.minY + card.height * 0.62),
                     spread: min(32, card.width * 0.27), strength: soft, dark: dark)
        }

        let emitter = state.projection * (0.22 + 0.44 * state.beamOpacity + 0.10 * state.mergeOpacity)
        glow(in: &context, at: origin, radiusX: 17, radiusY: 6,
             color: Hologram.light.opacity(emitter * 0.36))
        glow(in: &context, at: CGPoint(x: origin.x, y: 2), radiusX: 6, radiusY: 3,
             color: Hologram.white.opacity(emitter * 0.70))
        var aperture = Path()
        aperture.move(to: CGPoint(x: origin.x - 4, y: origin.y))
        aperture.addLine(to: CGPoint(x: origin.x + 4, y: origin.y))
        context.stroke(aperture, with: .color(Hologram.white.opacity(emitter)),
                       style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
    }

    /// A tapered light volume with a Gaussian cross-section. Narrow overlapping
    /// strips feather the silhouette, without outlining a solid triangle.
    private func stageRay(in context: inout GraphicsContext, from source: CGPoint, to target: CGPoint,
                          spread: CGFloat, strength: CGFloat, dark: Bool) {
        guard strength > 0.001 else { return }
        let dx = target.x - source.x, dy = target.y - source.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let normal = CGVector(dx: -dy / length, dy: dx / length)
        var haze = context
        haze.translateBy(x: (source.x + target.x) / 2, y: (source.y + target.y) / 2)
        haze.rotate(by: .radians(Double(atan2(dy, dx))))
        glow(in: &haze, at: .zero, radiusX: length * 0.54, radiusY: spread * 0.75,
             color: Hologram.light.opacity(strength * (dark ? 0.12 : 0.08)))

        let lanes = 18
        for lane in 0..<lanes {
            let a = CGFloat(lane) / CGFloat(lanes) * 2 - 1
            let b = CGFloat(lane + 1) / CGFloat(lanes) * 2 - 1
            let center = (a + b) / 2
            let feather = exp(-center * center * 4.8)
            func offset(_ point: CGPoint, _ distance: CGFloat) -> CGPoint {
                CGPoint(x: point.x + normal.dx * distance, y: point.y + normal.dy * distance)
            }
            var volume = Path()
            volume.move(to: offset(source, a * 1.4))
            volume.addLine(to: offset(source, b * 1.4))
            volume.addLine(to: offset(target, b * spread))
            volume.addLine(to: offset(target, a * spread))
            volume.closeSubpath()
            let alpha = strength * feather
            context.fill(volume, with: .linearGradient(
                Gradient(stops: [.init(color: Hologram.white.opacity(alpha * 0.30), location: 0),
                                 .init(color: Hologram.light.opacity(alpha * (dark ? 0.21 : 0.14)), location: 0.28),
                                 .init(color: Hologram.light.opacity(alpha * 0.10), location: 0.85),
                                 .init(color: .clear, location: 1)]),
                startPoint: source, endPoint: target))
        }
        var spine = Path(); spine.move(to: source); spine.addLine(to: target)
        context.stroke(spine, with: .linearGradient(
            Gradient(colors: [Hologram.white.opacity(strength * 0.22), Hologram.light.opacity(strength * 0.08), .clear]),
            startPoint: source, endPoint: target), lineWidth: 0.5)
    }

    private func beam(in context: inout GraphicsContext, x: CGFloat, top: CGFloat,
                      bottom: CGFloat, tailDirection: CGFloat, opacity: CGFloat, dark: Bool) {
        guard opacity > 0.001 else { return }
        let height = bottom - top
        let midY = (top + bottom) / 2
        let strong = contrast == .increased
        glow(in: &context, at: CGPoint(x: x + tailDirection * 3, y: midY),
             radiusX: 12, radiusY: height * 0.57,
             color: Hologram.light.opacity(opacity * (dark ? 0.31 : 0.24)))
        glow(in: &context, at: CGPoint(x: x, y: midY + height * 0.10),
             radiusX: 3.5, radiusY: height * 0.47,
             color: Hologram.white.opacity(opacity * 0.27))

        var core = Path()
        core.move(to: CGPoint(x: x, y: top + 2))
        core.addLine(to: CGPoint(x: x, y: bottom - 1))
        context.stroke(core, with: .linearGradient(
            Gradient(stops: [.init(color: .clear, location: 0),
                             .init(color: Hologram.white.opacity(opacity * 0.83), location: 0.10),
                             .init(color: Hologram.white.opacity(opacity * 0.96), location: 0.70),
                             .init(color: Hologram.light.opacity(opacity * 0.50), location: 0.96),
                             .init(color: .clear, location: 1)]),
            startPoint: CGPoint(x: x, y: top), endPoint: CGPoint(x: x, y: bottom)),
            style: StrokeStyle(lineWidth: strong ? 1.15 : 0.85, lineCap: .round))

        // The ends of the scanner stay attached to this local surface.
        glow(in: &context, at: CGPoint(x: x, y: bottom - 1), radiusX: 10, radiusY: 3,
             color: Hologram.white.opacity(opacity * 0.52))
        var cap = Path()
        cap.move(to: CGPoint(x: x - 3.5, y: bottom - 0.7))
        cap.addLine(to: CGPoint(x: x + 3.5, y: bottom - 0.7))
        context.stroke(cap, with: .color(Hologram.white.opacity(0.65 * opacity)),
                       style: StrokeStyle(lineWidth: 0.65, lineCap: .round))
        for index in 0..<12 {
            let seed = UInt64(index * 71 + (tailDirection < 0 ? 13 : 47))
            let n = ParticleMotion.hash(seed)
            let y = top + 8 + (height - 16) * (CGFloat(index) + 0.25 + n * 0.45) / 12
            let behind = tailDirection * (2 + n * 7)
            let diameter: CGFloat = index % 5 == 0 ? 1.05 : 0.65
            let mote = CGRect(x: x + behind, y: y, width: diameter, height: diameter)
            context.fill(Path(ellipseIn: mote), with: .color(Hologram.white.opacity(opacity * (0.24 + n * 0.35))))
        }
    }

    private func fusion(in context: inout GraphicsContext, center: CGFloat, top: CGFloat,
                        baseline: CGFloat, opacity: CGFloat) {
        guard opacity > 0.001 else { return }
        let height = max(12, baseline - top)
        glow(in: &context, at: CGPoint(x: center, y: top + height * 0.60),
             radiusX: 14, radiusY: height * 0.48,
             color: Hologram.white.opacity(opacity * 0.19))
        let expansion = ParticleMotion.phase(progress, 0.77, 0.98)
        let width = min(156, max(26, span.width * 0.40)) * (0.16 + 0.84 * expansion)
        let y = baseline - 1.2
        glow(in: &context, at: CGPoint(x: center, y: y), radiusX: width * 0.60, radiusY: 5,
             color: Hologram.light.opacity(opacity * 0.25))
        var sheen = Path()
        sheen.move(to: CGPoint(x: center - width / 2, y: y))
        sheen.addLine(to: CGPoint(x: center + width / 2, y: y))
        context.stroke(sheen, with: .linearGradient(
            Gradient(colors: [.clear, Hologram.white.opacity(opacity * 0.68), .clear]),
            startPoint: CGPoint(x: center - width / 2, y: y),
            endPoint: CGPoint(x: center + width / 2, y: y)),
            style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        for index in 0..<8 {
            let n = ParticleMotion.hash(UInt64(index * 53 + 11))
            let side: CGFloat = index % 2 == 0 ? -1 : 1
            let x = center + side * width * (0.12 + n * 0.34)
            let dot = CGRect(x: x, y: y - 1 + n * 2, width: 0.8, height: 0.8)
            context.fill(Path(ellipseIn: dot), with: .color(Hologram.white.opacity(opacity * 0.48)))
        }
    }

    private func glow(in context: inout GraphicsContext, at center: CGPoint,
                      radiusX: CGFloat, radiusY: CGFloat, color: Color) {
        guard radiusX > 0, radiusY > 0 else { return }
        var light = context
        light.translateBy(x: center.x, y: center.y)
        light.scaleBy(x: radiusX, y: radiusY)
        light.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                   with: .radialGradient(Gradient(colors: [color, .clear]),
                                         center: .zero, startRadius: 0, endRadius: 1))
    }
}

import SwiftUI

/// A shared depth coordinate for materialization, halos and grain masks.
/// The stable AppKit hit target deliberately lives outside this presentation.
enum ParticleMotion {
    static let revealDuration = 1.04
    static let dismissDuration = 0.66
    static let hideDuration = dismissDuration + 0.08
    static let arrivalDuration = 0.46

    static func phase(_ progress: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
        Hologram.ease((progress - start) / (end - start))
    }
    static func scale(_ progress: CGFloat) -> CGFloat { 0.76 + 0.24 * phase(progress, 0.12, 0.96) }
    static func hash(_ value: UInt64) -> CGFloat {
        var x = value &+ 0x9e3779b97f4a7c15
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        return CGFloat((x ^ (x >> 31)) & 0xffff) / 65535
    }
    static func seed(_ text: String) -> UInt64 { text.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) } }

    static func grainOpacity(progress: CGFloat, x: CGFloat, y: CGFloat, noise: CGFloat) -> CGFloat {
        let radius = hypot((x - 0.5) / 0.72, (y - 0.5) / 0.72)
        let threshold = 0.025 + radius * 0.28 + noise * 0.34
        return phase(progress, threshold, threshold + 0.23)
    }
}

struct ParticleGrainMask: View {
    let progress: CGFloat
    let seed: UInt64
    var scan: ParticleScanCard? = nil
    var scanProgress: CGFloat = 1
    var depthScale: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            guard progress > 0, scanProgress > 0, size.width > 0, size.height > 0 else { return }
            if progress >= 0.999 && scanProgress >= 0.999 {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                return
            }
            // Batch cells into eight paths rather than issuing thousands of fills.
            let grain: CGFloat = 2.5
            var buckets = Array(repeating: Path(), count: 8)
            let columns = Int(ceil(size.width / grain)), rows = Int(ceil(size.height / grain))
            let geometry = scan.map { ParticleScanGeometry(span: $0.span) }
            let scanFrame = geometry?.frame(at: scanProgress)
            for row in 0..<rows {
                for column in 0..<columns {
                    let x = CGFloat(column) * grain, y = CGFloat(row) * grain
                    let noise = ParticleMotion.hash(seed &+ UInt64(row * 997 + column * 31))
                    let scanCoverage: CGFloat
                    if let scan, let geometry, let scanFrame {
                        scanCoverage = geometry.coverage(at: scan.card.midX + (x - size.width / 2) * depthScale,
                                                         progress: scanProgress, frame: scanFrame)
                    } else { scanCoverage = 1 }
                    let opacity = ParticleMotion.grainOpacity(progress: min(progress, scanCoverage), x: x / size.width,
                                                              y: y / size.height, noise: noise)
                    guard opacity > 0.01 else { continue }
                    let bucket = min(7, Int(opacity * 8))
                    buckets[bucket].addRect(CGRect(x: x, y: y, width: grain + 0.2, height: grain + 0.2))
                }
            }
            for index in buckets.indices {
                context.fill(buckets[index], with: .color(.white.opacity(Double(index + 1) / 8)))
            }
        }
    }
}

struct ParticleAppearance: AnimatableModifier {
    var progress: CGFloat
    let seed: UInt64
    var enabled: Bool = true
    var arrivalProgress: CGFloat = 1
    var scan: ParticleScanCard? = nil
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, arrivalProgress) }
        set { progress = newValue.first; arrivalProgress = newValue.second }
    }
    @ViewBuilder func body(content: Content) -> some View {
        let p = Hologram.unit(progress)
        let local = Hologram.unit(arrivalProgress)
        let illumination = scan.map { card in
            let geometry = ParticleScanGeometry(span: card.span)
            return (0...4).reduce(CGFloat(0)) { sum, index in
                sum + geometry.coverage(at: card.card.minX + card.card.width * CGFloat(index) / 4, progress: p)
            } / 5
        } ?? p
        let visual = min(local, illumination)
        let formed = ParticleMotion.phase(scan == nil ? min(p, local) : local, 0.22, 0.96)
        let depth = scan == nil ? ParticleMotion.scale(min(p, local))
            : ParticleMotion.scale(local) * (0.94 + 0.06 * ParticleMotion.phase(p, 0.10, 0.92))
        if enabled {
            Group {
                if p >= 0.999 && local >= 0.999 { content }
                else {
                    content
                        .mask { ParticleGrainMask(progress: formed, seed: seed, scan: scan,
                                                  scanProgress: scan == nil ? 1 : p, depthScale: depth) }
                        .scaleEffect(depth)
                        .blur(radius: (1 - visual) * 0.55)
                }
            }
            .background { ParticleHalo(progress: visual) }
            .overlay { ParticleSpecks(progress: visual, seed: seed) }
        } else { content }
    }
}

struct ParticleHalo: View {
    let progress: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        GeometryReader { geo in
            let awake = ParticleMotion.phase(progress, 0, 0.23)
            let settle = ParticleMotion.phase(progress, 0.74, 1)
            ZStack {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 10).fill(Hologram.ink.opacity(0.94))
                        .padding(-5).opacity(awake)
                } else {
                    Circle().fill(RadialGradient(colors: [Hologram.light.opacity((0.40 - 0.09 * settle) * awake), .clear],
                                                 center: .center, startRadius: 0, endRadius: 100))
                        .frame(width: 200, height: 200)
                        .scaleEffect(x: (geo.size.width + 66) / 200, y: (geo.size.height + 60) / 200)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    Circle().fill(RadialGradient(colors: [Hologram.white.opacity((0.18 - 0.10 * settle) * awake), .clear],
                                                 center: .center, startRadius: 0, endRadius: 100))
                        .frame(width: 200, height: 200)
                        .scaleEffect(x: geo.size.width / 180, y: geo.size.height / 180)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Hologram.white.opacity(0.8 * awake), lineWidth: 1)
                }
            }
        }.allowsHitTesting(false)
    }
}

struct ParticleSpecks: View {
    let progress: CGFloat
    let seed: UInt64
    var body: some View {
        Canvas { context, size in
            let p = Hologram.unit(progress)
            guard p > 0, p < 1, size.width > 0, size.height > 0 else { return }
            let awake = ParticleMotion.phase(p, 0.02, 0.19), fade = 1 - ParticleMotion.phase(p, 0.82, 1)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var cool = Array(repeating: Path(), count: 6), warm = Path()
            for index in 0..<144 {
                let n = seed &+ UInt64(index * 29)
                let rx = ParticleMotion.hash(n), ry = ParticleMotion.hash(n &+ 13)
                let t = ParticleMotion.phase(p, 0.08 + ParticleMotion.hash(n &+ 7) * 0.12, 0.88 + rx * 0.12)
                let depth = -175 * (1 - t), scale = 540 / (540 - depth)
                let turn = rx * .pi * 2 + t * 2.4
                let curl = sin(t * .pi) * (1 - t) * 10
                let x = center.x + ((rx - 0.5) * size.width + cos(turn) * curl) * scale
                let y = center.y + ((ry - 0.5) * size.height + sin(turn) * curl) * scale
                let side: CGFloat = (index % 13 == 0 ? 1.3 : 0.75) * scale
                let rect = CGRect(x: x, y: y, width: side, height: side)
                if index % 23 == 0 { warm.addEllipse(in: rect) }
                else { cool[min(5, Int(rx * 6))].addEllipse(in: rect) }
            }
            for index in cool.indices {
                context.fill(cool[index], with: .color(Hologram.white.opacity(awake * fade * (0.35 + Double(index) * 0.10))))
            }
            context.fill(warm, with: .color(Color(red: 1, green: 0.88, blue: 0.64).opacity(awake * fade * 0.65)))
        }.allowsHitTesting(false)
    }
}

/// An ambient plane behind the content, with no top emitter or enclosing HUD.
struct ParticleField: View, Animatable {
    var progress: CGFloat
    let field: CGRect
    let pulseX: CGFloat?
    let pulse: Double
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        Canvas { context, size in
            let p = Hologram.unit(progress)
            guard p > 0, field.width > 0 else { return }
            let awake = ParticleMotion.phase(p, 0, 0.24)
            let center = CGPoint(x: field.midX, y: field.midY)
            var ambient = context
            ambient.translateBy(x: center.x, y: center.y)
            ambient.scaleBy(x: field.width / 2, y: field.height / 2)
            ambient.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                         with: .radialGradient(Gradient(colors: [Hologram.light.opacity(0.06 * awake), .clear]),
                                               center: .zero, startRadius: 0, endRadius: 1))
            if let pulseX, pulse > 0 {
                let radius = 9 + (1 - min(1, pulse)) * 30
                let ring = CGRect(x: pulseX - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: ring), with: .color(Hologram.white.opacity(pulse * 0.42)), lineWidth: 0.7)
                for index in 0..<12 {
                    let angle = CGFloat(index) * .pi / 6
                    let point = CGPoint(x: pulseX + cos(angle) * radius, y: center.y + sin(angle) * radius)
                    context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: 1, height: 1)), with: .color(Hologram.light.opacity(pulse * 0.7)))
                }
            }

        }.allowsHitTesting(false)
    }
}

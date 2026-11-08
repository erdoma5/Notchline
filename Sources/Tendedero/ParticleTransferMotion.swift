import Foundation
import CoreGraphics

/// Screen-space particles leave the source individually, so a transmission is
/// a continuous stream rather than a rasterized cluster moving as one object.
/// Progress is independent of the selected duration and every seed is stable.
struct ParticleTransferMotion {
    struct Particle {
        let position: CGPoint
        let tail: CGPoint
        let opacity: CGFloat
        let radius: CGFloat
        let warm: Bool
    }

    struct Frame {
        let particles: [Particle]
        let sourceProgress: CGFloat
        let sourceReleased: Bool
        /// Progress of the landing response, not its opacity. The renderer can
        /// use a single smooth pulse without flashing for each arriving mote.
        let arrival: CGFloat
        let opacity: CGFloat
        let landing: ParticleLineLanding
    }

    let card: CGRect
    let destination: CGPoint
    /// The Bezier convex hull includes every source cell; the additional
    /// margin covers normal offsets, the radius of each mote and its glow.
    let bounds: CGRect
    let landing: ParticleLineLanding

    private struct Seed {
        let origin: CGPoint
        let launch: CGFloat
        let duration: CGFloat
        let curl: CGFloat
        let phase: CGFloat
        let tailLag: CGFloat
        let tailLength: CGFloat
        let alpha: CGFloat
        let radius: CGFloat
        let warm: Bool
        let landingUnit: CGFloat
    }

    private let control1: CGPoint
    private let control2: CGPoint
    private let normal: CGVector
    private let seeds: [Seed]
    private static let maximumCurl: CGFloat = 16
    private static let sourceEnd: CGFloat = 0.36

    init(card rawCard: CGRect, destination rawDestination: CGPoint, sourceScreen: CGRect? = nil,
         destinationScreen: CGRect? = nil) {
        let card = Self.valid(rawCard) ? rawCard.standardized : .zero
        let start = CGPoint(x: card.midX, y: card.midY)
        var end = rawDestination.x.isFinite && rawDestination.y.isFinite ? rawDestination : start
        var dx = end.x - start.x, dy = end.y - start.y
        var distance = hypot(dx, dy)
        if !distance.isFinite {
            end = start; dx = 0; dy = 0; distance = 0
        }
        var normal = distance > 0.01
            ? CGVector(dx: -dy / distance, dy: dx / distance)
            : CGVector(dx: 1, dy: 0)
        var bend = min(96, max(24, distance * 0.14))

        // Pick the roomy side at departure. In particular, a horizontal paste
        // near the menu bar curves down instead of briefly leaving the display.
        if let screen = sourceScreen, Self.valid(screen), !screen.isEmpty {
            func room(_ n: CGVector) -> CGFloat {
                var result = CGFloat.greatestFiniteMagnitude
                if n.dx > 0.0001 { result = min(result, (screen.maxX - start.x - 12) / n.dx) }
                if n.dx < -0.0001 { result = min(result, (start.x - screen.minX - 12) / -n.dx) }
                if n.dy > 0.0001 { result = min(result, (screen.maxY - start.y - 12) / n.dy) }
                if n.dy < -0.0001 { result = min(result, (start.y - screen.minY - 12) / -n.dy) }
                return max(0, result)
            }
            let reverse = CGVector(dx: -normal.dx, dy: -normal.dy)
            if room(reverse) > room(normal) { normal = reverse }
            bend = min(bend, max(4, room(normal) * 0.65))
        }

        let control1: CGPoint
        let control2: CGPoint
        if distance < 8 {
            // A same-place paste still unravels and reforms, with a compact
            // bowed path instead of an undefined direction or a static dot.
            control1 = CGPoint(x: start.x + normal.dx * bend,
                               y: start.y + normal.dy * bend)
            control2 = CGPoint(x: end.x - normal.dx * bend * 0.65,
                               y: end.y - normal.dy * bend * 0.65)
        } else {
            control1 = CGPoint(x: start.x + dx * 0.29 + normal.dx * bend,
                               y: start.y + dy * 0.29 + normal.dy * bend)
            control2 = CGPoint(x: start.x + dx * 0.73 + normal.dx * bend * 0.42,
                               y: start.y + dy * 0.73 + normal.dy * bend * 0.42)
        }

        var seeds: [Seed] = []
        seeds.reserveCapacity(144)
        for row in 0..<9 {
            for column in 0..<16 {
                let index = row * 16 + column
                let rx = (CGFloat(column) + 0.2 + Self.noise(index + 3) * 0.6) / 16
                let ry = (CGFloat(row) + 0.2 + Self.noise(index + 379) * 0.6) / 9
                // Interleaved cohorts avoid peeling an obvious row of a grid.
                let cohort = CGFloat((index * 37) % 144) / 143
                let launch = 0.025 + cohort * 0.255 + Self.noise(index + 31) * 0.025
                seeds.append(Seed(
                    origin: CGPoint(x: card.minX + card.width * rx, y: card.minY + card.height * ry),
                    launch: launch,
                    duration: 0.48 + Self.noise(index + 67) * 0.145,
                    curl: 4 + Self.noise(index + 131) * (Self.maximumCurl - 4),
                    phase: Self.noise(index + 733) * .pi * 2,
                    tailLag: 0.013 + Self.noise(index + 193) * 0.015,
                    tailLength: 12 + Self.noise(index + 271) * 14,
                    alpha: 0.52 + Self.noise(index + 419) * 0.40,
                    radius: index % 19 == 0 ? 1.25 : 0.55 + Self.noise(index + 521) * 0.40,
                    warm: index % 17 == 0,
                    landingUnit: Self.noise(index + 947)))
            }
        }

        self.card = card
        self.destination = end
        self.control1 = control1
        self.control2 = control2
        self.normal = normal
        self.seeds = seeds
        landing = ParticleLineLanding(destination: end, screen: destinationScreen)

        let minX = min(card.minX, control1.x, control2.x, end.x)
        let minY = min(card.minY, control1.y, control2.y, end.y)
        let maxX = max(card.maxX, control1.x, control2.x, end.x)
        let maxY = max(card.maxY, control1.y, control2.y, end.y)
        // Tails are line segments between two points on the same bounded
        // trajectory, so they cannot escape its convex bounding rectangle.
        let margin = Self.maximumCurl + 1.25 + 12
        let pathBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -margin, dy: -margin)
        bounds = pathBounds
            .union(pathBounds.offsetBy(dx: min(0, landing.left - end.x), dy: min(0, landing.baseline - end.y)))
            .union(pathBounds.offsetBy(dx: max(0, landing.right - end.x), dy: max(0, landing.baseline - end.y)))
            .union(landing.bounds)
    }

    func frame(at rawProgress: CGFloat) -> Frame {
        let p = rawProgress.isFinite ? Self.unit(rawProgress) : 0
        let particles = seeds.map { seed -> Particle in
            let t = Self.unit((p - seed.launch) / seed.duration)
            let position = point(for: seed, fraction: t)
            let earlier = Self.unit((p - seed.launch - seed.tailLag) / seed.duration)
            let previous = point(for: seed, fraction: earlier)
            let vx = position.x - previous.x, vy = position.y - previous.y
            let length = hypot(vx, vy)
            let tailScale = length > seed.tailLength ? seed.tailLength / length : 1
            let tail = CGPoint(x: position.x - vx * tailScale, y: position.y - vy * tailScale)
            let opacity = Self.phase(t, 0, 0.075) * (1 - Self.phase(t, 0.78, 1)) * seed.alpha
            return Particle(position: position, tail: tail, opacity: opacity,
                            radius: seed.radius * (1 - 0.32 * Self.phase(t, 0.80, 1)), warm: seed.warm)
        }
        return Frame(particles: particles,
                     sourceProgress: Self.phase(p, 0.025, Self.sourceEnd),
                     sourceReleased: p >= Self.sourceEnd,
                     arrival: Self.phase(p, 0.49, 0.97),
                     opacity: 1 - Self.phase(p, 0.95, 1), landing: landing)
    }

    private func point(for seed: Seed, fraction: CGFloat) -> CGPoint {
        let t = Self.ease(fraction), u = 1 - t
        let x = u * u * u * seed.origin.x + 3 * u * u * t * control1.x
            + 3 * u * t * t * control2.x + t * t * t * destination.x
        let y = u * u * u * seed.origin.y + 3 * u * u * t * control1.y
            + 3 * u * t * t * control2.y + t * t * t * destination.y
        // Normal drift gives the current depth without changing its endpoints;
        // its bound is maximumCurl, used in the rectangle above.
        let curl = seed.curl * sin(.pi * t) * (1 - t)
            * sin(seed.phase + t * .pi * 3.2)
        // Keep the approved transit intact. Only its last approach fans into
        // the same horizontal strip as the landing sheen, eliminating a funnel.
        let spread = Self.phase(fraction, 0.76, 1)
        let target = landing.point(at: seed.landingUnit)
        return CGPoint(x: x + normal.dx * curl + (target.x - destination.x) * spread,
                       y: y + normal.dy * curl + (target.y - destination.y) * spread)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
    }
    private static func unit(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    private static func ease(_ x: CGFloat) -> CGFloat {
        let t = unit(x)
        return t * t * (3 - 2 * t)
    }
    private static func phase(_ x: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat {
        ease((x - from) / (to - from))
    }
    private static func noise(_ value: Int) -> CGFloat {
        var x = UInt32(truncatingIfNeeded: value) &+ 0x9e3779b9
        x = (x ^ (x >> 16)) &* 0x7feb352d
        x = (x ^ (x >> 15)) &* 0x846ca68b
        x ^= x >> 16
        return CGFloat(x & 0xffff) / 65535
    }
}

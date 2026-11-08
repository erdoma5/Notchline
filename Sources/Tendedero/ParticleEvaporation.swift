import AppKit
import CoreGraphics

/// Local deletion: the card loses cohesion in place, while a few of its
/// dissolving pixels lift and extinguish. Sending uses a separate renderer.
enum ParticleEvaporation {
    static let duration: TimeInterval = 0.60
    private static let levels = 8
    private static let white = NSColor(srgbRed: 0.88, green: 0.99, blue: 0.98, alpha: 1)
    private static let light = NSColor(srgbRed: 0.54, green: 0.88, blue: 0.84, alpha: 1)

    /// Coordinates are local to the unscaled card, with positive y upwards.
    /// A common erosion clock keeps the departing pixels and motes connected.
    static func erasureStart(at point: CGPoint, size: CGSize) -> CGFloat {
        guard valid(size), point.x.isFinite, point.y.isFinite else { return 1 }
        let x = unit(point.x / size.width), y = unit(point.y / size.height)
        let fromTop = (1 - y) * 0.80
        let fromSides = min(x, 1 - x) * 1.60 + 0.05
        let fromBottom = y * 0.95 + 0.43
        let depth = min(fromTop, fromSides, fromBottom)
        // Broad waviness avoids a mechanical straight wipe; finer variation
        // creates a soft granular boundary rather than large image fragments.
        let wave = field(x: x * 7, y: y * 6)
        let grain = noise(Int(point.x / 1.35) &* 157 &+ Int(point.y / 1.35) &* 293)
        return 0.025 + depth * 0.78 + wave * 0.100 + grain * 0.023
    }

    static func draw(image: CGImage, in ctx: CGContext, size: CGSize, progress: CGFloat) {
        guard valid(size), progress.isFinite else { return }
        let p = unit(progress), bounds = CGRect(origin: .zero, size: size)
        if p == 0 { ctx.draw(image, in: bounds); return }
        guard p < 1 else { return }
        ctx.saveGState()
        drawRaster(image, in: ctx, size: size, progress: p)
        drawMotes(in: ctx, size: size, progress: p)
        // The pending corners acknowledge release once, then vanish before
        // the body has evaporated. No residual frame or destination marker.
        let flash = phase(p, 0, 0.035) * (1 - phase(p, 0.04, 0.19))
        if flash > 0 {
            ctx.setStrokeColor(white.withAlphaComponent(flash * 0.72).cgColor)
            ctx.setLineWidth(0.75)
            ctx.setShadow(offset: .zero, blur: 4, color: light.withAlphaComponent(flash * 0.25).cgColor)
            ctx.addPath(Hologram.brackets(in: bounds.insetBy(dx: -1.3, dy: -1.3), length: 6))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// A detached card stays fully legible. Readiness is eased by the panel,
    /// and is reversible when the pointer brings the card back to its shelf.
    static func drawHeld(image: CGImage, in ctx: CGContext, size: CGSize,
                         readiness: CGFloat, time: TimeInterval,
                         reducedMotion: Bool = false, reducedTransparency: Bool = false,
                         increasedContrast: Bool = false) {
        guard valid(size), readiness.isFinite else { return }
        let r = unit(readiness), bounds = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        let support = 1 - r * 0.80
        if !reducedTransparency {
            glow(in: ctx, center: CGPoint(x: size.width / 2, y: 0),
                 radius: CGSize(width: size.width * 0.64, height: 16), alpha: 0.16 * support)
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8,
                      color: NSColor.black.withAlphaComponent(0.12 + support * 0.08).cgColor)
        ctx.draw(image, in: bounds)
        ctx.restoreGState()
        // Fine edge fragments communicate the armed state without tinting
        // the content or applying the rope theme's swinging paper treatment.
        ctx.setLineWidth(increasedContrast ? 1.15 : 0.80)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(white.withAlphaComponent(unit((increasedContrast ? 0.55 : 0.28) + r * 0.48)).cgColor)
        if !reducedTransparency {
            ctx.setShadow(offset: .zero, blur: 3 + r * 2,
                          color: light.withAlphaComponent(0.12 + r * 0.16).cgColor)
        }
        let offset = 0.8 + r * 1.0
        ctx.addPath(Hologram.brackets(in: bounds.insetBy(dx: -offset, dy: -offset), length: 4 + r * 3))
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        if !reducedMotion, time.isFinite, r > 0.001 {
            for index in 0..<3 {
                let t = CGFloat((max(0, time) / 1.65 + Double(index) * 0.337).truncatingRemainder(dividingBy: 1))
                let alpha = sin(t * .pi) * r * 0.62
                let x = size.width * [CGFloat(0.10), 0.87, 0.62][index] + sin(t * .pi) * (index == 1 ? 1.6 : -1.2) * r
                let y = size.height - 0.6 + (2 + t * 9) * r
                let radius = (0.56 - 0.26 * t) * r
                ctx.setFillColor(white.withAlphaComponent(alpha).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }
        ctx.restoreGState()
    }

    private static func drawRaster(_ image: CGImage, in ctx: CGContext, size: CGSize, progress p: CGFloat) {
        guard p < 0.80 else { return }
        let grain: CGFloat = max(1.0, min(1.35, min(size.width, size.height) / 58))
        let paths = (0..<levels).map { _ in CGMutablePath() }
        let frontier = (0..<4).map { _ in CGMutablePath() }
        var used = Array(repeating: false, count: levels)
        var frontierUsed = Array(repeating: false, count: 4)
        let cols = Int(ceil(size.width / grain)), rows = Int(ceil(size.height / grain))
        for row in 0..<rows {
            for column in 0..<cols {
                let x = CGFloat(column) * grain, y = CGFloat(row) * grain
                let start = erasureStart(at: CGPoint(x: x + grain / 2, y: y + grain / 2), size: size)
                let loss = phase(p, start, start + 0.105)
                let coverage = 1 - loss
                if coverage > 0 {
                    let bucket = min(levels - 1, Int(ceil(coverage * CGFloat(levels))) - 1)
                    paths[bucket].addRect(CGRect(x: x, y: y, width: min(grain, size.width - x), height: min(grain, size.height - y)))
                    used[bucket] = true
                }
                // Only a sparse fraction of the dissolving edge is luminous.
                // Content remains the visual material, rather than a neon mask.
                if (column &* 31 &+ row &* 17) % 11 == 0, loss > 0.16, loss < 0.94 {
                    let alpha = sin(loss * .pi) * 0.48
                    let bucket = min(3, Int(alpha * 8))
                    let radius = 0.22 + noise(column &* 47 &+ row &* 83) * 0.18
                    frontier[bucket].addEllipse(in: CGRect(x: x + grain / 2 - radius, y: y + grain / 2 - radius,
                                                          width: radius * 2, height: radius * 2))
                    frontierUsed[bucket] = true
                }
            }
        }
        for bucket in 0..<levels where used[bucket] {
            ctx.saveGState()
            ctx.setShouldAntialias(false)
            ctx.addPath(paths[bucket]); ctx.clip()
            ctx.setAlpha(CGFloat(bucket + 1) / CGFloat(levels))
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
        for bucket in 0..<4 where frontierUsed[bucket] {
            ctx.setFillColor(white.withAlphaComponent(CGFloat(bucket + 1) / 8).cgColor)
            ctx.addPath(frontier[bucket]); ctx.fillPath()
        }
    }

    private static func drawMotes(in ctx: CGContext, size: CGSize, progress p: CGFloat) {
        let columns = 18, rows = 12
        let paths = (0..<12).map { _ in CGMutablePath() }
        var used = Array(repeating: false, count: 12)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let origin = CGPoint(x: (CGFloat(column) + 0.15 + noise(index + 123) * 0.7) * size.width / CGFloat(columns),
                                     y: (CGFloat(row) + 0.15 + noise(index + 987) * 0.7) * size.height / CGFloat(rows))
                let start = erasureStart(at: origin, size: size) + 0.025
                let lifetime = min(0.985 - start, 0.31 + noise(index + 715) * 0.09)
                let age = (p - start) / lifetime
                guard age > 0, age < 1 else { continue }
                let travel = ease(age)
                let opacity = phase(age, 0, 0.12) * (1 - phase(age, 0.25, 1)) * (0.46 + noise(index + 81) * 0.34)
                guard opacity > 0.015 else { continue }
                let drift = (noise(index + 36) - 0.5) * 5.0
                let x = origin.x + drift * sin(travel * .pi * 0.7)
                let y = origin.y + (8 + noise(index + 631) * 14) * travel
                let radius = (0.43 + noise(index + 512) * 0.40) * (1 - travel * 0.72)
                let color = index % 4 == 0 ? 1 : 0
                let bucket = color * 6 + min(5, Int(opacity * 6))
                paths[bucket].addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                used[bucket] = true
                if index % 9 == 0, age < 0.65 {
                    ctx.setStrokeColor(light.withAlphaComponent(opacity * 0.18).cgColor)
                    ctx.setLineWidth(0.40)
                    ctx.move(to: CGPoint(x: x, y: y))
                    ctx.addLine(to: CGPoint(x: x - drift * 0.07, y: y - 1.9 * sin(age * .pi)))
                    ctx.strokePath()
                }
            }
        }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 1.8, color: light.withAlphaComponent(0.20).cgColor)
        for bucket in 0..<12 where used[bucket] {
            let color = bucket < 6 ? white : light
            ctx.setFillColor(color.withAlphaComponent((CGFloat(bucket % 6) + 0.5) / 6).cgColor)
            ctx.addPath(paths[bucket]); ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private static func glow(in ctx: CGContext, center: CGPoint, radius: CGSize, alpha: CGFloat) {
        guard alpha > 0, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [light.withAlphaComponent(alpha).cgColor, light.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: radius.width, y: radius.height)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        ctx.restoreGState()
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
    private static func unit(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    private static func ease(_ x: CGFloat) -> CGFloat { let t = unit(x); return t * t * (3 - 2 * t) }
    private static func phase(_ p: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat { ease((p - from) / (to - from)) }
    private static func noise(_ seed: Int) -> CGFloat {
        var n = UInt32(truncatingIfNeeded: seed) &+ 0x9e3779b9
        n = (n ^ (n >> 16)) &* 0x7feb352d
        n = (n ^ (n >> 15)) &* 0x846ca68b
        n ^= n >> 16
        return CGFloat(n & 0xffff) / 65535
    }
    private static func field(x: CGFloat, y: CGFloat) -> CGFloat {
        let ix = Int(floor(x)), iy = Int(floor(y))
        let fx = ease(x - CGFloat(ix)), fy = ease(y - CGFloat(iy))
        let a = noise(ix &* 113 &+ iy &* 263)
        let b = noise((ix &+ 1) &* 113 &+ iy &* 263)
        let c = noise(ix &* 113 &+ (iy &+ 1) &* 263)
        let d = noise((ix &+ 1) &* 113 &+ (iy &+ 1) &* 263)
        return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
    }
}

import AppKit
import CoreGraphics

/// The detached-card counterpart of the depth reveal. Every frame is a pure
/// function of progress: interrupted/reversed gestures never reseed the dust.
/// The enclosing window owns timing, placement, and the final fade in flight.
enum ParticleRendering {
    private static let columns = 16
    private static let rows = 11
    private static let alphaLevels = 6

    private enum Destination { case depth, packet }

    /// Removal evaporates locally; sending keeps its independent transfer path.
    static func dissolve(image: CGImage, in ctx: CGContext, size: CGSize, progress: CGFloat) {
        ParticleEvaporation.draw(image: image, in: ctx, size: size, progress: progress)
    }

    /// Turns a pasted copy into a compact constellation. At progress == 1 the
    /// constellation stays visible so InkFlight can carry it to the editor.
    static func transmission(image: CGImage, in ctx: CGContext, size: CGSize, progress: CGFloat) {
        draw(image: image, in: ctx, size: size, progress: progress, destination: .packet)
    }

    /// Only the departing raster. Independently timed light particles are
    /// rendered over its whole route by ParticleTransferVisuals.
    static func departure(image: CGImage, in ctx: CGContext, size: CGSize, progress: CGFloat) {
        guard progress.isFinite, size.width > 0, size.height > 0 else { return }
        let p = unit(progress)
        if p == 0 { ctx.draw(image, in: CGRect(origin: .zero, size: size)); return }
        guard p < 1 else { return }
        let grain = max(2.2, min(3, min(size.width, size.height) / 28))
        drawRemainingImage(image, in: ctx, size: size, grain: grain, progress: p, scale: 1)
    }

    private static func unit(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
    private static func ease(_ value: CGFloat) -> CGFloat {
        let t = unit(value)
        return t * t * (3 - 2 * t)
    }
    private static func phase(_ value: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat {
        ease((value - from) / max(0.0001, to - from))
    }

    /// Integer mixing avoids random generators and trigonometry in the mask
    /// loop. Seeds depend on the grain location, never on time or image data.
    private static func noise(_ seed: Int) -> CGFloat {
        var n = UInt32(truncatingIfNeeded: seed) &+ 0x9e3779b9
        n = (n ^ (n >> 16)) &* 0x7feb352d
        n = (n ^ (n >> 15)) &* 0x846ca68b
        n ^= n >> 16
        return CGFloat(n & 0xffff) / 65535
    }

    private static func threshold(column: Int, row: Int, size: CGSize, grain: CGFloat) -> CGFloat {
        let dx = (CGFloat(column) * grain + grain / 2 - size.width / 2) / max(1, size.width / 2)
        let dy = (CGFloat(row) * grain + grain / 2 - size.height / 2) / max(1, size.height / 2)
        // The perimeter loosens slightly earlier, with no directional wipe.
        let edge = min(1, hypot(dx, dy))
        return 0.06 + noise(column &* 127 &+ row &* 313) * 0.36 + (1 - edge) * 0.10
    }

    private static func draw(image: CGImage, in ctx: CGContext, size: CGSize,
                             progress raw: CGFloat, destination: Destination) {
        guard raw.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let p = unit(raw), bounds = CGRect(origin: .zero, size: size)
        if p == 0 {
            ctx.saveGState()
            ctx.draw(image, in: bounds)
            ctx.restoreGState()
            return
        }
        if destination == .depth && p == 1 { return }

        let grain = max(2.2, min(3.0, min(size.width, size.height) / 28))
        let retreat = phase(p, 0.02, 0.90)
        let scale: CGFloat = 1 - (destination == .depth ? 0.22 : 0.12) * retreat
        drawRemainingImage(image, in: ctx, size: size, grain: grain, progress: p, scale: scale)
        drawParticles(in: ctx, size: size, grain: grain, progress: p, destination: destination)
    }

    /// Fine, locally irregular coverage, quantized into six union paths. The
    /// original image is decoded once by the caller and drawn at most six
    /// times per frame, instead of cropping hundreds of little image tiles.
    private static func drawRemainingImage(_ image: CGImage, in ctx: CGContext, size: CGSize,
                                            grain: CGFloat, progress: CGFloat, scale: CGFloat) {
        guard progress < 0.80 else { return }
        let paths = (0..<alphaLevels).map { _ in CGMutablePath() }
        var used = Array(repeating: false, count: alphaLevels)
        let cols = Int(ceil(size.width / grain)), rows = Int(ceil(size.height / grain))
        for row in 0..<rows {
            for column in 0..<cols {
                let start = threshold(column: column, row: row, size: size, grain: grain)
                let coverage = 1 - phase(progress, start, start + 0.22)
                guard coverage > 0 else { continue }
                let bucket = min(alphaLevels - 1, Int(ceil(coverage * CGFloat(alphaLevels))) - 1)
                let x = CGFloat(column) * grain, y = CGFloat(row) * grain
                paths[bucket].addRect(CGRect(x: x, y: y,
                                             width: min(grain, size.width - x),
                                             height: min(grain, size.height - y)))
                used[bucket] = true
            }
        }
        ctx.saveGState()
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        ctx.interpolationQuality = .high
        for index in 0..<alphaLevels where used[index] {
            ctx.saveGState()
            ctx.setShouldAntialias(false)
            ctx.addPath(paths[index])
            ctx.clip()
            ctx.setAlpha(CGFloat(index + 1) / CGFloat(alphaLevels))
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private static func drawParticles(in ctx: CGContext, size: CGSize, grain: CGFloat,
                                       progress p: CGFloat, destination: Destination) {
        let light = Hologram.color
        let white = NSColor(srgbRed: 0.87, green: 1, blue: 0.95, alpha: 1)
        let gold = NSColor(srgbRed: 1, green: 0.88, blue: 0.63, alpha: 1)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let packetWidth = min(38, max(2, size.width * 0.38))
        let packetHeight = min(22, max(2, size.height * 0.34))
        let groups = (0..<12).map { _ in CGMutablePath() }
        var used = Array(repeating: false, count: 12)
        ctx.saveGState()

        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let rx = (CGFloat(column) + 0.17 + noise(index + 31) * 0.66) / CGFloat(columns)
                let ry = (CGFloat(row) + 0.17 + noise(index + 719) * 0.66) / CGFloat(rows)
                let origin = CGPoint(x: rx * size.width, y: ry * size.height)
                let start = threshold(column: Int(origin.x / grain), row: Int(origin.y / grain), size: size, grain: grain)
                let t = phase(p, start, min(0.98, start + 0.54))
                let birth = phase(p, start - 0.035, start + 0.09)
                guard birth > 0 else { continue }
                let angle = noise(index + 137) * .pi * 2
                let bend = sin(t * .pi) * (1.8 + noise(index + 91) * 3.2)
                let depth = 1 / (1 + 0.65 * t)
                let x: CGFloat, y: CGFloat, alpha: CGFloat, radius: CGFloat
                if destination == .depth {
                    x = center.x + (origin.x - center.x) * depth + cos(angle) * bend
                    y = center.y + (origin.y - center.y) * depth + sin(angle) * bend
                    alpha = birth * (1 - phase(p, 0.48, 1)) * (0.52 + noise(index + 4) * 0.34)
                    radius = (0.42 + noise(index + 48) * 0.36) * depth
                } else {
                    let radial = sqrt(noise(index + 821))
                    let destinationX = center.x + cos(angle) * packetWidth / 2 * radial
                    let destinationY = center.y + sin(angle) * packetHeight / 2 * radial
                    x = origin.x + (destinationX - origin.x) * t + cos(angle + .pi / 2) * bend
                    y = origin.y + (destinationY - origin.y) * t + sin(angle + .pi / 2) * bend
                    alpha = birth * (0.48 + noise(index + 4) * 0.40)
                    radius = 0.42 + noise(index + 48) * 0.30
                }
                guard alpha > 0.015 else { continue }
                let color = index % 17 == 0 ? 2 : (index % 3 == 0 ? 1 : 0)
                let level = min(3, Int(alpha * 4))
                let group = color * 4 + level
                groups[group].addEllipse(in: CGRect(x: x - radius, y: y - radius,
                                                    width: radius * 2, height: radius * 2))
                used[group] = true
                // A few short rays describe depth travel. Their orientation
                // is radial and balanced, so the group never drifts upwards.
                if index % 8 == 0 && t > 0 && t < 0.93 {
                    let dx = (origin.x - center.x) * 0.07 * sin(t * .pi)
                    let dy = (origin.y - center.y) * 0.07 * sin(t * .pi)
                    ctx.setStrokeColor(light.withAlphaComponent(alpha * 0.24).cgColor)
                    ctx.setLineWidth(0.45)
                    ctx.move(to: CGPoint(x: x, y: y))
                    ctx.addLine(to: CGPoint(x: x + dx, y: y + dy))
                    ctx.strokePath()
                }
            }
        }
        let colors = [white, light, gold]
        ctx.setShadow(offset: .zero, blur: 2.2, color: light.withAlphaComponent(0.24).cgColor)
        for index in 0..<groups.count where used[index] {
            let alpha = (CGFloat(index % 4) + 0.5) / 4
            ctx.setFillColor(colors[index / 4].withAlphaComponent(alpha).cgColor)
            ctx.addPath(groups[index])
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}

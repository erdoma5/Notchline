import AppKit
import QuartzCore

/// A tiny destination-only raster gives both the native compositor and the
/// exported preview the same feathering. The stream itself stays vector-based.
private final class ParticleLandingSheenLayer: CALayer {
    var glint: CGFloat = 0

    override func draw(in ctx: CGContext) {
        let inset = ParticleLineLanding.feather
        let coreWidth = bounds.width - inset * 2
        guard coreWidth > 0, bounds.height > 0 else { return }
        let light = Hologram.color
        let white = NSColor(srgbRed: 0.87, green: 1, blue: 0.96, alpha: 1)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let core = CGRect(x: inset, y: bounds.midY - 0.5, width: coreWidth, height: 1)
        if let halo = CGGradient(colorsSpace: space, colors: [light.withAlphaComponent(0.20).cgColor,
                                                               light.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 1]) {
            ctx.saveGState()
            ctx.translateBy(x: bounds.midX, y: bounds.midY)
            ctx.scaleBy(x: bounds.width / 2, y: 4.5)
            ctx.drawRadialGradient(halo, startCenter: .zero, startRadius: 0,
                                   endCenter: .zero, endRadius: 1, options: [])
            ctx.restoreGState()
        }
        if let line = CGGradient(colorsSpace: space,
                                 colors: [white.withAlphaComponent(0).cgColor,
                                          light.withAlphaComponent(0.40).cgColor,
                                          white.withAlphaComponent(0.76).cgColor,
                                          white.withAlphaComponent(0.20).cgColor,
                                          white.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 0.18, 0.46, 0.78, 1]) {
            ctx.saveGState()
            ctx.clip(to: core)
            ctx.drawLinearGradient(line, start: CGPoint(x: core.minX, y: core.midY),
                                   end: CGPoint(x: core.maxX, y: core.midY), options: [])
            ctx.restoreGState()
        }
        if glint > 0, let head = CGGradient(colorsSpace: space,
                                            colors: [white.withAlphaComponent(0).cgColor,
                                                     white.withAlphaComponent(0.55 * glint).cgColor,
                                                     white.withAlphaComponent(0).cgColor] as CFArray,
                                            locations: [0, 0.48, 1]) {
            let front = CGRect(x: core.minX - 2, y: core.midY - 0.65, width: min(24, core.width + 8), height: 1.3)
            ctx.saveGState(); ctx.clip(to: front)
            ctx.drawLinearGradient(head, start: CGPoint(x: front.minX, y: front.midY),
                                   end: CGPoint(x: front.maxX, y: front.midY), options: [])
            ctx.restoreGState()
        }
    }
}

/// Vector batches keep a screen-spanning stream cheap: no full-screen bitmap
/// is repainted each frame and the original thumbnail is only decoded once.
@MainActor
final class ParticleTransferVisuals {
    let layer = CALayer()
    private let motes = (0..<12).map { _ in CAShapeLayer() }
    private let trails = (0..<4).map { _ in CAShapeLayer() }
    private let sheen = ParticleLandingSheenLayer()

    init() {
        let white = NSColor(srgbRed: 0.87, green: 1, blue: 0.96, alpha: 1)
        let gold = NSColor(srgbRed: 1, green: 0.88, blue: 0.65, alpha: 1)
        let colors = [Hologram.color, white, gold]
        layer.isHidden = true
        for (index, tail) in trails.enumerated() {
            tail.fillColor = nil
            tail.strokeColor = Hologram.color.withAlphaComponent(CGFloat(index + 1) * 0.09).cgColor
            tail.lineWidth = 0.65
            tail.lineCap = .round
            layer.addSublayer(tail)
        }
        for (index, mote) in motes.enumerated() {
            mote.fillColor = colors[index / 4].withAlphaComponent((CGFloat(index % 4) + 0.5) / 4).cgColor
            mote.shadowColor = Hologram.color.cgColor
            mote.shadowOpacity = 0.28
            mote.shadowRadius = 2
            mote.shadowOffset = .zero
            layer.addSublayer(mote)
        }
        layer.addSublayer(sheen)
    }

    func update(_ frame: ParticleTransferMotion.Frame, bounds: CGRect, destination: CGPoint, scale: CGFloat) {
        layer.isHidden = false
        layer.frame = CGRect(origin: .zero, size: bounds.size)
        layer.opacity = Float(frame.opacity)
        let paths = (0..<12).map { _ in CGMutablePath() }
        let tailPaths = (0..<4).map { _ in CGMutablePath() }
        for (index, p) in frame.particles.enumerated() where p.opacity > 0.01 {
            let color = p.warm ? 2 : (index % 3 == 0 ? 1 : 0)
            let level = min(3, max(0, Int(p.opacity * 4)))
            let point = CGPoint(x: p.position.x - bounds.minX, y: p.position.y - bounds.minY)
            let tail = CGPoint(x: p.tail.x - bounds.minX, y: p.tail.y - bounds.minY)
            paths[color * 4 + level].addEllipse(in: CGRect(x: point.x - p.radius, y: point.y - p.radius,
                                                         width: p.radius * 2, height: p.radius * 2))
            if hypot(point.x - tail.x, point.y - tail.y) > 0.4 {
                tailPaths[level].move(to: tail)
                tailPaths[level].addLine(to: point)
            }
        }
        for index in motes.indices {
            motes[index].frame = layer.bounds
            motes[index].contentsScale = scale
            motes[index].path = paths[index]
        }
        for index in trails.indices {
            trails[index].frame = layer.bounds
            trails[index].contentsScale = scale
            trails[index].path = tailPaths[index]
        }
        let band = frame.landing.band(at: frame.arrival)
        var core = band.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        core.origin.y = (core.origin.y * scale).rounded() / scale
        sheen.frame = core.insetBy(dx: -ParticleLineLanding.feather, dy: -8.5)
        sheen.contentsScale = scale
        sheen.opacity = Float(band.opacity)
        sheen.glint = band.opacity > 0 ? band.glintOpacity / band.opacity : 0
        sheen.setNeedsDisplay()
        sheen.displayIfNeeded()
    }

    func clear() {
        layer.isHidden = true
        for shape in motes + trails { shape.path = nil }
        sheen.opacity = 0
        sheen.contents = nil
        sheen.frame = .zero
    }
}

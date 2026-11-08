import CoreGraphics

struct PaperPlane {
    let image: CGImage
    let pointsLeft: Bool
    private let reverse: CGImage
    private static let wingLight = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(),
                                               colorComponents: [1, 0.26, 1, 0],
                                               locations: [0, 1], count: 2)!

    init(image: CGImage, pointsLeft: Bool) {
        self.image = image
        self.pointsLeft = pointsLeft
        // The unprinted strip inside the left edge has the actual paper's
        // color and its light-to-dark grain, even on an older clipping.
        let margin = CGRect(x: image.width / 40, y: 0, width: 1, height: image.height)
        reverse = image.cropping(to: margin) ?? image
    }

    func draw(in ctx: CGContext, size: CGSize, fold: CGFloat) {
        let sheet = CGRect(origin: .zero, size: size)
        guard size.width > 0, size.height > 0 else { return }
        guard fold > 0 else { ctx.draw(image, in: sheet); return }

        // All hinges meet at the nose. Reflect the *source* geometry as well
        // when flying left, so the print starts right-side up in either case.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (pointsLeft ? 1 - x : x) * size.width, y: y * size.height)
        }
        let upperCorner = turn(fold, from: 0, to: 0.29)
        let lowerCorner = turn(fold, from: 0.17, to: 0.46)
        let pinch = turn(fold, from: 0.41, to: 0.76)
        let farWing = turn(fold, from: 0.71, to: 0.94)
        let nearWing = turn(fold, from: 0.76, to: 1)
        let crease = max(0.08, 1 - size.height / (2 * size.width))
        let flatNose = p(1, 0.50)
        let nose = mix(flatNose, p(0.995, 0.63), pinch)

        // Rim vertices from the top corner: the two corner folds,
        // broad wings and the two narrow faces of the keel tile the sheet.
        let flat = [p(1, 1), p(crease, 1), p(0, 1), p(0, 0.58), p(0, 0.50),
                    p(0, 0.42), p(0, 0), p(crease, 0), p(1, 0)]
        var tucked = flat
        tucked[0] = mix(flat[0], p(crease, 0.50), upperCorner)
        tucked[8] = mix(flat[8], p(crease, 0.50), lowerCorner)

        // Pinch almost edge-on before opening the wings. The exposed keel
        // and the offset wingtips give the glider a three-quarter silhouette.
        let pinched = [p(0.66, 0.50), p(0.62, 0.57), p(0.065, 0.61),
                       p(0.16, 0.49), p(0.20, 0.29), p(0.25, 0.43),
                       p(0.12, 0.48), p(0.63, 0.52), p(0.66, 0.48)]
        let tip = p(0.995, 0.63)
        let far = p(0.015, 0.91), near = p(0.36, 0.055)
        let farRoot = p(0.275, 0.49), keel = p(0.255, 0.14), nearRoot = p(0.40, 0.34)
        let open = [mix(tip, far, 0.32), mix(tip, far, 0.49), far, farRoot, keel, nearRoot, near,
                    mix(tip, near, 0.49), mix(tip, near, 0.32)]
        let rim = flat.indices.map { i in
            mix(mix(tucked[i], pinched[i], pinch), open[i], i < 4 ? farWing : nearWing)
        }

        // Draw an uninterrupted stock underneath the touching triangles. This
        // keeps a hairline of screen color from showing through a moving crease.
        ctx.saveGState()
        ctx.beginPath()
        ctx.move(to: nose)
        for vertex in rim[1...7] { ctx.addLine(to: vertex) }
        ctx.closePath()
        ctx.clip()
        ctx.draw(reverse, in: sheet)
        ctx.restoreGState()

        // Corner flaps reveal their blank reverse when they pass edge-on.
        // As the body closes, the remaining print disappears into the fold.
        let ink: [CGFloat] = [upperCorner < 0.5 ? 1 : 0, 1 - pinch, 1 - pinch, 1 - pinch,
                              1 - pinch, 1 - pinch, 1 - pinch, lowerCorner < 0.5 ? 1 : 0]
        let light: [CGFloat] = [-0.12 * upperCorner, -0.12 * pinch, -0.12 * pinch, -0.31 * pinch,
                                -0.18 * pinch, 0.09 * pinch, 0.09 * pinch, 0.14 * lowerCorner]
        for i in [1, 2, 3, 4, 5, 6, 0, 7] {
            drawFace(in: ctx, sheet: sheet, source: flatNose, from: flat[i], to: flat[i + 1],
                     nose: nose, from: rim[i], to: rim[i + 1], ink: ink[i], light: light[i])
        }

        // Soft reflected light across the wings; only the center fold has
        // a crisp edge, so the silhouette stays legible at the smallest size.
        for (outer, root, amount) in [(rim[2], rim[3], farWing), (rim[6], rim[5], nearWing)] where amount > 0 {
            ctx.saveGState()
            ctx.beginPath()
            ctx.move(to: nose)
            ctx.addLine(to: outer)
            ctx.addLine(to: root)
            ctx.closePath()
            ctx.clip()
            ctx.setAlpha(amount)
            ctx.drawLinearGradient(Self.wingLight, start: mix(nose, outer, 0.7), end: mix(nose, root, 0.7),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        if pinch > 0 {
            ctx.saveGState()
            ctx.move(to: rim[3])
            ctx.addLine(to: nose)
            ctx.setLineWidth(max(0.42, size.width * 0.005))
            ctx.setStrokeColor(gray: 1, alpha: pinch * 0.68)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func drawFace(in ctx: CGContext, sheet: CGRect, source: CGPoint, from a: CGPoint, to b: CGPoint,
                          nose: CGPoint, from u: CGPoint, to v: CGPoint, ink: CGFloat, light: CGFloat) {
        let sa = CGVector(dx: a.x - source.x, dy: a.y - source.y)
        let sb = CGVector(dx: b.x - source.x, dy: b.y - source.y)
        let du = CGVector(dx: u.x - nose.x, dy: u.y - nose.y)
        let dv = CGVector(dx: v.x - nose.x, dy: v.y - nose.y)
        let det = sa.dx * sb.dy - sa.dy * sb.dx
        guard abs(det) > 0.001, abs(du.dx * dv.dy - du.dy * dv.dx) > 0.001 else { return }
        let map = CGAffineTransform(a: (du.dx * sb.dy - dv.dx * sa.dy) / det,
                                    b: (du.dy * sb.dy - dv.dy * sa.dy) / det,
                                    c: (sa.dx * dv.dx - sb.dx * du.dx) / det,
                                    d: (sa.dx * dv.dy - sb.dx * du.dy) / det, tx: 0, ty: 0)
        ctx.saveGState()
        ctx.beginPath()
        ctx.move(to: nose)
        ctx.addLine(to: u)
        ctx.addLine(to: v)
        ctx.closePath()
        ctx.clip()
        ctx.translateBy(x: nose.x, y: nose.y)
        ctx.concatenate(map)
        ctx.translateBy(x: -source.x, y: -source.y)
        if ink < 1 { ctx.draw(reverse, in: sheet) }
        if ink > 0 {
            ctx.setAlpha(ink)
            ctx.draw(image, in: sheet)
            ctx.setAlpha(1)
        }
        ctx.setFillColor(gray: light > 0 ? 1 : 0, alpha: abs(light))
        ctx.fill(sheet)
        ctx.restoreGState()
    }

    private func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func turn(_ fold: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        let t = min(1, max(0, (fold - start) / (end - start)))
        return (1 - cos(.pi * t)) / 2
    }
}

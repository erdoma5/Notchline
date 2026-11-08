import CoreGraphics
import Foundation

/// A short fracture wave begins at the grip. Each fleck carries
/// the original color and alpha of its patch, including at the rounded corners.
struct PhotoDust {
    static let lifetime = 0.88

    private struct Fleck {
        let color: CGColor
        let rect: CGRect
        let dx, dy, curl, spin, delay, duration: CGFloat
    }
    private let flecks: [Fleck]
    private let image: CGImage
    private let bounds: CGRect

    init(image: CGImage, size: CGSize, grip: CGPoint) {
        self.image = image
        bounds = CGRect(origin: .zero, size: size)
        // Read the thumbnail once. In flight a fleck is only a few pixels
        // wide; painting its coverage-weighted color avoids decoding hundreds
        // of tiny CGImage crops on the main thread at every frame.
        guard let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                     bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { flecks = []; return }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        func color(x: Int, y: Int, width: Int, height: Int) -> CGColor? {
            var r = 0, g = 0, b = 0, a = 0
            for row in y..<(y + height) {
                var pixel = bytes.advanced(by: row * bitmap.bytesPerRow + x * 4)
                for _ in 0..<width {
                    r += Int(pixel[0]); g += Int(pixel[1]); b += Int(pixel[2]); a += Int(pixel[3])
                    pixel += 4
                }
            }
            guard a > 0 else { return nil }
            return CGColor(srgbRed: CGFloat(r) / CGFloat(a), green: CGFloat(g) / CGFloat(a),
                           blue: CGFloat(b) / CGFloat(a), alpha: CGFloat(a) / CGFloat(255 * width * height))
        }
        let sx = size.width / CGFloat(image.width), sy = size.height / CGFloat(image.height)
        let grain = max(2.1, sqrt(size.width * size.height / 820))
        let diagonal = hypot(size.width, size.height)
        var pieces: [Fleck] = []
        var y = 0
        while y < image.height {
            let height = min(image.height - y, max(1, Int(grain * .random(in: 0.7...1.25) / sy)))
            var x = 0
            while x < image.width {
                let width = min(image.width - x, max(1, Int(grain * .random(in: 0.55...1.55) / sx)))
                if let color = color(x: x, y: y, width: width, height: height) {
                    // Bitmap rows count down from the top, AppKit points up.
                    let rect = CGRect(x: CGFloat(x) * sx, y: CGFloat(image.height - y - height) * sy,
                                      width: CGFloat(width) * sx, height: CGFloat(height) * sy)
                    let vx = rect.midX - grip.x, vy = rect.midY - grip.y
                    let angle = atan2(vy, vx) + CGFloat.random(in: -0.85...0.85)
                    let reach = CGFloat.random(in: 17...79)
                    pieces.append(Fleck(color: color, rect: rect,
                                        dx: cos(angle) * reach + 13, dy: sin(angle) * reach + 24,
                                        curl: .random(in: -11...11), spin: .random(in: -2.7...2.7),
                                        delay: min(1, hypot(vx, vy) / diagonal) * 0.14 + .random(in: 0...0.055),
                                        duration: .random(in: 0.42...0.68)))
                }
                x += width
            }
            y += height
        }
        flecks = pieces
    }

    func draw(in ctx: CGContext, elapsed: CGFloat) {
        // Until the wave arrives, keep the original image sharp. A single
        // clipped image draw preserves text and edges between flying grains.
        if elapsed < 0.20 {
            let intact = CGMutablePath()
            for fleck in flecks where elapsed <= fleck.delay { intact.addRect(fleck.rect) }
            ctx.saveGState()
            ctx.setShouldAntialias(false)
            ctx.addPath(intact)
            ctx.clip()
            ctx.draw(image, in: bounds)
            ctx.restoreGState()
        }
        for fleck in flecks {
            let t = (elapsed - fleck.delay) / fleck.duration
            guard t > 0, t < 1 else { continue }
            let outward = t * (2 - t)
            let shrink = 1 - 0.95 * t
            let width = fleck.rect.width * shrink, height = fleck.rect.height * shrink
            ctx.saveGState()
            ctx.translateBy(x: fleck.rect.midX + fleck.dx * outward + fleck.curl * sin(t * .pi),
                            y: fleck.rect.midY + fleck.dy * outward + 10 * t * t)
            ctx.rotate(by: fleck.spin * outward)
            ctx.setAlpha(1 - t * t)
            ctx.setFillColor(fleck.color)
            ctx.fill(CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
            ctx.restoreGState()
        }
    }
}

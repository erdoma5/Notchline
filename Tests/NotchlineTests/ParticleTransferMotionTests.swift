import AppKit
import QuartzCore
import XCTest
@testable import Notchline

final class ParticleTransferMotionTests: XCTestCase {
    func testTransferStartsAtSourceAndEndsWithoutResidualParticles() {
        let card = CGRect(x: 100, y: 600, width: 140, height: 104)
        let motion = ParticleTransferMotion(card: card, destination: CGPoint(x: 700, y: 150))
        let first = motion.frame(at: 0), last = motion.frame(at: 1)
        XCTAssertEqual(first.sourceProgress, 0)
        XCTAssertFalse(first.sourceReleased)
        XCTAssertTrue(first.particles.allSatisfy { $0.opacity == 0 && card.contains($0.position) })
        XCTAssertEqual(last.sourceProgress, 1)
        XCTAssertTrue(last.sourceReleased)
        XCTAssertEqual(last.opacity, 0)
        XCTAssertTrue(last.particles.allSatisfy { $0.opacity == 0 })
        XCTAssertFalse(motion.frame(at: 0.35).sourceReleased)
        XCTAssertTrue(motion.frame(at: 0.37).sourceReleased)
    }

    func testParticlesFormADistributedStreamInsteadOfMovingAsOnePacket() {
        let motion = ParticleTransferMotion(card: CGRect(x: 90, y: 650, width: 140, height: 100),
                                            destination: CGPoint(x: 850, y: 150))
        let particles = motion.frame(at: 0.50).particles.filter { $0.opacity > 0.1 }
        XCTAssertGreaterThan(particles.count, 80)
        let xs = particles.map(\.position.x)
        XCTAssertGreaterThan((xs.max() ?? 0) - (xs.min() ?? 0), 250,
                             "The head must be well ahead of the particles still departing")
        XCTAssertGreaterThan(particles.filter { hypot($0.position.x - $0.tail.x, $0.position.y - $0.tail.y) > 3 }.count, 40)
    }

    func testBoundsAndDeterminismAcrossScreenDirectionsAndSamePlace() {
        let card = CGRect(x: -600, y: 1050, width: 140, height: 104)
        for end in [CGPoint(x: -530, y: 1102), CGPoint(x: -1300, y: 850), CGPoint(x: 900, y: -150),
                    CGPoint(x: -530, y: 400), CGPoint(x: -530, y: 1500)] {
            let motion = ParticleTransferMotion(card: card, destination: end,
                                                sourceScreen: CGRect(x: -1600, y: 800, width: 1600, height: 900))
            for step in 0...100 {
                let first = motion.frame(at: CGFloat(step) / 100)
                let repeatFrame = motion.frame(at: CGFloat(step) / 100)
                for (a, b) in zip(first.particles, repeatFrame.particles) {
                    XCTAssertEqual(a.position, b.position)
                    XCTAssertEqual(a.tail, b.tail)
                    XCTAssertEqual(a.opacity, b.opacity)
                    XCTAssertTrue(motion.bounds.contains(a.position))
                    XCTAssertTrue(motion.bounds.contains(a.tail))
                }
            }
        }
    }

    /// Render the production vector layers over a sample source and editor.
    /// The opt-in frame sequence makes motion QA possible without user content.
    @MainActor
    func testRenderNativeTransferFramesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["NOTCHLINE_TRANSFER_PREVIEW_DIR"] else { return }
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let card = CGRect(x: 115, y: 252, width: 144, height: 104)
        let destination = CGPoint(x: 566, y: 94)
        let motion = ParticleTransferMotion(card: card, destination: destination)
        let image = try XCTUnwrap(TextNote("让灵感有个落脚点。", stock: .mint).thumbnail(scale: 2)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let visuals = ParticleTransferVisuals()
        for index in 0...60 {
            let fraction = CGFloat(index) / 60, state = motion.frame(at: fraction)
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 1440, height: 800, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.scaleBy(x: 2, y: 2)
            ctx.setFillColor(NSColor(srgbRed: 0.07, green: 0.10, blue: 0.14, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 720, height: 400))
            ctx.setFillColor(Hologram.color.withAlphaComponent(0.30).cgColor)
            ctx.fill(CGRect(x: 87, y: 248, width: 200, height: 4))
            ctx.setFillColor(NSColor(white: 1, alpha: 0.04).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 424, y: 45, width: 260, height: 78), cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath()
            let sourceOpacity: CGFloat = state.sourceReleased ? 1 : 0.14
            ctx.saveGState(); ctx.setAlpha(sourceOpacity); ctx.draw(image, in: card); ctx.restoreGState()
            if !state.sourceReleased {
                ctx.saveGState(); ctx.translateBy(x: card.minX, y: card.minY)
                ParticleRendering.departure(image: image, in: ctx, size: card.size, progress: state.sourceProgress)
                ctx.restoreGState()
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            visuals.update(state, bounds: motion.bounds, destination: destination, scale: 2)
            CATransaction.commit()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("粒子转移 · 原生动画示例" as NSString).draw(at: CGPoint(x: 24, y: 368), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: 0.85, alpha: 1)])
            ("已粘贴：让灵感有个落脚点。" as NSString).draw(at: CGPoint(x: 440, y: 83), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.82, alpha: 1)])
            ("原件保留在收纳槽" as NSString).draw(at: CGPoint(x: 117, y: 226), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.48, alpha: 1)])
            NSGraphicsContext.restoreGraphicsState()
            // The real nonactivating transfer window sits above the editor.
            ctx.saveGState(); ctx.translateBy(x: motion.bounds.minX, y: motion.bounds.minY)
            visuals.layer.render(in: ctx); ctx.restoreGState()
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(String(format: "frame-%03d.png", index)))
        }
        visuals.clear()
    }
}

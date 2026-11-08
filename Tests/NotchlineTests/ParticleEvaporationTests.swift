import AppKit
import CoreGraphics
import XCTest
@testable import Notchline

final class ParticleEvaporationTests: XCTestCase {
    private let cardSize = CGSize(width: 150, height: 104)

    private func context(size: CGSize, scale: CGFloat = 2) throws -> CGContext {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: scale, y: scale)
        return ctx
    }

    private func bytes(_ ctx: CGContext) throws -> Data {
        Data(bytes: try XCTUnwrap(ctx.data), count: ctx.bytesPerRow * ctx.height)
    }

    private func alphaSum(_ ctx: CGContext, in rect: CGRect? = nil) throws -> Int {
        let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        let area = rect ?? CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        var sum = 0
        for y in max(0, Int(area.minY))..<min(ctx.height, Int(area.maxY)) {
            for x in max(0, Int(area.minX))..<min(ctx.width, Int(area.maxX)) {
                sum += Int(pixels[y * ctx.bytesPerRow + x * 4 + 3])
            }
        }
        return sum
    }

    private func fixture(size: CGSize) throws -> CGImage {
        let ctx = try context(size: size)
        let rect = CGRect(origin: .zero, size: size)
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.90, blue: 0.75, alpha: 1))
        ctx.fill(rect)
        ctx.setFillColor(CGColor(srgbRed: 0.24, green: 0.59, blue: 0.64, alpha: 1))
        ctx.fill(CGRect(x: 0, y: size.height * 0.82, width: size.width, height: size.height * 0.12))
        ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.27, blue: 0.29, alpha: 1))
        // Asymmetric interior marks detect source motion and shrinking.
        ctx.fill(CGRect(x: size.width * 0.28, y: size.height * 0.38,
                        width: size.width * 0.31, height: size.height * 0.055))
        ctx.fill(CGRect(x: size.width * 0.37, y: size.height * 0.52,
                        width: size.width * 0.29, height: size.height * 0.045))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func render(_ image: CGImage, size: CGSize, progress: CGFloat) throws -> CGContext {
        let ctx = try context(size: CGSize(width: size.width + 80, height: size.height + 80))
        ctx.translateBy(x: 40, y: 40)
        ParticleEvaporation.draw(image: image, in: ctx, size: size, progress: progress)
        return ctx
    }

    func testEvaporationStartsWithOriginalPixelsAndLeavesNoResidualAtFinish() throws {
        for size in [cardSize, CGSize(width: 68, height: 148), CGSize(width: 12, height: 9)] {
            let image = try fixture(size: size)
            let original = try context(size: CGSize(width: size.width + 80, height: size.height + 80))
            original.translateBy(x: 40, y: 40)
            original.draw(image, in: CGRect(origin: .zero, size: size))
            XCTAssertEqual(try bytes(render(image, size: size, progress: 0)), try bytes(original))
            XCTAssertEqual(try alphaSum(render(image, size: size, progress: 1)), 0)
            XCTAssertEqual(try alphaSum(render(image, size: size, progress: 1.1)), 0)
        }
    }

    func testRemainingInteriorDoesNotShrinkOrMoveAsThePerimeterEvaporates() throws {
        let image = try fixture(size: cardSize)
        let original = try render(image, size: cardSize, progress: 0)
        let evaporating = try render(image, size: cardSize, progress: 0.12)
        let expected = try bytes(original), actual = try bytes(evaporating)
        // This crop includes both asymmetric marks but excludes the eroding rim.
        let minX = Int((40 + cardSize.width * 0.26) * 2)
        let maxX = Int((40 + cardSize.width * 0.69) * 2)
        let minY = Int((40 + cardSize.height * 0.34) * 2)
        let maxY = Int((40 + cardSize.height * 0.59) * 2)
        for y in minY..<maxY {
            let start = y * original.bytesPerRow + minX * 4
            let end = y * original.bytesPerRow + maxX * 4
            XCTAssertEqual(actual[start..<end], expected[start..<end], "Deleting must erase in place, not scale the card")
        }
    }

    func testIntermediateFramesAreDeterministicAndActuallyDissolve() throws {
        let image = try fixture(size: cardSize)
        let originalAlpha = try alphaSum(render(image, size: cardSize, progress: 0))
        for progress: CGFloat in [0.24, 0.47, 0.72] {
            let first = try render(image, size: cardSize, progress: progress)
            let second = try render(image, size: cardSize, progress: progress)
            XCTAssertEqual(try bytes(first), try bytes(second))
            XCTAssertGreaterThan(try alphaSum(first), 0)
            XCTAssertLessThan(try alphaSum(first), originalAlpha)
        }
    }

    func testReducedMotionPendingStateIsStillAndKeepsContentReadable() throws {
        let image = try fixture(size: cardSize)
        func held(time: Double) throws -> CGContext {
            let ctx = try context(size: CGSize(width: 230, height: 184))
            ctx.translateBy(x: 40, y: 40)
            ParticleEvaporation.drawHeld(image: image, in: ctx, size: cardSize,
                readiness: 1, time: time, reducedMotion: true,
                reducedTransparency: true, increasedContrast: true)
            return ctx
        }
        let first = try held(time: 0), second = try held(time: 2.37)
        XCTAssertEqual(try bytes(first), try bytes(second))
        let original = try render(image, size: cardSize, progress: 0)
        let center = CGRect(x: 140, y: 140, width: 100, height: 70)
        XCTAssertEqual(try alphaSum(first, in: center), try alphaSum(original, in: center))
    }

    func testErasureReachesTopAndSidesBeforeTheInterior() {
        let center = ParticleEvaporation.erasureStart(at: CGPoint(x: 75, y: 46), size: cardSize)
        for point in [CGPoint(x: 75, y: 103), CGPoint(x: 1, y: 52), CGPoint(x: 149, y: 52)] {
            XCTAssertLessThan(ParticleEvaporation.erasureStart(at: point, size: cardSize), center)
        }
    }

    /// Export the actual production renderer over opaque backgrounds, using only
    /// synthetic content. Frames cover held → pending → released → fully clear.
    @MainActor
    func testRenderNativeEvaporationFramesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["NOTCHLINE_EVAPORATION_PREVIEW_DIR"] else { return }
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let noteSize = CGSize(width: 170, height: 124)
        let photoSize = CGSize(width: 174, height: 112)
        let note = try previewNote(size: noteSize)
        let photo = try previewPhoto(size: photoSize)
        for dark in [true, false] {
            for frame in 0...83 {
                let ctx = try context(size: CGSize(width: 660, height: 288))
                ctx.setFillColor(CGColor(srgbRed: dark ? 0.055 : 0.94,
                                        green: dark ? 0.075 : 0.95, blue: dark ? 0.10 : 0.96, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 660, height: 288))
                let primary = dark ? NSColor(srgbRed: 0.89, green: 0.95, blue: 0.95, alpha: 1) : NSColor(srgbRed: 0.12, green: 0.19, blue: 0.22, alpha: 1)
                let secondary = dark ? NSColor(srgbRed: 0.44, green: 0.55, blue: 0.60, alpha: 1) : NSColor(srgbRed: 0.40, green: 0.48, blue: 0.51, alpha: 1)
                drawText("粒子蒸发", at: CGPoint(x: 30, y: 244), font: .systemFont(ofSize: 17, weight: .semibold), color: primary, in: ctx)
                let label = frame < 12 ? "拖离光槽" : frame < 36 ? "松手即可移除 · 卡片仍然清晰" : frame < 72 ? "松手 · 凝聚消散" : "已移除 · 可撤销"
                drawText(label, at: CGPoint(x: 30, y: 222), font: .systemFont(ofSize: 10), color: secondary, in: ctx)
                ctx.setFillColor(secondary.withAlphaComponent(0.18).cgColor)
                ctx.fill(CGRect(x: 30, y: 210, width: 600, height: 0.5))
                let readiness = Hologram.ease(CGFloat(frame) / 24)
                let progress = min(1, max(0, CGFloat(frame - 36) / 35))
                for (image, size, x) in [(note, noteSize, CGFloat(113)), (photo, photoSize, CGFloat(378))] {
                    ctx.saveGState()
                    ctx.translateBy(x: x, y: 64)
                    if frame < 36 {
                        ParticleEvaporation.drawHeld(image: image, in: ctx, size: size,
                            readiness: readiness, time: Double(frame) / 60)
                    } else {
                        ParticleEvaporation.draw(image: image, in: ctx, size: size, progress: progress)
                    }
                    ctx.restoreGState()
                }
                drawText("便签", at: CGPoint(x: 185, y: 28), font: .systemFont(ofSize: 10), color: secondary, in: ctx)
                drawText("照片", at: CGPoint(x: 451, y: 28), font: .systemFont(ofSize: 10), color: secondary, in: ctx)
                let image = try XCTUnwrap(ctx.makeImage())
                let bitmap = NSBitmapImageRep(cgImage: image)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent(String(format: "%@-%03d.png", dark ? "dark" : "light", frame)))
            }
        }
    }

    @MainActor
    private func drawText(_ text: String, at point: CGPoint, font: NSFont, color: NSColor, in ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
        NSGraphicsContext.restoreGraphicsState()
    }

    @MainActor
    private func previewNote(size: CGSize) throws -> CGImage {
        let ctx = try context(size: size)
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.91, green: 0.93, blue: 0.80, alpha: 1)); ctx.fillPath()
        let ink = NSColor(srgbRed: 0.22, green: 0.29, blue: 0.25, alpha: 1)
        drawText("留一点时间给灵感", at: CGPoint(x: 15, y: 91), font: .systemFont(ofSize: 12, weight: .medium), color: ink, in: ctx)
        drawText("周末去山里走走", at: CGPoint(x: 15, y: 64), font: .systemFont(ofSize: 10), color: ink.withAlphaComponent(0.8), in: ctx)
        drawText("带上相机，慢一点。", at: CGPoint(x: 15, y: 46), font: .systemFont(ofSize: 10), color: ink.withAlphaComponent(0.8), in: ctx)
        return try XCTUnwrap(ctx.makeImage())
    }

    private func previewPhoto(size: CGSize) throws -> CGImage {
        let ctx = try context(size: size)
        let rect = CGRect(origin: .zero, size: size)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil)); ctx.clip()
        ctx.setFillColor(CGColor(srgbRed: 0.39, green: 0.55, blue: 0.59, alpha: 1)); ctx.fill(rect)
        ctx.setFillColor(CGColor(srgbRed: 0.87, green: 0.84, blue: 0.69, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 125, y: 76, width: 17, height: 17))
        for (offset, color) in [(CGFloat(24), CGColor(srgbRed: 0.28, green: 0.43, blue: 0.44, alpha: 1)),
                                (CGFloat(-10), CGColor(srgbRed: 0.12, green: 0.28, blue: 0.29, alpha: 1))] {
            ctx.move(to: CGPoint(x: -15, y: 0))
            ctx.addLine(to: CGPoint(x: 52 + offset, y: 87 + offset * 0.25))
            ctx.addLine(to: CGPoint(x: 96 + offset, y: 43))
            ctx.addLine(to: CGPoint(x: 135 + offset, y: 71))
            ctx.addLine(to: CGPoint(x: size.width + 20, y: 0)); ctx.closePath()
            ctx.setFillColor(color); ctx.fillPath()
        }
        return try XCTUnwrap(ctx.makeImage())
    }
}

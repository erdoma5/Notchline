import CoreGraphics
import Foundation
import XCTest
@testable import Notchline

final class ParticleRenderingTests: XCTestCase {
    private let size = CGSize(width: 150, height: 110)
    private let pixelWidth = 300
    private let pixelHeight = 220

    private struct Raster {
        let bytes: Data
        let alphaSum: Int
        let visibleBounds: CGRect?
    }

    private func context() throws -> CGContext {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: 2, y: 2)
        return ctx
    }

    /// Nonuniform colors and transparent corners catch a changed frame,
    /// misplaced image, unwanted glow or premultiplication at progress zero.
    private func fixture() throws -> CGImage {
        let ctx = try context()
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.89, blue: 0.66, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 4, y: 4, width: 142, height: 102),
                          cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(srgbRed: 0.21, green: 0.27, blue: 0.24, alpha: 0.75))
        for row in 0..<5 {
            ctx.fill(CGRect(x: 12, y: CGFloat(20 + row * 15), width: CGFloat(67 + row * 7), height: 3))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.40, green: 0.66, blue: 0.73, alpha: 0.47))
        ctx.fill(CGRect(x: 0, y: 90, width: 150, height: 8))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func raster(_ ctx: CGContext) throws -> Raster {
        let pointer = try XCTUnwrap(ctx.data)
        let bytes = Data(bytes: pointer, count: ctx.bytesPerRow * pixelHeight)
        let pixels = pointer.assumingMemoryBound(to: UInt8.self)
        var sum = 0, minX = pixelWidth, minY = pixelHeight, maxX = -1, maxY = -1
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let alpha = Int(pixels[y * ctx.bytesPerRow + x * 4 + 3])
                sum += alpha
                if alpha > 0 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        let bounds = maxX < 0 ? nil : CGRect(x: CGFloat(minX), y: CGFloat(minY),
                                            width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
        return Raster(bytes: bytes, alphaSum: sum, visibleBounds: bounds)
    }

    private func render(_ image: CGImage, progress: CGFloat, transmission: Bool) throws -> Raster {
        let ctx = try context()
        if transmission {
            ParticleRendering.transmission(image: image, in: ctx, size: size, progress: progress)
        } else {
            ParticleRendering.dissolve(image: image, in: ctx, size: size, progress: progress)
        }
        return try raster(ctx)
    }

    func testBothAnimationsStartWithTheExactOriginalAndDissolveEndsTransparent() throws {
        let image = try fixture(), original = try context()
        original.draw(image, in: CGRect(origin: .zero, size: size))
        let expected = try raster(original)
        XCTAssertGreaterThan(expected.alphaSum, 0)
        for transmission in [false, true] {
            let start = try render(image, progress: 0, transmission: transmission)
            XCTAssertEqual(start.bytes, expected.bytes)
        }
        let end = try render(image, progress: 1, transmission: false)
        XCTAssertEqual(end.alphaSum, 0)
        XCTAssertNil(end.visibleBounds)
    }

    func testTransmissionEndsInAVisibleCompactClusterAtTheOriginalCenter() throws {
        let image = try fixture()
        let source = try render(image, progress: 0, transmission: true)
        let packet = try render(image, progress: 1, transmission: true)
        XCTAssertGreaterThan(packet.alphaSum, 0, "The flight still needs a visible payload after condensation")
        XCTAssertLessThan(packet.alphaSum, source.alphaSum / 5)
        let bounds = try XCTUnwrap(packet.visibleBounds)
        XCTAssertLessThan(bounds.width, CGFloat(pixelWidth) * 0.60)
        XCTAssertLessThan(bounds.height, CGFloat(pixelHeight) * 0.60)
        XCTAssertEqual(bounds.midX, CGFloat(pixelWidth) / 2, accuracy: CGFloat(pixelWidth) * 0.10)
        XCTAssertEqual(bounds.midY, CGFloat(pixelHeight) / 2, accuracy: CGFloat(pixelHeight) * 0.10)
    }

    func testIntermediateFramesDoNotReseedWhenRenderedAgain() throws {
        let image = try fixture()
        for transmission in [false, true] {
            for progress: CGFloat in [0.23, 0.46, 0.71] {
                let first = try render(image, progress: progress, transmission: transmission)
                let second = try render(image, progress: progress, transmission: transmission)
                XCTAssertGreaterThan(first.alphaSum, 0)
                XCTAssertEqual(first.bytes, second.bytes, "The same progress must preserve particle positions and coverage")
            }
        }
    }

    func testGrainMaskFullyHidesAndRevealsEverySampledCell() {
        for row in 0...20 {
            for column in 0...20 {
                let x = CGFloat(column) / 20, y = CGFloat(row) / 20
                for noise: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                    XCTAssertEqual(ParticleMotion.grainOpacity(progress: 0, x: x, y: y, noise: noise), 0)
                    XCTAssertEqual(ParticleMotion.grainOpacity(progress: 1, x: x, y: y, noise: noise), 1)
                }
            }
        }
    }

    func testApproachScaleMovesMonotonicallyFromDepthToTheSurface() {
        XCTAssertEqual(ParticleMotion.scale(0), 0.76, accuracy: 0.000001)
        XCTAssertEqual(ParticleMotion.scale(1), 1, accuracy: 0.000001)
        var previous = ParticleMotion.scale(0)
        for step in 1...100 {
            let next = ParticleMotion.scale(CGFloat(step) / 100)
            XCTAssertGreaterThanOrEqual(next, previous)
            XCTAssertGreaterThanOrEqual(next, 0.76)
            XCTAssertLessThanOrEqual(next, 1)
            previous = next
        }
    }
}

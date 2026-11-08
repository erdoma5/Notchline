import CoreGraphics
import AppKit
import QuartzCore
import XCTest
@testable import Notchline

final class ParticleLineLandingTests: XCTestCase {
    @MainActor
    func testNativeSheenActuallyRendersWideAndClearsAtBothEnds() throws {
        let visuals = ParticleTransferVisuals()
        let landing = ParticleLineLanding(destination: CGPoint(x: 100, y: 16))
        let bounds = CGRect(x: 0, y: -8, width: 140, height: 40)
        func raster(_ progress: CGFloat) throws -> (alpha: Int, width: Int, height: Int) {
            let frame = ParticleTransferMotion.Frame(particles: [], sourceProgress: 1, sourceReleased: true,
                                                     arrival: progress, opacity: 1, landing: landing)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            visuals.update(frame, bounds: bounds, destination: landing.anchor, scale: 2)
            CATransaction.commit()
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 280, height: 80, bitsPerComponent: 8, bytesPerRow: 1120,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.scaleBy(x: 2, y: 2)
            visuals.layer.render(in: ctx)
            let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
            var sum = 0, left = 280, right = -1, bottom = 80, top = -1
            for y in 0..<80 { for x in 0..<280 {
                let alpha = Int(data[y * 1120 + x * 4 + 3]); sum += alpha
                if alpha > 2 { left = min(left, x); right = max(right, x); bottom = min(bottom, y); top = max(top, y) }
            } }
            return (sum, max(0, right - left + 1), max(0, top - bottom + 1))
        }
        XCTAssertEqual(try raster(0).alpha, 0)
        let visible = try raster(0.46)
        XCTAssertGreaterThan(visible.alpha, 0)
        XCTAssertGreaterThan(visible.width, 140, "The visible native core should span more than 70pt")
        XCTAssertLessThan(visible.height, 24, "The ending is a thin horizontal sheen, not a ring")
        XCTAssertEqual(try raster(1).alpha, 0)
        visuals.clear()
        XCTAssertTrue(visuals.layer.isHidden)
        XCTAssertGreaterThan(try raster(0.46).alpha, 0, "A cleared pooled layer must remain reusable")
    }

    func testWideSheenStartsAtTheAnchorAndFadesWithoutALingeringUnderline() {
        let target = CGPoint(x: 400, y: 300)
        let landing = ParticleLineLanding(destination: target)
        XCTAssertEqual(ParticleLineLanding.preferredWidth, 88)
        XCTAssertEqual(landing.anchor, target)
        XCTAssertEqual(landing.right - landing.left, 88, accuracy: 0.0001)
        XCTAssertLessThan(landing.left, target.x)
        XCTAssertGreaterThan(landing.right, target.x)
        XCTAssertEqual(landing.baseline, target.y - 7, accuracy: 0.0001)

        let initial = landing.band(at: 0), final = landing.band(at: 1)
        XCTAssertEqual(initial.rect.minX, target.x, accuracy: 0.0001)
        XCTAssertEqual(initial.rect.width, 0)
        XCTAssertEqual(initial.opacity, 0)
        XCTAssertEqual(initial.glintOpacity, 0)
        XCTAssertEqual(final.rect.minX, landing.left, accuracy: 0.0001)
        XCTAssertEqual(final.rect.width, 88, accuracy: 0.0001)
        XCTAssertEqual(final.opacity, 0)
        XCTAssertEqual(final.glintOpacity, 0)
        XCTAssertGreaterThan(landing.band(at: 0.25).opacity, 0.5)
        XCTAssertGreaterThan(landing.band(at: 0.25).glintOpacity, 0.5)
        XCTAssertLessThan(landing.band(at: 0.85).opacity, landing.band(at: 0.25).opacity)

        var previous: CGFloat = 0
        for step in 0...100 {
            let band = landing.band(at: CGFloat(step) / 100)
            XCTAssertGreaterThanOrEqual(band.rect.width, previous)
            XCTAssertLessThanOrEqual(band.rect.width, 88.0001)
            XCTAssertGreaterThanOrEqual(band.opacity, 0)
            XCTAssertLessThanOrEqual(band.opacity, 1)
            assertContained(band.rect, in: landing.bounds)
            previous = band.rect.width
        }
        XCTAssertLessThanOrEqual(landing.bounds.minX, landing.left - ParticleLineLanding.feather)
        XCTAssertGreaterThanOrEqual(landing.bounds.maxX, landing.right + ParticleLineLanding.feather)
        XCTAssertLessThan(landing.bounds.minY, landing.baseline - 4)
        XCTAssertGreaterThan(landing.bounds.maxY, landing.baseline + 4)
    }

    func testHorizontalEndpointsClampAndAlwaysShareOneBaseline() {
        let landing = ParticleLineLanding(destination: CGPoint(x: -760, y: 1120))
        XCTAssertEqual(landing.point(at: -1), CGPoint(x: landing.left, y: landing.baseline))
        XCTAssertEqual(landing.point(at: 2), CGPoint(x: landing.right, y: landing.baseline))
        var previous = landing.left
        for step in 0...100 {
            let point = landing.point(at: CGFloat(step) / 100)
            XCTAssertEqual(point.y, landing.baseline)
            XCTAssertGreaterThanOrEqual(point.x, previous)
            XCTAssertTrue(landing.bounds.contains(point))
            previous = point.x
        }
    }

    func testLandingUsesTheDestinationDisplayIncludingItsLeftRightAndLowerEdges() {
        let sourceScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let destinationScreen = CGRect(x: -1920, y: 850, width: 1920, height: 1080)
        let card = CGRect(x: 480, y: 680, width: 140, height: 104)
        let targets = [CGPoint(x: destinationScreen.minX + 1, y: 1200),
                       CGPoint(x: destinationScreen.maxX - 1, y: 1200),
                       CGPoint(x: -960, y: destinationScreen.minY + 1)]
        for target in targets {
            let motion = ParticleTransferMotion(card: card, destination: target,
                                                sourceScreen: sourceScreen, destinationScreen: destinationScreen)
            let landing = motion.landing
            XCTAssertEqual(landing.anchor, target)
            XCTAssertGreaterThanOrEqual(landing.left, destinationScreen.minX)
            XCTAssertLessThanOrEqual(landing.right, destinationScreen.maxX)
            XCTAssertEqual(landing.right - landing.left, 88, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(landing.left, target.x)
            XCTAssertGreaterThanOrEqual(landing.right, target.x)
            XCTAssertGreaterThanOrEqual(landing.baseline, destinationScreen.minY + 2)
            XCTAssertLessThanOrEqual(landing.baseline, destinationScreen.maxY - 2)
            XCTAssertTrue(motion.bounds.contains(landing.bounds), "The feathered end must not be clipped by the transfer window")
            XCTAssertEqual(motion.frame(at: 0.8).landing.anchor, target)
            XCTAssertEqual(motion.frame(at: 0.8).landing.baseline, landing.baseline)
        }
    }

    func testVeryNarrowDisplaysProduceFiniteNonnegativeBandsInsideTheDisplay() {
        for width: CGFloat in [1, 4, 8, 12, 24, 60] {
            let screen = CGRect(x: -200, y: 400, width: width, height: 200)
            for fraction: CGFloat in [0.1, 0.5, 0.9] {
                let destination = CGPoint(x: screen.minX + width * fraction, y: screen.minY + 1)
                let landing = ParticleLineLanding(destination: destination, screen: screen)
                XCTAssertTrue(landing.left.isFinite && landing.right.isFinite && landing.baseline.isFinite)
                XCTAssertGreaterThanOrEqual(landing.left, screen.minX)
                XCTAssertLessThanOrEqual(landing.right, screen.maxX)
                XCTAssertGreaterThanOrEqual(landing.right - landing.left, 0)
                XCTAssertLessThanOrEqual(landing.right - landing.left, width)
                for progress: CGFloat in [0, 0.2, 0.5, 1] {
                    let band = landing.band(at: progress)
                    XCTAssertTrue(band.rect.minX.isFinite && band.rect.maxX.isFinite)
                    XCTAssertGreaterThanOrEqual(band.rect.width, 0)
                    assertContained(band.rect, in: landing.bounds)
                }
            }
        }
    }

    func testFinalParticlesSpreadAlongTheLineAndTheirWholeApproachFitsTheWindow() throws {
        let card = CGRect(x: -600, y: 1050, width: 140, height: 104)
        let source = CGRect(x: -1600, y: 800, width: 1600, height: 900)
        let cases: [(CGPoint, CGRect?)] = [
            (CGPoint(x: -530, y: 1102), source),
            (CGPoint(x: -1599, y: 920), source),
            (CGPoint(x: 1439, y: 1), CGRect(x: 0, y: 0, width: 1440, height: 900)),
            (CGPoint(x: 25, y: -600), CGRect(x: -50, y: -900, width: 80, height: 700)),
            (CGPoint(x: -530, y: 400), nil)
        ]
        for (target, destinationScreen) in cases {
            let motion = ParticleTransferMotion(card: card, destination: target,
                                                sourceScreen: source, destinationScreen: destinationScreen)
            let final = motion.frame(at: 1)
            for particle in final.particles {
                XCTAssertEqual(particle.position.y, motion.landing.baseline, accuracy: 0.0001)
                XCTAssertGreaterThanOrEqual(particle.position.x, motion.landing.left - 0.0001)
                XCTAssertLessThanOrEqual(particle.position.x, motion.landing.right + 0.0001)
                XCTAssertEqual(particle.opacity, 0)
            }
            let xs = final.particles.map(\.position.x)
            let spread = try XCTUnwrap(xs.max()) - XCTUnwrap(xs.min())
            XCTAssertGreaterThan(spread, (motion.landing.right - motion.landing.left) * 0.65,
                                 "The last particles should fan out horizontally, not all enter one point")
            for step in 0...200 {
                let frame = motion.frame(at: CGFloat(step) / 200)
                for particle in frame.particles {
                    XCTAssertTrue(motion.bounds.contains(particle.position), "Particle outside bounds at step \(step) toward \(target)")
                    XCTAssertTrue(motion.bounds.contains(particle.tail), "Tail outside bounds at step \(step) toward \(target)")
                }
            }
        }
    }

    func testRetargetedWindowIncludesBothOldAndNewFeatheredLandingAreas() {
        let card = CGRect(x: 500, y: 680, width: 140, height: 104)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let other = CGRect(x: -1280, y: 900, width: 1280, height: 800)
        let original = ParticleTransferMotion(card: card, destination: CGPoint(x: 1380, y: 150),
                                              sourceScreen: screen, destinationScreen: screen)
        let redirected = ParticleTransferMotion(card: card, destination: CGPoint(x: -1279, y: 901),
                                                sourceScreen: screen, destinationScreen: other)
        let window = original.bounds.union(redirected.bounds)
        XCTAssertTrue(window.contains(original.landing.bounds))
        XCTAssertTrue(window.contains(redirected.landing.bounds))
        XCTAssertGreaterThanOrEqual(redirected.landing.left, other.minX)
        XCTAssertLessThanOrEqual(redirected.landing.right, other.maxX)
        let after = redirected.frame(at: 0.8).landing.band(at: 0.65)
        XCTAssertTrue(window.contains(after.rect.insetBy(dx: -ParticleLineLanding.feather, dy: -4)),
                      "Retargeting must grow the window for the broad sheen, not just the caret point")
    }

    private func assertContained(_ inner: CGRect, in outer: CGRect,
                                 file: StaticString = #filePath, line: UInt = #line) {
        // A zero-width initial sheen is valid even though it has no filled area.
        XCTAssertGreaterThanOrEqual(inner.minX, outer.minX - 0.0001, file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxX, outer.maxX + 0.0001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(inner.minY, outer.minY - 0.0001, file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxY, outer.maxY + 0.0001, file: file, line: line)
    }
}

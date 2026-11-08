import AppKit
import SwiftUI
import XCTest
@testable import Notchline

final class ParticleScanTests: XCTestCase {
    @MainActor
    func testNativeColumnMaskOnlyExposesPixelsBehindTheScanner() throws {
        let card = ParticleScanCard(span: CGRect(x: 0, y: 0, width: 480, height: 16),
                                    card: CGRect(x: 0, y: 0, width: 140, height: 100))
        func alpha(at x: Int, progress: CGFloat) throws -> UInt8 {
            let renderer = ImageRenderer(content: ParticleGrainMask(progress: 1, seed: 17, scan: card,
                                                                    scanProgress: progress, depthScale: 1)
                .frame(width: 140, height: 100))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let context = try XCTUnwrap(CGContext(data: nil, width: 140, height: 100, bitsPerComponent: 8,
                                                  bytesPerRow: 560, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 140, height: 100))
            return try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)[50 * 560 + x * 4 + 3]
        }
        XCTAssertEqual(try alpha(at: 10, progress: 0), 0)
        XCTAssertEqual(try alpha(at: 10, progress: 0.30), 255)
        XCTAssertEqual(try alpha(at: 100, progress: 0.30), 0)
        XCTAssertEqual(try alpha(at: 100, progress: 1), 255)
    }

    func testClosedAndSettledEndpointsHaveNoScanningLight() {
        let scan = ParticleScanGeometry(span: CGRect(x: 40, y: 130, width: 640, height: 16))
        let closed = scan.frame(at: 0), open = scan.frame(at: 1)
        XCTAssertEqual(closed.leftX, 40)
        XCTAssertEqual(closed.rightX, 680)
        XCTAssertEqual(closed.beamOpacity, 0)
        XCTAssertEqual(closed.mergeOpacity, 0)
        XCTAssertEqual(closed.projection, 0)
        XCTAssertEqual(open.leftX, 360, accuracy: 0.0001)
        XCTAssertEqual(open.rightX, 360, accuracy: 0.0001)
        XCTAssertEqual(open.beamOpacity, 0)
        XCTAssertEqual(open.mergeOpacity, 0)
        XCTAssertEqual(open.projection, 1)
        for step in 0...100 {
            let x = 40 + CGFloat(step) * 6.4
            XCTAssertEqual(scan.coverage(at: x, progress: 0), 0)
            XCTAssertEqual(scan.coverage(at: x, progress: 1), 1)
        }
    }

    func testLightFrontsAndCoverageRemainMirrorSymmetric() {
        let span = CGRect(x: -540, y: 100, width: 710, height: 16)
        let scan = ParticleScanGeometry(span: span)
        for step in 0...100 {
            let p = CGFloat(step) / 100, frame = scan.frame(at: p)
            XCTAssertEqual(frame.leftX + frame.rightX, span.midX * 2, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(frame.leftX, frame.rightX)
            XCTAssertGreaterThanOrEqual(frame.leftX, span.minX)
            XCTAssertLessThanOrEqual(frame.rightX, span.maxX)
            for column in 0...20 {
                let distance = span.width * CGFloat(column) / 40
                XCTAssertEqual(scan.coverage(at: span.midX - distance, progress: p),
                               scan.coverage(at: span.midX + distance, progress: p), accuracy: 0.0001)
            }
        }
    }

    func testContentAheadOfTheLightStaysHiddenUntilTheCentralFusion() {
        let scan = ParticleScanGeometry(span: CGRect(x: 80, y: 130, width: 600, height: 16))
        for p: CGFloat in [0.10, 0.20, 0.35, 0.50, 0.65, 0.75] {
            let frame = scan.frame(at: p)
            for fraction: CGFloat in [0.05, 0.25, 0.50, 0.75, 0.95] {
                let x = frame.leftX + (frame.rightX - frame.leftX) * fraction
                XCTAssertEqual(scan.coverage(at: x, progress: p), 0, accuracy: 0.0001,
                               "An unvisited region must not materialize ahead of either scanner")
            }
        }
        XCTAssertGreaterThan(scan.coverage(at: 90, progress: 0.50), 0.9)
        XCTAssertGreaterThan(scan.coverage(at: 670, progress: 0.50), 0.9)
        XCTAssertEqual(scan.coverage(at: 380, progress: 0.78), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(scan.coverage(at: 380, progress: 0.84), 0)
        XCTAssertLessThan(scan.coverage(at: 380, progress: 0.84), 1)
        XCTAssertEqual(scan.coverage(at: 380, progress: 0.91), 1, accuracy: 0.0001,
                       "The exact center must finish without a permanent seam")
    }

    func testRevealIsMonotonicAndReversesWithoutCoverageGaps() {
        let scan = ParticleScanGeometry(span: CGRect(x: -240, y: 130, width: 480, height: 16))
        for column in 0...80 {
            let x = -240 + CGFloat(column) * 6
            var increasing: CGFloat = 0
            var forward: [CGFloat] = []
            for step in 0...200 {
                let p = CGFloat(step) / 200
                let coverage = scan.coverage(at: x, progress: p)
                XCTAssertGreaterThanOrEqual(coverage + 0.000001, increasing)
                XCTAssertGreaterThanOrEqual(coverage, 0)
                XCTAssertLessThanOrEqual(coverage, 1)
                increasing = coverage
                forward.append(coverage)
            }
            var decreasing: CGFloat = 1
            for step in stride(from: 200, through: 0, by: -1) {
                let coverage = scan.coverage(at: x, progress: CGFloat(step) / 200)
                XCTAssertLessThanOrEqual(coverage, decreasing + 0.000001)
                XCTAssertEqual(coverage, forward[step], accuracy: 0.000001)
                decreasing = coverage
            }
            XCTAssertEqual(decreasing, 0)
        }
    }

    func testNarrowAndEmptySpansStayFiniteAndComplete() {
        for origin: CGFloat in [-1800, -1, 0, 400] {
            for width: CGFloat in [0, 0.1, 1, 4, 12, 40] {
                let span = CGRect(x: origin, y: 0, width: width, height: 0)
                let scan = ParticleScanGeometry(span: span)
                for p: CGFloat in [-0.5, 0, 0.2, 0.5, 0.8, 1, 1.5, .nan] {
                    let frame = scan.frame(at: p)
                    XCTAssertTrue(frame.leftX.isFinite && frame.rightX.isFinite)
                    XCTAssertTrue(frame.beamOpacity.isFinite && frame.mergeOpacity.isFinite && frame.projection.isFinite)
                    let coverage = scan.coverage(at: span.midX, progress: p)
                    XCTAssertTrue(coverage.isFinite)
                    XCTAssertGreaterThanOrEqual(coverage, 0)
                    XCTAssertLessThanOrEqual(coverage, 1)
                }
                XCTAssertEqual(scan.coverage(at: span.midX, progress: 0), 0)
                XCTAssertEqual(scan.coverage(at: span.midX, progress: 1), 1)
            }
        }
        XCTAssertGreaterThanOrEqual(LineTheme.hologram.hideDuration, ParticleMotion.dismissDuration,
                                    "The panel must outlive the last frame of the closing scanner")
    }

    @MainActor
    func testNativeTargetsStayAtTheirShelfPositionsThroughoutTheScan() async throws {
        _ = NSApplication.shared
        let name = "ParticleScanTargets." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let pasteboard = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: folder)
        }
        let line = Line(defaults: defaults, pasteboard: pasteboard)
        line.soundOn = false; line.setTheme(.hologram); line.revealed = true
        for (filename, size) in [("wide.png", CGSize(width: 720, height: 180)),
                                 ("tall.png", CGSize(width: 180, height: 540))] {
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.systemTeal.setFill(); rect.fill(); return true
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let url = folder.appendingPathComponent(filename)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            XCTAssertNotNil(line.hang(url, quietly: true))
        }
        let note = folder.appendingPathComponent("idea.txt")
        try Data("Keep the target still while the light passes.".utf8).write(to: note)
        XCTAssertNotNil(line.hang(note, quietly: true))

        let host = NSHostingView(rootView: LineView(line: line, presentationProgress: 0))
        host.sizingOptions = []
        let panel = LinePanel(content: host)
        panel.alphaValue = 0
        panel.setFrame(CGRect(x: 120, y: 160, width: 840, height: Layout.panelHeight), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(line.hitRects.count, 3)
        let expected = line.cardRects(width: panel.frame.width)
        for p: CGFloat in [0, 0.5, 1, 0.5, 0] {
            host.rootView = LineView(line: line, presentationProgress: p)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(35))
            for (index, item) in line.items.enumerated() {
                let rect = try XCTUnwrap(line.hitRects[item.id])
                XCTAssertEqual(rect.minX, expected[index].minX, accuracy: 0.75)
                XCTAssertEqual(rect.minY, expected[index].minY, accuracy: 0.75)
                XCTAssertEqual(rect.width, expected[index].width, accuracy: 0.75)
                XCTAssertEqual(rect.height, expected[index].height, accuracy: 0.75)
                XCTAssertEqual(rect.maxY, Layout.particleBaseline, accuracy: 0.75)
            }
        }
    }
}

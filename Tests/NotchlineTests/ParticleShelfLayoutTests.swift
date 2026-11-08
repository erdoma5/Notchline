import AppKit
import SwiftUI
import XCTest
@testable import Notchline

final class ParticleShelfLayoutTests: XCTestCase {
    func testMixedCardsShareOneLowerEdgeAcrossWidthsAndPositions() {
        let sizes = [CGSize(width: 144, height: 42), CGSize(width: 34, height: 112),
                     CGSize(width: 136, height: 104)]
        for width: CGFloat in [320, 1000, 2000] {
            for center in [CGFloat(30), width / 2, width - 30] {
                for size in sizes {
                    for drop: CGFloat in [-12, 0, 18] {
                        let rect = Layout.cardRect(centerX: center, size: size, width: width,
                                                   theme: .hologram, drop: drop)
                        XCTAssertEqual(rect.maxY, Layout.particleBaseline, accuracy: 0.0001)
                        XCTAssertEqual(rect.midX, center, accuracy: 0.0001)
                        XCTAssertEqual(rect.size, size)
                    }
                }
            }
        }
    }

    func testClotheslineKeepsItsCurvedTopAndPullDisplacement() {
        let size = CGSize(width: 144, height: 104)
        // On a 2000pt display the original rope has 30pt of center sag.
        for (x, top): (CGFloat, CGFloat) in [(0, 14.5), (1000, 44.5), (2000, 14.5)] {
            for drop: CGFloat in [0, 17] {
                let rect = Layout.cardRect(centerX: x, size: size, width: 2000,
                                           theme: .clothesline, drop: drop)
                XCTAssertEqual(rect.minY, top + drop, accuracy: 0.0001)
                XCTAssertEqual(rect.midX, x, accuracy: 0.0001)
                XCTAssertEqual(rect.size, size)
            }
        }
    }

    func testShelfIncludesPartialNeighboursButIgnoresFullyOffscreenCards() {
        let baseline = Layout.particleBaseline
        let centered = CGRect(x: 430, y: baseline - 100, width: 140, height: 100)
        let farLeft = CGRect(x: -400, y: baseline - 100, width: 100, height: 100)
        let farRight = CGRect(x: 1200, y: baseline - 100, width: 100, height: 100)
        let shelf = Layout.particleShelfRect(cards: [farLeft, centered, farRight], width: 1000)
        XCTAssertEqual(shelf.minX, 408)
        XCTAssertEqual(shelf.maxX, 592)
        XCTAssertLessThan(shelf.minY, baseline)
        XCTAssertGreaterThan(shelf.maxY, baseline)

        let leftPeek = CGRect(x: -20, y: baseline - 100, width: 80, height: 100)
        let rightPeek = CGRect(x: 980, y: baseline - 100, width: 80, height: 100)
        let full = Layout.particleShelfRect(cards: [farLeft, leftPeek, centered, rightPeek, farRight], width: 1000)
        XCTAssertEqual(full.minX, 8)
        XCTAssertEqual(full.maxX, 992)
        let empty = Layout.particleShelfRect(cards: [], width: 1000)
        XCTAssertEqual(empty.midX, 500)
        XCTAssertGreaterThan(empty.width, 0)
    }

    func testDockingUsesTheLowerEdgeOnNegativeAndUpperDisplays() {
        let panels = [CGRect(x: -1600, y: 620, width: 1600, height: Layout.panelHeight),
                      CGRect(x: 280, y: 1800, width: 1000, height: Layout.panelHeight),
                      CGRect(x: -900, y: -1100, width: 900, height: Layout.panelHeight)]
        for panel in panels {
            let local = Layout.cardRect(centerX: panel.width / 2, size: CGSize(width: 140, height: 104),
                                        width: panel.width, theme: .hologram)
            let shelf = Layout.particleShelfRect(cards: [local], width: panel.width)
            let card = screenRect(local, in: panel)
            XCTAssertEqual(card.minY, panel.maxY - Layout.particleBaseline, accuracy: 0.0001)
            for dy: CGFloat in [-14, 0, 14] {
                XCTAssertTrue(Layout.touchesDock(card.offsetBy(dx: 0, dy: dy), in: panel,
                                                theme: .hologram, shelf: shelf))
            }
            for dy: CGFloat in [-15, 15] {
                XCTAssertFalse(Layout.touchesDock(card.offsetBy(dx: 0, dy: dy), in: panel,
                                                 theme: .hologram, shelf: shelf))
            }
            let leftOutside = CGRect(x: panel.minX + shelf.minX - card.width - 1, y: card.minY,
                                     width: card.width, height: card.height)
            let rightOutside = CGRect(x: panel.minX + shelf.maxX + 1, y: card.minY,
                                      width: card.width, height: card.height)
            XCTAssertFalse(Layout.touchesDock(leftOutside, in: panel, theme: .hologram, shelf: shelf))
            XCTAssertFalse(Layout.touchesDock(rightOutside, in: panel, theme: .hologram, shelf: shelf))
            XCTAssertTrue(Layout.touchesDock(leftOutside.offsetBy(dx: 2, dy: 0), in: panel,
                                            theme: .hologram, shelf: shelf))

            let ropeY = panel.maxY - Layout.ropeY(x: panel.width / 2, width: panel.width)
            let atOldRope = CGRect(x: card.minX, y: ropeY - 4, width: card.width, height: 8)
            XCTAssertTrue(Layout.touchesDock(atOldRope, in: panel, theme: .clothesline, shelf: shelf))
            XCTAssertFalse(Layout.touchesDock(atOldRope, in: panel, theme: .hologram, shelf: shelf),
                           "The old rope's invisible return band must not remain active")
        }
    }

    func testPullCanRemoveWhileTheUpperCardStillCrossesTheSlot() {
        let panel = CGRect(x: -1200, y: 800, width: 1000, height: Layout.panelHeight)
        let local = Layout.cardRect(centerX: 500, size: CGSize(width: 140, height: 104),
                                    width: panel.width, theme: .hologram)
        let shelf = Layout.particleShelfRect(cards: [local], width: panel.width)
        let original = screenRect(local, in: panel)
        let lowered = original.offsetBy(dx: 0, dy: -52)
        let slotPoint = CGPoint(x: lowered.midX, y: panel.maxY - Layout.particleBaseline)
        XCTAssertTrue(lowered.contains(slotPoint), "Its upper half still crosses the support")
        XCTAssertFalse(Layout.touchesDock(lowered, in: panel, theme: .hologram, shelf: shelf))
        var pull = LinePull(id: UUID(), anchor: 0.5)
        pull.track(down: 52, sideways: 0,
                   touchingRope: Layout.touchesDock(lowered, in: panel, theme: .hologram, shelf: shelf))
        XCTAssertTrue(pull.armed, "Removal should not require dragging past the card's entire height")
        pull.track(down: 8, sideways: 0,
                   touchingRope: Layout.touchesDock(original.offsetBy(dx: 0, dy: -8), in: panel,
                                                    theme: .hologram, shelf: shelf))
        XCTAssertFalse(pull.armed)
    }

    @MainActor
    func testNativeHitRectsMatchSharedGeometryForMixedCardsAndPressFeedback() async throws {
        _ = NSApplication.shared
        let name = "ParticleShelfLayout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let pb = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            pb.releaseGlobally()
            try? FileManager.default.removeItem(at: folder)
        }
        let line = Line(defaults: defaults, pasteboard: pb)
        line.soundOn = false; line.setTheme(.hologram); line.revealed = true
        for (filename, size) in [("landscape.png", CGSize(width: 720, height: 180)),
                                 ("portrait.png", CGSize(width: 160, height: 640))] {
            let url = folder.appendingPathComponent(filename)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.systemTeal.setFill(); rect.fill(); return true
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            XCTAssertNotNil(line.hang(url, quietly: true))
        }
        let text = folder.appendingPathComponent("note.txt")
        try Data("An idea with a place to rest.\nKeep the lower edge aligned.".utf8).write(to: text)
        XCTAssertNotNil(line.hang(text, quietly: true))

        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        let window = LinePanel(content: host)
        window.setFrame(CGRect(x: 100, y: 100, width: 860, height: Layout.panelHeight), display: false)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(2)
        while line.hitRects.count != 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(line.hitRects.count, 3)
        let shared = line.cardRects(width: window.frame.width)
        XCTAssertEqual(Set(shared.map { Int($0.height.rounded()) }).count, 3,
                       "The fixture must exercise genuinely different card heights")
        func assertGeometry() throws {
            for (index, item) in line.items.enumerated() {
                let actual = try XCTUnwrap(line.hitRects[item.id])
                let expected = shared[index]
                XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.75)
                XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.75)
                XCTAssertEqual(actual.width, expected.width, accuracy: 0.75)
                XCTAssertEqual(actual.height, expected.height, accuracy: 0.75)
                XCTAssertEqual(actual.maxY, Layout.particleBaseline, accuracy: 0.75)
            }
        }
        try assertGeometry()
        line.pressedID = line.items[0].id
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        try assertGeometry()
        line.pressedID = nil
    }

    private func screenRect(_ rect: CGRect, in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + rect.minX, y: panel.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }
}

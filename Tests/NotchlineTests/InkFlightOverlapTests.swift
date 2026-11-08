import AppKit
import XCTest
@testable import Notchline

final class InkFlightOverlapTests: XCTestCase {
    @MainActor
    func testRepeatedPastesShareTheFoldAndOtherClippingsKeepTheirOwnPaper() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Needs a desktop with motion enabled")
        }
        let area = screen.visibleFrame
        let source = LinePanel(content: NSView())
        source.alphaValue = 0
        source.setFrame(area, display: false)
        source.orderFrontRegardless()
        defer { source.orderOut(nil) }

        let flights = InkFlights()
        let thumb = try XCTUnwrap(TextNote("折纸", stock: .sky).thumbnail(scale: 1))
        let image = try XCTUnwrap(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var hidden = Set<UUID>()
        var departures: [UUID: Int] = [:]
        let ids = (0..<4).map { _ in UUID() }
        func active() -> [InkFlight] {
            NSApp.windows.compactMap { $0 as? InkFlight }.filter { $0.isVisible }
        }
        let left = CGPoint(x: area.minX + area.width * 0.20, y: area.midY)
        let right = CGPoint(x: area.maxX - area.width * 0.20, y: area.midY)
        func play(_ index: Int, to target: CGPoint) -> Bool {
            let id = ids[index]
            let card = CGRect(x: area.midX + CGFloat(index * 42) - 92, y: area.midY + 68, width: 40, height: 30)
            let started = flights.play(itemID: id, image: image, card: card, tilt: 1, to: target,
                                       speed: .fast, sourceWindow: source) {
                hidden.remove(id)
                departures[id, default: 0] += 1
            }
            if started { hidden.insert(id) }
            for panel in active() { panel.alphaValue = 0 }
            return started
        }
        func wait(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(12)) }
            XCTAssertTrue(condition())
        }

        XCTAssertTrue(play(0, to: right))
        let first = try XCTUnwrap(active().first)
        try await Task.sleep(for: .milliseconds(180))
        let paper = try XCTUnwrap(first.contentView?.layer?.sublayers?.first)
        paper.displayIfNeeded()
        XCTAssertNotNil(paper.contents, "The folding paper should already have a raster")
        XCTAssertTrue(play(0, to: left))
        XCTAssertEqual(active(), [first])
        XCTAssertNil(departures[ids[0]], "Changing direction should not end the ongoing fold")
        XCTAssertTrue(play(1, to: right))
        XCTAssertTrue(play(2, to: right))
        XCTAssertEqual(Set(active().compactMap(\.foldingID)), Set(ids.prefix(3)))
        XCTAssertFalse(play(3, to: left), "All three sheets are still on their pins")

        try await wait { !hidden.contains(ids[0]) }
        XCTAssertTrue(first.isVisible, "The original fold launched even after a second paste")
        XCTAssertGreaterThan(first.frame.midX, area.midX - 72, "Kept the nose direction of the original fold")
        XCTAssertTrue(play(3, to: left), "The fourth clipping can now reuse the airborne window")
        XCTAssertEqual(active().count, 3)
        try await wait { !flights.isVisible }
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(departures, Dictionary(uniqueKeysWithValues: ids.map { ($0, 1) }))
    }
}

import SwiftUI
import XCTest
@testable import Notchline

final class LineInteractionTests: XCTestCase {
    func testOverflowRevealsPartOfTheNextActualCardAtEitherEnd() {
        let width: CGFloat = 1280
        let count = 11, visible = 5
        func bounds(_ index: Int, _ cardWidth: CGFloat, scroll: CGFloat) -> ClosedRange<CGFloat> {
            let x = Layout.x(index: index, count: count, width: width, visible: visible,
                             scroll: scroll, itemWidth: cardWidth)
            return (x - cardWidth / 2)...(x + cardWidth / 2)
        }
        let end = CGFloat(count - visible) * Layout.spacing
        for cardWidth: CGFloat in [20, 144] {
            let older = bounds(count - visible - 1, cardWidth, scroll: 0)
            XCTAssertLessThan(older.lowerBound, 0)
            XCTAssertGreaterThan(older.upperBound, 0)
            XCTAssertLessThan(bounds(count - 1, cardWidth, scroll: 0).upperBound, width)
            let newer = bounds(visible, cardWidth, scroll: end)
            XCTAssertLessThan(newer.lowerBound, width)
            XCTAssertGreaterThan(newer.upperBound, width)
            XCTAssertGreaterThan(bounds(0, cardWidth, scroll: end).lowerBound, 0)
            XCTAssertGreaterThan(bounds(count - visible - 1, cardWidth, scroll: Layout.spacing).lowerBound, 0)
        }
    }

    func testPhotoKeepsItsGripOutsideTheLineWhileTheRopeUnloads() {
        let grab = PhotoGrab(card: CGRect(x: 140, y: 800, width: 140, height: 100),
                             pointer: CGPoint(x: 153, y: 825))
        let acrossDisplays = CGPoint(x: -690, y: 310)
        let frame = grab.frame(at: acrossDisplays)
        XCTAssertEqual(acrossDisplays.x - frame.minX, 13)
        XCTAssertEqual(acrossDisplays.y - frame.minY, 25)

        var pull = LinePull(id: UUID(), anchor: 0.3)
        pull.track(down: 20, sideways: 0, touchingRope: false)
        XCTAssertFalse(pull.armed)
        XCTAssertGreaterThan(pull.depth, 0)
        XCTAssertEqual(pull.offset(at: 300, width: 1000), pull.depth, accuracy: 0.001)
        XCTAssertEqual(pull.offset(at: 0, width: 1000), 0)
        XCTAssertEqual(pull.offset(at: 1000, width: 1000), 0)
        pull.track(down: 65, sideways: 0, touchingRope: false)
        XCTAssertTrue(pull.armed)
        XCTAssertEqual(pull.depth, 0)
        pull.track(down: -15, sideways: 700, touchingRope: false)
        XCTAssertTrue(pull.armed, "A drag outside both the peg and the rope is still a removal")
        pull.track(down: 10, sideways: 3, touchingRope: false)
        XCTAssertFalse(pull.armed)
    }

    func testCardEdgeCanCatchTheCurvedRopeOnAnOffsetDisplay() {
        let panel = CGRect(x: -1800, y: 620, width: 1600, height: 210)
        let lowPoint = panel.maxY - Layout.ropeY(x: 800, width: panel.width)
        // Only the crown of the card enters the band around the low point.
        let card = CGRect(x: panel.midX - 150, y: lowPoint - 109, width: 300, height: 96)
        XCTAssertTrue(Layout.touchesRope(card, in: panel))
        XCTAssertFalse(Layout.touchesRope(card.offsetBy(dx: 0, dy: -8), in: panel))
        // Near the left end, only the right edge of this photo reaches the rope.
        let edge = CGRect(x: panel.minX - 90, y: panel.maxY - 13, width: 96, height: 70)
        XCTAssertTrue(Layout.touchesRope(edge, in: panel))
        XCTAssertFalse(Layout.touchesRope(edge.offsetBy(dx: -10, dy: 0), in: panel))
        XCTAssertFalse(Layout.touchesRope(edge.offsetBy(dx: 0, dy: 30), in: panel))
    }

    @MainActor
    func testClickPullCancelAndPutBack() async throws {
        _ = NSApplication.shared
        let suite = "NotchlineTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let pb = NSPasteboard.withUniqueName()
        let line = Line(defaults: defaults, pasteboard: pb)
        line.soundOn = false
        line.revealed = true

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".png")
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            defaults.removePersistentDomain(forName: suite)
            pb.releaseGlobally()
        }
        let id = try XCTUnwrap(line.hang(url, quietly: true))
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: Layout.panelHeight),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func findCard(in view: NSView) -> GrabView? {
            if let card = view as? GrabView { return card }
            return view.subviews.lazy.compactMap { findCard(in: $0) }.first
        }
        let card = try XCTUnwrap(findCard(in: host))
        func waitForCopy(after previous: UUID? = nil) async throws {
            for _ in 0..<100 {
                if line.feedback?.kind == .copied, line.feedback?.id != previous { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("The image was not copied within two seconds")
        }
        // Event coordinates below are relative to the former corner button.
        let topLeft = card.convert(NSPoint(x: card.bounds.minX,
                                           y: card.isFlipped ? card.bounds.minY : card.bounds.maxY), to: nil)
        func event(_ type: NSEvent.EventType, x: CGFloat = 5, y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: topLeft.x + x, y: topLeft.y + y - 90), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 0))
        }

        // A click where the old discard button was must actually copy.
        card.mouseDown(with: try event(.leftMouseDown, y: 85))
        card.mouseUp(with: try event(.leftMouseUp, y: 85))
        XCTAssertTrue(line.awaitingSingleClick)
        try await waitForCopy()
        XCTAssertEqual(pb.data(forType: .png), png)
        XCTAssertEqual(line.feedback?.kind, .copied)
        // Repeating a copy of the same photo starts a fresh confirmation.
        let firstNotice = line.feedback?.id
        try await Task.sleep(for: .seconds(0.75))
        line.copy(id)
        try await waitForCopy(after: firstNotice)
        XCTAssertNotEqual(line.feedback?.id, firstNotice)
        try await Task.sleep(for: .seconds(0.7))
        XCTAssertEqual(line.feedback?.kind, .copied)
        let originalCount = pb.changeCount

        // Sideways, a short pull, and an armed pull eased back up all cancel.
        for (dx, lowest, releaseY) in [(70, 78, 78), (5, 55, 55), (5, 10, 58)] {
            card.mouseDown(with: try event(.leftMouseDown, y: 85))
            card.mouseDragged(with: try event(.leftMouseDragged, x: CGFloat(dx), y: CGFloat(lowest)))
            card.mouseUp(with: try event(.leftMouseUp, x: CGFloat(dx), y: CGFloat(releaseY)))
            XCTAssertEqual(line.liveCount, 1)
            XCTAssertFalse(line.awaitingSingleClick)
            XCTAssertFalse(line.canPutBack)
            XCTAssertNil(line.pull.id)
        }

        // Release at the far side of the line. The pointer remains below
        // the rope; only the top edge of the dragged photo touches it.
        let center = card.convert(CGPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
        let start = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: center,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        card.mouseDown(with: start)
        let away = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged,
            location: CGPoint(x: center.x, y: center.y - 150), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        card.mouseDragged(with: away)
        XCTAssertTrue(line.pull.armed)
        let targetX = window.frame.width - 90
        let rope = window.frame.height - Layout.ropeY(x: targetX, width: window.frame.width)
        let target = CGPoint(x: targetX, y: rope - card.bounds.height / 2)
        let release = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: target,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        card.mouseUp(with: release)
        XCTAssertEqual(line.liveCount, 1)
        XCTAssertFalse(line.canPutBack)
        XCTAssertNil(line.loosePhoto)

        // End outside the card. The last item still has a confirmation, and
        // the original image remains at the URL promised to the clipboard.
        card.mouseDown(with: try event(.leftMouseDown, y: 85))
        card.mouseDragged(with: try event(.leftMouseDragged, y: 12))
        let panel = try XCTUnwrap(line.loosePhoto)
        let near = panel.frame.origin
        card.mouseDragged(with: try event(.leftMouseDragged, x: 265, y: -378))
        XCTAssertEqual(panel.frame.minX - near.x, 260, accuracy: 1)
        XCTAssertEqual(panel.frame.minY - near.y, -390, accuracy: 1)
        XCTAssertTrue(panel.ignoresMouseEvents)
        card.mouseUp(with: try event(.leftMouseUp, x: 285, y: -390))
        XCTAssertEqual(panel.frame.minX - near.x, 280, accuracy: 1)
        XCTAssertEqual(panel.frame.minY - near.y, -402, accuracy: 1)
        XCTAssertNil(line.loosePhoto)
        XCTAssertEqual(line.liveCount, 0)
        guard case .removed? = line.feedback?.kind else { return XCTFail("Missing removal feedback") }
        XCTAssertEqual(try Data(contentsOf: url), png)
        XCTAssertEqual(pb.changeCount, originalCount)
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), [])
        line.putBack()
        XCTAssertNil(line.feedback)
        XCTAssertEqual(line.items.filter { !$0.falling }.map(\.url), [url])
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), [url.path])

        // A file that vanished between the click and the delayed copy must
        // neither replace the clipboard nor report a successful copy.
        try FileManager.default.removeItem(at: url)
        line.copy(try XCTUnwrap(line.items.first?.id))
        XCTAssertNil(line.feedback)
        XCTAssertEqual(pb.changeCount, originalCount)
    }
}

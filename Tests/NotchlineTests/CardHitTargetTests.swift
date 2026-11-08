import SwiftUI
import XCTest
@testable import Notchline

final class CardHitTargetTests: XCTestCase {
    @MainActor
    func testPhotoAndPaperRouteLeftCenterAndRightClicksThroughTheSameStableTarget() throws {
        _ = NSApplication.shared
        let suite = "CardHitTarget." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let line = Line(defaults: defaults, pasteboard: NSPasteboard(name: .init(suite)))
        let photo = NSImage(size: NSSize(width: 800, height: 500), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let items = [
            Pegged(url: URL(fileURLWithPath: "/tmp/unused-clipping.txt"),
                   thumb: try XCTUnwrap(TextNote("Same clipping").thumbnail(scale: 1))),
            Pegged(url: URL(fileURLWithPath: "/tmp/unused-photo.png"), thumb: photo)
        ]
        func findGrab(_ view: NSView) -> GrabView? {
            if let grab = view as? GrabView { return grab }
            return view.subviews.lazy.compactMap(findGrab).first
        }
        for theme in LineTheme.allCases {
          line.setTheme(theme)
          for item in items {
            var offsets: [CGFloat] = []
            func scene(angle: Double) -> some View {
                PeggedView(item: item, line: line, ropeDrop: 4, tapAngle: angle,
                           tapHighlight: 0) { offsets.append($0) }
                    .frame(width: 320, height: 280)
            }
            let host = NSHostingView(rootView: scene(angle: 0))
            host.sizingOptions = []
            let panel = LinePanel(content: host)
            panel.setContentSize(NSSize(width: 320, height: 280))
            host.layoutSubtreeIfNeeded()
            let grab = try XCTUnwrap(findGrab(host))
            let parent = try XCTUnwrap(host.superview)
            for (index, fraction) in [CGFloat(0.1), 0.5, 0.9].enumerated() {
                let local = CGPoint(x: grab.bounds.width * fraction, y: grab.bounds.midY)
                let pointer = grab.convert(local, to: parent)
                // A preceding left/right tap moves the artwork, but the next
                // press at the same physical point must still reach GrabView.
                host.rootView = scene(angle: 4.5 * Double(fraction * 2 - 1))
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(host.hitTest(pointer) === grab)
                let point = grab.convert(local, to: nil)
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                    location: point, modifierFlags: [], timestamp: Double(index * 2 + 1),
                    windowNumber: panel.windowNumber, context: nil, eventNumber: index,
                    clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp,
                    location: point, modifierFlags: [], timestamp: down.timestamp + 0.05,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: index,
                    clickCount: 1, pressure: 0))
                grab.mouseDown(with: down)
                grab.mouseUp(with: up)
            }
            XCTAssertEqual(offsets.count, 3)
            for (actual, expected) in zip(offsets, [CGFloat(-0.8), 0, 0.8]) {
                XCTAssertEqual(actual, expected, accuracy: 0.001)
            }
            line.cancelScheduledCopy()
            withExtendedLifetime(panel) {}
          }
        }
    }

    @MainActor
    func testStationaryPointerAtEdgeStillHitsTheCardAtThePeakOfTheTapWave() throws {
        _ = NSApplication.shared
        let suite = "CardHitTarget." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let line = Line(defaults: defaults)
        let note = TextNote("Same clipping")
        let item = Pegged(url: URL(fileURLWithPath: "/tmp/unused-clipping.txt"),
                          thumb: try XCTUnwrap(note.thumbnail(scale: 1)))
        let size = CGSize(width: 320, height: 280)
        func scene(drop: CGFloat) -> some View {
            PeggedView(item: item, line: line, ropeDrop: drop, tapAngle: Double(drop), tapHighlight: 0) { _ in }
                .frame(width: size.width, height: size.height)
        }

        let host = NSHostingView(rootView: scene(drop: 0))
        host.sizingOptions = []
        let panel = LinePanel(content: host)
        panel.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        func findGrab(_ view: NSView) -> GrabView? {
            if let hit = view as? GrabView { return hit }
            return view.subviews.lazy.compactMap(findGrab).first
        }
        let grab = try XCTUnwrap(findGrab(host))
        // This is inside the top edge, away from the wooden peg. Moving the
        // hit target by the four-point visual recoil would lose a second press.
        let pointer = grab.convert(CGPoint(x: grab.bounds.width * 0.25,
            y: grab.isFlipped ? 1 : grab.bounds.height - 1), to: try XCTUnwrap(host.superview))
        XCTAssertTrue(host.hitTest(pointer) === grab)
        host.rootView = scene(drop: 4)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.hitTest(pointer) === grab, "The same stationary click should still hit the clipping")
        withExtendedLifetime(panel) {}
    }
}

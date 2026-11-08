import AppKit
import XCTest
@testable import Notchline

final class LinePointerRoutingTests: XCTestCase {
    @MainActor
    func testOnlyRecordedExternalMenuBarClicksHideTheLine() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let band = AppDelegate.menuBarBand(of: screen)
        let window = LinePanel(content: NSView())
        func externalClick(at point: CGPoint) throws -> NSEvent {
            let quartzPoint = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
            let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                           mouseCursorPosition: quartzPoint, mouseButton: .left))
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        let above = CGPoint(x: band.midX, y: band.midY)
        let below = CGPoint(x: band.midX, y: band.minY - 40)
        XCTAssertTrue(AppDelegate.isMenuBarClick(try externalClick(at: above), linePanel: window))
        XCTAssertFalse(AppDelegate.isMenuBarClick(try externalClick(at: below), linePanel: window))

        window.setFrame(band, display: false)
        let ownEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: window.convertPoint(fromScreen: above), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        XCTAssertFalse(AppDelegate.isMenuBarClick(ownEvent, linePanel: window))
    }
}

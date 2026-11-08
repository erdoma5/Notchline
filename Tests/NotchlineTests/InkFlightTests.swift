import AppKit
import XCTest
@testable import Notchline

final class InkFlightTests: XCTestCase {
    func testGliderStaysOnThePinThroughTheFoldAndPauseAtEverySpeed() {
        let start = CGPoint(x: 300, y: 800)
        for speed in [InkSpeed.fast, .medium, .slow] {
            let motion = InkFlightMotion(start: start, end: CGPoint(x: 720, y: 290), tilt: 2, speed: speed)
            let timing = speed.timing
            XCTAssertGreaterThanOrEqual(timing.fold, 0.55)
            XCTAssertGreaterThanOrEqual(timing.hold, 0.08)
            let halfway = motion.state(at: timing.fold / 2 / speed.duration)
            XCTAssertEqual(halfway.center, start)
            XCTAssertEqual(halfway.fold, 0.5, accuracy: 0.001)
            let held = motion.state(at: (timing.fold + timing.hold / 2) / speed.duration)
            XCTAssertEqual(held.center, start)
            XCTAssertEqual(held.fold, 1)
            XCTAssertEqual(held.opacity, 1)
            XCTAssertFalse(held.sourceReleased)
        }
    }

    func testGliderLeavesAndArrivesLevelWithRoomToTurnAtTheScreenEdge() {
        let screen = CGRect(x: -1200, y: 80, width: 1200, height: 800)
        let start = CGPoint(x: -60, y: 824)
        for end in [CGPoint(x: -580, y: 380), CGPoint(x: -60, y: 270),
                    CGPoint(x: -40, y: 810), start] {
            let motion = InkFlightMotion(start: start, end: end, tilt: -2, sourceScreen: screen)
            let timing = motion.speed.timing
            func glide(_ t: Double) -> InkFlightMotion.State {
                motion.state(at: (timing.fold + timing.hold + t * timing.glide) / motion.speed.duration)
            }
            let launch = glide(0.10).center, approach = glide(0.90).center
            XCTAssertLessThanOrEqual(abs(launch.y - start.y), abs(launch.x - start.x) * 0.40 + 0.1)
            XCTAssertLessThanOrEqual(abs(approach.y - end.y), abs(approach.x - end.x) * 0.40 + 0.1)
            XCTAssertEqual(glide(0.5).opacity, 1)
            XCTAssertTrue(glide(0.6).sourceReleased)
            XCTAssertEqual(glide(1).center.x, end.x, accuracy: 0.001)
            XCTAssertEqual(glide(1).center.y, end.y, accuracy: 0.001)
            XCTAssertEqual(glide(1).opacity, 0, accuracy: 0.001)
            for step in 0...40 {
                let frame = glide(Double(step) / 40)
                XCTAssertTrue(screen.contains(frame.center))
                XCTAssertTrue(frame.angle.isFinite)
            }
            if end.x == start.x && end != start {
                XCTAssertTrue(motion.pointsLeft, "Near the right edge there is room to turn on the left")
                XCTAssertLessThan(glide(0.5).center.x, start.x - 60)
            }
        }
    }

    func testLandingOnOffsetDisplaysAndFallbackToVisibleField() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1280, y: 900, width: 1280, height: 800)]
        var target = InkLanding(caret: CGRect(x: -870, y: -320, width: 0, height: 20),
                                field: CGRect(x: -1100, y: -400, width: 400, height: 180),
                                window: CGRect(x: -1200, y: -480, width: 800, height: 500))
        XCTAssertEqual(target.point(on: screens), CGPoint(x: -870, y: 1210))
        target.caret = CGRect(x: 100, y: 100, width: 1, height: 20) // outside its editor
        XCTAssertEqual(target.point(on: screens), CGPoint(x: -900, y: 1210))
        target.caret = CGRect(x: -870, y: -330, width: 0, height: 0)
        XCTAssertEqual(target.point(on: screens), CGPoint(x: -870, y: 1230))
        target.caret = CGRect(x: -870, y: -330, width: 2, height: 0)
        XCTAssertEqual(target.point(on: screens), CGPoint(x: -900, y: 1210))
        target.field = CGRect(x: -2000, y: -500, width: 100, height: 50)
        XCTAssertNil(target.point(on: screens))
        target.caret = nil
        target.field = nil
        XCTAssertNil(target.point(on: screens))
    }

    func testLandingCanUseVerifiedFieldOrCaretWithNoWindowFrame() {
        let screens = [CGRect(x: 0, y: 0, width: 900, height: 600),
                       CGRect(x: 0, y: 600, width: 900, height: 400)]
        let field = CGRect(x: 150, y: 200, width: 300, height: 80)
        let caret = CGRect(x: 200, y: 225, width: 1, height: 20)
        var target = InkLanding(caret: caret, field: field, window: nil)
        XCTAssertEqual(target.point(on: screens), CGPoint(x: 200.5, y: 365))
        target.caret = nil
        XCTAssertEqual(target.point(on: screens), CGPoint(x: 300, y: 360))
        target.field = nil
        target.caret = caret
        XCTAssertEqual(target.point(on: screens), CGPoint(x: 200.5, y: 365))
        target.caret = .zero // The primary desktop corner is on the upper display.
        target.window = CGRect(x: -30, y: -20, width: 160, height: 70)
        XCTAssertNil(target.point(on: screens))
        target.caret = CGRect(x: 100, y: 90, width: 0, height: 20) // outside this known window
        XCTAssertNil(target.point(on: screens))
    }

    @MainActor
    func testPasteDoesNotWaitForInkAndSlowOrMissingGeometryUsesCue() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { throw XCTSkip("Reduce Motion is enabled") }
        let suite = "InkFlightTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let pb = NSPasteboard.withUniqueName()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".txt")
        defer {
            pb.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        let sample = "在灯塔下见。"
        try Data(sample.utf8).write(to: url)
        var sent = 0, flights = 0
        var lookup: CheckedContinuation<CGPoint?, Never>?
        let line = Line(defaults: defaults, pasteboard: pb, pasteDestination: {
            .target(locateFlight: {
                await withCheckedContinuation { lookup = $0 }
            }, sendPaste: { isCurrent in
                XCTAssertTrue(isCurrent())
                XCTAssertEqual(pb.string(forType: .string), sample)
                sent += 1
                return true
            })
        })
        let id = try XCTUnwrap(line.hang(url, quietly: true))
        line.onPasteFlight = { item, point in
            XCTAssertEqual(item.id, id)
            XCTAssertEqual(point, CGPoint(x: 400, y: 120))
            flights += 1
            return true
        }
        func doubleClick() throws {
            line.scheduleCopy(id)
            try XCTUnwrap(line.beginDoubleClick(id))()
        }
        func takeLookup() async throws -> CheckedContinuation<CGPoint?, Never> {
            for _ in 0..<30 where lookup == nil { await Task.yield() }
            let pending = try XCTUnwrap(lookup)
            lookup = nil
            return pending
        }
        for n in 1...4 {
            try doubleClick()
            XCTAssertEqual(sent, n, "Paste was dispatched before any geometry could be returned")
            let pending = try await takeLookup()
            if n == 3 {
                // The original paste has committed. A still-valid response
                // from a busy editor may arrive during the next first click.
                try await Task.sleep(for: .milliseconds(210))
                line.scheduleCopy(id)
            }
            if n == 4 { try await Task.sleep(for: .milliseconds(510)) }
            pending.resume(returning: n == 2 ? nil : CGPoint(x: 400, y: 120))
            try await Task.sleep(for: .milliseconds(15))
            if n == 3 { line.cancelScheduledCopy() }
            XCTAssertEqual(flights, 1, "A new copy supersedes the previous paste flight")
            XCTAssertEqual(line.feedback?.kind, n == 3 ? .copied : .pasteRequested)
            XCTAssertEqual(line.feedback?.showsCue, n == 2 || n == 3 || n == 4)
        }
        try doubleClick()
        let older = try await takeLookup()
        try doubleClick()
        let newer = try await takeLookup()
        older.resume(returning: CGPoint(x: 99, y: 99))
        newer.resume(returning: CGPoint(x: 400, y: 120))
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(sent, 6)
        XCTAssertEqual(flights, 2, "A newer committed paste supersedes a pending older animation")
    }
}

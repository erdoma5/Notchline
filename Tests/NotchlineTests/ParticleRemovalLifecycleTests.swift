import AppKit
import XCTest
@testable import Notchline

final class ParticleRemovalLifecycleTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let name: String
        let defaults: UserDefaults
        let pasteboard: NSPasteboard
        let url: URL
        let line: Line
        let id: UUID
        let frame: CGRect
        let grab: PhotoGrab

        init(theme: LineTheme = .hologram) throws {
            _ = NSApplication.shared
            name = "ParticleRemovalLifecycle." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            pasteboard = .withUniqueName()
            url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".txt")
            try Data("Keep the original after evaporation".utf8).write(to: url)
            line = Line(defaults: defaults, pasteboard: pasteboard)
            line.soundOn = false
            line.setTheme(theme)
            line.revealed = true
            id = try XCTUnwrap(line.hang(url, quietly: true))
            frame = CGRect(x: 0, y: 600, width: 1000, height: Layout.panelHeight)
            let card = CGRect(x: 430, y: frame.maxY - Layout.particleBaseline, width: 140, height: 105)
            grab = PhotoGrab(card: card, pointer: CGPoint(x: card.midX, y: card.midY))
        }

        func drag(down: CGFloat) {
            line.trackPull(id, from: grab,
                to: CGPoint(x: grab.pointer.x, y: grab.pointer.y - down), in: frame)
        }

        func cleanUp() {
            if let id = line.pull.id { line.releasePull(id, cancelled: true) }
            defaults.removePersistentDomain(forName: name)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: url)
        }
    }

    @MainActor
    private func waitUntilHidden(_ panel: LoosePhotoPanel) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while panel.isVisible && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(panel.isVisible, "A completed gesture must release its overlay window")
        XCTAssertFalse(panel.isAnimating, "No timer should survive a completed gesture")
    }

    @MainActor
    func testPendingCueReversesWithActualDockingDecision() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.drag(down: 180)
        let panel = try XCTUnwrap(fixture.line.loosePhoto)
        defer { panel.orderOut(nil) }
        XCTAssertTrue(fixture.line.pull.armed)
        XCTAssertEqual(panel.removalArmed, fixture.line.pull.armed)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(panel.removalReadiness, 1, accuracy: 0.01)
        XCTAssertEqual(fixture.line.liveCount, 1, "Pending removal must not delete content")

        fixture.drag(down: 0)
        XCTAssertFalse(fixture.line.pull.armed)
        XCTAssertEqual(panel.removalArmed, fixture.line.pull.armed)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(panel.removalReadiness, 0, accuracy: 0.01)
        fixture.line.releasePull(fixture.id, cancelled: false)
        XCTAssertNil(fixture.line.loosePhoto)
        XCTAssertEqual(fixture.line.liveCount, 1)
        XCTAssertFalse(fixture.line.canPutBack)
        try await waitUntilHidden(panel)
    }

    @MainActor
    func testReleaseEvaporatesThenCleansUpAndUndoPreservesTheOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.line.copy(fixture.id)
        let clipboardBefore = fixture.pasteboard.changeCount
        fixture.drag(down: 180)
        let panel = try XCTUnwrap(fixture.line.loosePhoto)
        defer { panel.orderOut(nil) }
        fixture.line.releasePull(fixture.id, cancelled: false)
        XCTAssertNil(fixture.line.loosePhoto)
        XCTAssertNil(fixture.line.pull.id)
        XCTAssertEqual(fixture.line.liveCount, 0)
        XCTAssertTrue(fixture.line.canPutBack)
        XCTAssertEqual(try String(contentsOf: fixture.url), "Keep the original after evaporation")
        XCTAssertEqual(fixture.pasteboard.changeCount, clipboardBefore)
        try await waitUntilHidden(panel)

        fixture.line.putBack()
        XCTAssertEqual(fixture.line.liveCount, 1)
        XCTAssertEqual(fixture.line.items.first(where: { !$0.falling })?.url, fixture.url)
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "pegged"), [fixture.url.path])
        XCTAssertEqual(fixture.line.theme, .hologram)
    }

    @MainActor
    func testThemeSwitchCancelsArmedRemovalAndEndsItsTimer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.drag(down: 180)
        let panel = try XCTUnwrap(fixture.line.loosePhoto)
        defer { panel.orderOut(nil) }
        fixture.line.setTheme(.clothesline)
        XCTAssertNil(fixture.line.pull.id)
        XCTAssertNil(fixture.line.loosePhoto)
        XCTAssertEqual(fixture.line.liveCount, 1)
        XCTAssertFalse(fixture.line.canPutBack)
        XCTAssertFalse(panel.removalArmed)
        try await waitUntilHidden(panel)
    }

    @MainActor
    func testHiddenShelfCancellationStopsImmediatelyAndDoesNotRemove() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.drag(down: 180)
        let panel = try XCTUnwrap(fixture.line.loosePhoto)
        fixture.line.revealed = false
        fixture.line.releasePull(fixture.id, cancelled: true)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isAnimating)
        XCTAssertNil(fixture.line.loosePhoto)
        XCTAssertEqual(fixture.line.liveCount, 1)
        XCTAssertFalse(fixture.line.canPutBack)
    }
}

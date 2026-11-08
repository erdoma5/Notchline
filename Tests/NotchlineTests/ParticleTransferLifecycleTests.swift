import AppKit
import XCTest
@testable import Notchline

final class ParticleTransferLifecycleTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let flights = InkFlights()
        let source: LinePanel
        let image: CGImage
        let area: CGRect
        let ids = (0..<4).map { _ in UUID() }
        let previous: Set<ObjectIdentifier>
        var hidden = Set<UUID>()
        var departures: [UUID: Int] = [:]

        init() throws {
            _ = NSApplication.shared
            guard let screen = NSScreen.main, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                throw XCTSkip("Needs a desktop with motion enabled")
            }
            previous = Set(NSApp.windows.compactMap { $0 as? InkFlight }.map(ObjectIdentifier.init))
            area = screen.visibleFrame
            let thumb = try XCTUnwrap(TextNote("把一个好点子传过去", stock: .mint).thumbnail(scale: 1))
            image = try XCTUnwrap(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
            source = LinePanel(content: NSView())
            source.alphaValue = 0
            source.setFrame(area, display: false)
            source.orderFrontRegardless()
        }

        var left: CGPoint { CGPoint(x: area.minX + area.width * 0.20, y: area.midY - 80) }
        var right: CGPoint { CGPoint(x: area.maxX - area.width * 0.20, y: area.midY - 80) }

        func panels() -> [InkFlight] {
            NSApp.windows.compactMap { $0 as? InkFlight }
                .filter { !previous.contains(ObjectIdentifier($0)) }
        }

        @discardableResult
        func play(_ index: Int, to target: CGPoint? = nil, theme: LineTheme = .hologram) -> Bool {
            let id = ids[index]
            let card = CGRect(x: area.midX + CGFloat(index * 42) - 92,
                              y: area.midY + 68, width: 64, height: 46)
            let started = flights.play(itemID: id, image: image, card: card, tilt: 0,
                                       to: target ?? right, speed: .fast, sourceWindow: source, theme: theme) {
                self.hidden.remove(id)
                self.departures[id, default: 0] += 1
            }
            if started { hidden.insert(id) }
            // Native windows and timers are exercised without covering the user's desktop.
            for panel in panels() { panel.alphaValue = 0 }
            return started
        }

        func finish() {
            flights.cancelAll()
            source.orderOut(nil)
        }
    }

    @MainActor
    private func wait(until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(12))
        }
        XCTAssertTrue(condition(), "Particle transfer did not reach its expected lifecycle state", file: file, line: line)
    }

    @MainActor
    func testEarlyParticleRetargetKeepsOneWindowAndRestoresTheSourceOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        XCTAssertTrue(fixture.play(0))
        let first = try XCTUnwrap(fixture.panels().first)
        XCTAssertEqual(fixture.hidden, [fixture.ids[0]], "play must not restore the source synchronously")
        XCTAssertNil(fixture.departures[fixture.ids[0]])
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(fixture.play(0, to: fixture.left))
        XCTAssertEqual(fixture.panels(), [first])
        XCTAssertEqual(first.foldingID, fixture.ids[0])
        XCTAssertNil(fixture.departures[fixture.ids[0]], "Retargeting must not restart or end the source phase")
        XCTAssertTrue(first.frame.insetBy(dx: -1, dy: -1).contains(fixture.left),
                      "The fixed transfer window must cover the new destination after retargeting")

        try await wait { !fixture.hidden.contains(fixture.ids[0]) }
        XCTAssertTrue(first.isVisible, "The original returns while the particle stream is still traveling")
        XCTAssertTrue(first.isPlaying)
        XCTAssertNil(first.foldingID)
        XCTAssertEqual(fixture.departures[fixture.ids[0]], 1)
        try await wait { !fixture.flights.isVisible }
        XCTAssertFalse(first.isPlaying)
        XCTAssertEqual(fixture.departures[fixture.ids[0]], 1)
    }

    @MainActor
    func testParticlePoolCapsAtThreeAndReusesAnAirborneWindowWithoutLosingSources() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        for index in 0..<3 { XCTAssertTrue(fixture.play(index)) }
        XCTAssertEqual(fixture.panels().count, 3)
        XCTAssertEqual(fixture.hidden, Set(fixture.ids.prefix(3)))
        XCTAssertEqual(Set(fixture.panels().compactMap(\.foldingID)), Set(fixture.ids.prefix(3)))
        XCTAssertFalse(fixture.play(3), "Three sources are still materializing, so none can be replaced yet")

        try await wait { !fixture.hidden.contains(fixture.ids[0]) }
        XCTAssertTrue(fixture.flights.isVisible)
        XCTAssertTrue(fixture.play(3), "An already-released stream can be reused by the next copy")
        XCTAssertEqual(fixture.panels().count, 3)
        try await wait { !fixture.flights.isVisible }
        XCTAssertTrue(fixture.hidden.isEmpty)
        XCTAssertTrue(fixture.panels().allSatisfy { !$0.isPlaying })
        XCTAssertEqual(fixture.departures, Dictionary(uniqueKeysWithValues: fixture.ids.map { ($0, 1) }))
    }

    @MainActor
    func testCancelAllStopsTimersRestoresSourcesAndAllowsClotheslineReuse() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        XCTAssertTrue(fixture.play(0))
        let first = try XCTUnwrap(fixture.panels().first)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.hidden.contains(fixture.ids[0]))
        fixture.flights.cancelAll()
        XCTAssertTrue(fixture.hidden.isEmpty)
        XCTAssertFalse(fixture.flights.isVisible)
        XCTAssertTrue(fixture.panels().allSatisfy { !$0.isPlaying })
        XCTAssertEqual(fixture.departures[fixture.ids[0]], 1)
        fixture.flights.cancelAll()
        XCTAssertEqual(fixture.departures[fixture.ids[0]], 1, "Cancellation remains idempotent")

        XCTAssertTrue(fixture.play(1, theme: .clothesline))
        XCTAssertEqual(fixture.panels(), [first], "The existing pool also serves the unchanged clothesline theme")
        XCTAssertLessThan(first.frame.width, 200, "A former wide stream window must return to a small paper window")
        XCTAssertLessThan(first.frame.height, 200)
        XCTAssertEqual(first.foldingID, fixture.ids[1])
        try await wait { !fixture.flights.isVisible }
        XCTAssertTrue(fixture.hidden.isEmpty)
        XCTAssertFalse(first.isPlaying)
        XCTAssertEqual(fixture.departures[fixture.ids[0]], 1)
        XCTAssertEqual(fixture.departures[fixture.ids[1]], 1)
    }

    @MainActor
    func testThemeChangeInvalidatesPendingGeometryWithoutUndoingThePaste() async throws {
        _ = NSApplication.shared
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Needs motion enabled so a flight lookup is requested")
        }
        let name = "ParticleTransferThemeChange." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let pasteboard = NSPasteboard.withUniqueName()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".txt")
        let original = "Keep this idea after the appearance changes."
        try Data(original.utf8).write(to: url)
        var lookup: CheckedContinuation<CGPoint?, Never>?
        var lookupFinished = false
        var pasted = 0, flights = 0
        defer {
            lookup?.resume(returning: nil)
            defaults.removePersistentDomain(forName: name)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: url)
        }
        let line = Line(defaults: defaults, pasteboard: pasteboard, pasteDestination: {
            .target(locateFlight: {
                let point = await withCheckedContinuation { (continuation: CheckedContinuation<CGPoint?, Never>) in
                    lookup = continuation
                }
                lookupFinished = true
                return point
            }, sendPaste: { valid in
                guard valid() else { return false }
                pasted += 1
                return true
            })
        })
        line.soundOn = false
        line.setTheme(.hologram)
        line.onPasteFlight = { _, _ in flights += 1; return true }
        let id = try XCTUnwrap(line.hang(url, quietly: true))
        line.scheduleCopy(id)
        let commitPaste = try XCTUnwrap(line.beginDoubleClick(id))
        commitPaste()
        XCTAssertEqual(pasted, 1, "Pasting is committed before its optional animation geometry arrives")
        try await wait { lookup != nil }

        line.setTheme(.clothesline)
        let completion = try XCTUnwrap(lookup)
        lookup = nil
        completion.resume(returning: CGPoint(x: 220, y: 180))
        try await wait { lookupFinished }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(flights, 0, "Geometry returned for the previous theme must not launch a late animation")
        XCTAssertEqual(pasted, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), original)
        XCTAssertEqual(line.items.filter { !$0.falling }.map(\.id), [id])
        XCTAssertEqual(try String(contentsOf: url), original)
        XCTAssertEqual(line.theme, .clothesline)
    }
}

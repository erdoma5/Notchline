import AppKit
import SwiftUI
import XCTest
@testable import Notchline

final class HologramTests: XCTestCase {
    @MainActor
    func testThemeSwitchPreservesClippingsClipboardAndPreferences() throws {
        _ = NSApplication.shared
        let name = "HologramTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let pb = NSPasteboard.withUniqueName()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".txt")
        try Data("A small, bright idea".utf8).write(to: url)
        defer { defaults.removePersistentDomain(forName: name); pb.releaseGlobally(); try? FileManager.default.removeItem(at: url) }
        defaults.set(50, forKey: "keepOnLine")
        let line = Line(defaults: defaults, pasteboard: pb)
        line.soundOn = false
        let id = try XCTUnwrap(line.hang(url, quietly: true))
        line.copy(id)
        let before = pb.changeCount
        for theme in [LineTheme.hologram, .clothesline, .hologram] {
            line.setTheme(theme)
            XCTAssertEqual(line.items.map(\.id), [id])
            XCTAssertEqual(pb.changeCount, before)
            XCTAssertEqual(pb.string(forType: .string), "A small, bright idea")
            XCTAssertEqual(defaults.integer(forKey: "keepOnLine"), 50)
        }
        let restored = Line(defaults: defaults, pasteboard: pb)
        XCTAssertEqual(restored.theme, .hologram)
        XCTAssertEqual(restored.items.map(\.url), [url])
        XCTAssertEqual(try String(contentsOf: url), "A small, bright idea")
    }

    @MainActor
    func testHolographicPullReattachesAndRemovalCanBeUndoneWithoutDeletingFile() throws {
        _ = NSApplication.shared
        let name = "HologramPull." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".txt")
        try Data("Keep this original".utf8).write(to: url)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: url) }
        let line = Line(defaults: defaults)
        line.soundOn = false; line.setTheme(.hologram); line.revealed = true
        let id = try XCTUnwrap(line.hang(url, quietly: true))
        let panel = CGRect(x: 0, y: 600, width: 1000, height: Layout.panelHeight)
        let card = CGRect(x: 430, y: panel.maxY - Layout.particleBaseline, width: 140, height: 105)
        let grip = CGPoint(x: card.midX, y: card.midY)
        let grab = PhotoGrab(card: card, pointer: grip)
        line.trackPull(id, from: grab, to: CGPoint(x: grip.x, y: grip.y - 180), in: panel)
        XCTAssertTrue(line.pull.armed)
        line.trackPull(id, from: grab, to: grip, in: panel)
        XCTAssertFalse(line.pull.armed)
        line.releasePull(id, cancelled: false)
        XCTAssertEqual(line.liveCount, 1)
        XCTAssertFalse(line.canPutBack)
        line.trackPull(id, from: grab, to: CGPoint(x: grip.x, y: grip.y - 180), in: panel)
        line.releasePull(id, cancelled: false)
        XCTAssertEqual(line.liveCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        line.putBack()
        XCTAssertEqual(line.liveCount, 1)
        XCTAssertEqual(line.items.first(where: { !$0.falling })?.url, url)
        XCTAssertEqual(line.theme, .hologram)
    }

    @MainActor
    func testHolographicTextAndPhotoPastesDispatchBeforeTheirLightFlights() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { throw XCTSkip("Motion disabled") }
        let name = "HologramPaste." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let pb = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name); pb.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("note.txt"), photo = folder.appendingPathComponent("photo.png")
        try Data("Transmit a copy".utf8).write(to: text)
        let image = NSImage(size: CGSize(width: 12, height: 12), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: photo)
        var pasted = 0, flown = 0
        let line = Line(defaults: defaults, pasteboard: pb, pasteDestination: {
            .target(locateFlight: { CGPoint(x: 100, y: 100) }, sendPaste: { valid in
                guard valid() else { return false }; pasted += 1; return true
            })
        })
        line.soundOn = false; line.setTheme(.hologram)
        line.onPasteFlight = { _, _ in XCTAssertGreaterThan(pasted, flown); flown += 1; return true }
        for url in [text, photo] {
            let id = try XCTUnwrap(line.hang(url, quietly: true))
            line.scheduleCopy(id)
            if url == photo { try await Task.sleep(for: .milliseconds(50)) }
            let action = try XCTUnwrap(line.beginDoubleClick(id)); action()
            let deadline = ContinuousClock.now + .seconds(2)
            while flown < (url == text ? 1 : 2), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(15)) }
            XCTAssertEqual(flown, url == text ? 1 : 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertEqual(pasted, 2)
        XCTAssertEqual(line.liveCount, 2)
    }

    /// Opt-in visual QA uses the real native view, isolated sample preferences
    /// and sample files; never the user's saved clips or clipboard.
    @MainActor
    func testNativeThemePreview() async throws {
        guard let output = ProcessInfo.processInfo.environment["NOTCHLINE_THEME_PREVIEW_DIR"] else { return }
        _ = NSApplication.shared
        let name = "HologramPreview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = folder.appendingPathComponent("sample.txt")
        let photo = folder.appendingPathComponent("sample.png")
        try Data("一个好点子\n让灵感有个落脚点。\n周末去山里走走，带上相机。".utf8).write(to: note)
        let sample = NSImage(size: CGSize(width: 360, height: 160), flipped: false) { rect in
            NSColor(srgbRed: 0.35, green: 0.48, blue: 0.56, alpha: 1).setFill(); rect.fill()
            let p = NSBezierPath(); p.move(to: .zero); p.line(to: CGPoint(x: 160, y: 190)); p.line(to: CGPoint(x: 310, y: 0)); p.close()
            NSColor(srgbRed: 0.16, green: 0.31, blue: 0.32, alpha: 1).setFill(); p.fill()
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sample.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: photo)
        let portrait = folder.appendingPathComponent("portrait.png")
        let portraitImage = NSImage(size: CGSize(width: 180, height: 300), flipped: false) { rect in
            NSColor(srgbRed: 0.70, green: 0.62, blue: 0.49, alpha: 1).setFill(); rect.fill()
            NSColor(srgbRed: 0.28, green: 0.39, blue: 0.36, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 42, dy: 36), xRadius: 30, yRadius: 30).fill()
            return true
        }
        let portraitRep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(portraitImage.tiffRepresentation)))
        try XCTUnwrap(portraitRep.representation(using: .png, properties: [:])).write(to: portrait)
        defer { defaults.removePersistentDomain(forName: name) }
        let line = Line(defaults: defaults); line.soundOn = false; line.setTheme(.hologram)
        _ = line.hang(note, quietly: true); _ = line.hang(portrait, quietly: true)
        _ = line.hang(photo, quietly: true); line.revealed = true
        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let host = NSHostingView(rootView: LineView(line: line)
                .background(mode == "dark" ? Color(red: 0.08, green: 0.12, blue: 0.17) : Color(white: 0.93)))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: appearance)
            let window = LinePanel(content: host)
            window.setFrame(CGRect(x: 100, y: 100, width: 760, height: Layout.panelHeight), display: false)
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(1250))
            host.needsDisplay = true
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("particles-\(mode).png"))
            window.orderOut(nil)
        }
        for progress: CGFloat in [0.32, 0.62, 0.82] {
            let preview = HStack(alignment: .bottom, spacing: 34) {
                ForEach(line.items) { item in
                    PeggedView(item: item, line: line, ropeDrop: 0, tapAngle: 0, tapHighlight: 0,
                               revealProgress: progress) { _ in }
                }
            }.frame(width: 760, height: Layout.panelHeight)
                .background(Color(red: 0.08, green: 0.12, blue: 0.17)).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: preview)
            host.sizingOptions = []
            let window = LinePanel(content: host)
            window.setFrame(CGRect(x: 100, y: 100, width: 760, height: Layout.panelHeight), display: false)
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded(); host.needsDisplay = true; host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("particles-stage-\(Int(progress * 100)).png"))
            window.orderOut(nil)
        }
    }
}

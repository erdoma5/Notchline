import SwiftUI
import XCTest
@testable import Notchline

final class DoubleClickPasteTests: XCTestCase {
    @MainActor
    func testReleaseRecognizesItsOwnLateDownButNotAPressQueuedAfterIt() throws {
        _ = NSApplication.shared
        let panel = LinePanel(content: NSView())
        func mouse(_ type: NSEvent.EventType, number: Int, time: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 8, y: 8),
                modifierFlags: [], timestamp: time, windowNumber: panel.windowNumber, context: nil,
                eventNumber: number, clickCount: 2, pressure: 0))
        }
        let press = ClippingPress(event: try mouse(.leftMouseDown, number: 7, time: 10), in: panel)
        press.complete(with: try mouse(.leftMouseUp, number: 8, time: 10.06))
        XCTAssertNil(press.release, "An unrelated release cannot authorize paste")
        press.complete(with: try mouse(.leftMouseUp, number: 7, time: 10.08))
        let release = try XCTUnwrap(press.release)
        let count = release.leftClicks
        // A delayed counter update anywhere in the completed press used to
        // fail the two-millisecond timestamp comparison in an opaque editor.
        XCTAssertTrue(release.accountsForLeftPress(from: count &- 1, to: count, lastDown: 10.023))
        XCTAssertTrue(release.accountsForLeftPress(from: count, to: count &+ 1, lastDown: 10.023))
        XCTAssertFalse(release.accountsForLeftPress(from: count &- 1, to: count, lastDown: 10.11))
        XCTAssertFalse(release.accountsForLeftPress(from: count &- 1, to: count &+ 1, lastDown: 10.023))
    }

    @MainActor
    func testConsecutiveDoubleClicksPasteEachClippingIntoTheSameEditor() throws {
        _ = NSApplication.shared
        let suite = "NotchlineTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let board = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let editor = NSTextView()
        let line = Line(defaults: defaults, pasteboard: board, pasteDestination: {
            .target { current in current() && editor.readSelection(from: board) }
        })
        let panel = LinePanel(content: NSView())
        func card(_ text: String) throws -> GrabView {
            let url = folder.appendingPathComponent(text + ".txt")
            try Data(text.utf8).write(to: url)
            let id = try XCTUnwrap(line.hang(url, quietly: true))
            let view = GrabView(frame: NSRect(x: 0, y: 0, width: 100, height: 70))
            panel.contentView?.addSubview(view)
            view.onClick = { _, press in line.scheduleCopy(id, press: press) }
            view.beginDoubleClick = { line.beginDoubleClick(id, press: $0) }
            return view
        }
        let a = try card("甲"), b = try card("乙")
        func click(_ view: GrabView, _ count: Int, x: CGFloat = 20,
                   at time: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 20),
                    modifierFlags: [], timestamp: time,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 0))
            }
            view.mouseDown(with: try event(.leftMouseDown))
            view.mouseUp(with: try event(.leftMouseUp))
        }
        // AppKit may keep counting at the same spot, or start a new series
        // when the pointer moves. Both should deliver one paste per pair.
        for (view, first, second, expected) in [(a, 1, 2, "甲"), (a, 3, 4, "甲甲"),
                                                 (b, 1, 2, "甲甲乙"), (b, 3, 4, "甲甲乙乙")] {
            try click(view, first)
            XCTAssertEqual(board.string(forType: .string), view === a ? "甲" : "乙",
                           "The first release must copy before the double-click interval ends")
            XCTAssertEqual(line.feedback?.kind, .copied)
            try click(view, second)
            XCTAssertEqual(editor.string, expected)
            XCTAssertFalse(line.awaitingSingleClick)
        }
        try click(a, 1)
        try click(b, 2)
        XCTAssertEqual(editor.string, "甲甲乙乙", "Clicks on two different cards cannot form a paste")
        try click(b, 3)
        XCTAssertEqual(editor.string, "甲甲乙乙乙")
        XCTAssertFalse(line.awaitingSingleClick)

        let time = ProcessInfo.processInfo.systemUptime
        try click(a, 1, at: time)
        try click(a, 1, x: 26, at: time + NSEvent.doubleClickInterval / 2)
        XCTAssertEqual(editor.string, "甲甲乙乙乙甲", "A reset click count within one clipping must still paste")
        XCTAssertFalse(line.awaitingSingleClick)

        try click(b, 1, at: time + 1)
        try click(b, 1, x: 65, at: time + 1.05)
        try click(b, 1, x: 65, at: time + 1.12 + NSEvent.doubleClickInterval)
        XCTAssertEqual(editor.string, "甲甲乙乙乙甲", "Distant or slow single clicks must not paste")
        XCTAssertTrue(line.awaitingSingleClick)
        line.cancelScheduledCopy()
    }

    @MainActor
    func testMissingAXMetadataDoesNotVetoNativePaste() {
        for attrs: [String: Any] in [[:], ["AXRole": "AXGroup"], ["AXRole": "AXTextField"]] {
            XCTAssertFalse(PasteDestination.blocksPaste(attribute: { attrs[$0] }))
        }
        for attrs: [String: Any] in [
            ["AXSubrole": "AXSecureTextField"], ["AXRole": "AXTextField", "AXEnabled": false],
            ["AXRole": "AXTextArea", "AXEditable": false]
        ] {
            XCTAssertTrue(PasteDestination.blocksPaste(attribute: { attrs[$0] }))
        }
    }

    @MainActor
    func testDoubleClickInsertsTheFullTextOrAnImageAtTheSelection() async throws {
        _ = NSApplication.shared
        let suite = "NotchlineTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pb = NSPasteboard.withUniqueName()
        defer {
            pb.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }

        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 150))
        editor.isRichText = true
        editor.importsGraphics = true
        editor.string = "A__Z"
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        var deliveries = 0
        var target = PasteDestination.target { current in
            guard current() else { return false }
            deliveries += 1
            return editor.readSelection(from: pb)
        }
        let line = Line(defaults: defaults, pasteboard: pb, pasteDestination: { target })
        func doubleClick(_ id: UUID) throws {
            line.scheduleCopy(id)
            let commit = try XCTUnwrap(line.beginDoubleClick(id))
            commit()
        }
        let file = folder.appendingPathComponent("note.txt")
        let original = " 你好，🌿\n" + String(repeating: "全文", count: 900)
        try Data(original.utf8).write(to: file)
        let id = try XCTUnwrap(line.hang(file, quietly: true))
        let item = try XCTUnwrap(line.items.first)

        // Use the native responder that SwiftUI puts on the hanging card.
        let responder = NSHostingView(rootView: GrabArea(item: item, line: line) { _ in })
        let panel = LinePanel(content: responder)
        panel.setContentSize(CGSize(width: 120, height: 80))
        responder.layoutSubtreeIfNeeded()
        func findCard(_ view: NSView) -> GrabView? {
            if let card = view as? GrabView { return card }
            return view.subviews.lazy.compactMap(findCard).first
        }
        let card = try XCTUnwrap(findCard(responder))
        func clickEvent(_ type: NSEvent.EventType, _ count: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 40, y: 40),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: count, pressure: 0))
        }
        card.mouseDown(with: try clickEvent(.leftMouseDown, 1))
        card.mouseUp(with: try clickEvent(.leftMouseUp, 1))
        XCTAssertTrue(line.awaitingSingleClick)
        card.mouseDown(with: try clickEvent(.leftMouseDown, 2))
        XCTAssertEqual(deliveries, 0, "The second press may still become a hold or drag")
        card.mouseUp(with: try clickEvent(.leftMouseUp, 2))
        XCTAssertFalse(line.awaitingSingleClick)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(editor.string, "A" + original + "Z")
        XCTAssertEqual(line.feedback?.kind, .pasteRequested)

        let photo = folder.appendingPathComponent("image.png")
        let bitmap = try XCTUnwrap(item.thumb.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: photo)
        let imageID = try XCTUnwrap(line.hang(photo, quietly: true))
        editor.string = "AB"
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        try doubleClick(imageID)
        for _ in 0..<100 where deliveries < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(deliveries, 2)
        XCTAssertEqual(pb.data(forType: .png), png)
        XCTAssertNil(pb.string(forType: .fileURL))
        XCTAssertNotNil(pb.data(forType: ClipboardWatcher.fromLine))
        XCTAssertNotNil(editor.textStorage?.attribute(.attachment, at: 1, effectiveRange: nil))
        XCTAssertEqual(line.feedback?.kind, .pasteRequested)

        let plain = NSTextView()
        plain.isRichText = false
        plain.importsGraphics = false
        plain.string = "ABC"
        plain.setSelectedRange(NSRange(location: 1, length: 0))
        // A plain editor only negotiates strings. An image paste must not
        // silently turn into a filename or replace the selected text.
        XCTAssertNil(pb.availableType(from: [.string, .fileURL]))
        XCTAssertFalse(plain.readSelection(from: pb))
        XCTAssertEqual(plain.string, "ABC")

        // Repeated denied clicks stay copy-only. A fresh permission check on
        // the next gesture can succeed without reconstructing the line.
        target = .permissionRequired
        for _ in 0..<2 {
            try doubleClick(id)
            XCTAssertEqual(pb.string(forType: .string), original)
            XCTAssertEqual(line.feedback?.kind, .needsAccessibility)
            XCTAssertEqual(deliveries, 2)
        }
        target = .target { $0() }
        try doubleClick(id)
        XCTAssertEqual(line.feedback?.kind, .pasteRequested)

        // A missing input or focus change also offers manual paste.
        for (destination, kind): (PasteDestination, Line.Feedback.Kind) in [
            (.noTarget, .needsEditor), (.target { _ in false }, .needsEditor)
        ] {
            target = destination
            try doubleClick(id)
            XCTAssertEqual(pb.string(forType: .string), original)
            XCTAssertEqual(line.feedback?.kind, kind)
            XCTAssertEqual(deliveries, 2)
        }

        // A newer copy during PNG preparation wins, even before the main
        // queue gets a chance to deliver the decoded image.
        try doubleClick(imageID)
        pb.clearContents()
        pb.setString("newer copy", forType: .string)
        for _ in 0..<100 where line.feedback?.kind != .clipboardChanged { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(line.feedback?.kind, .clipboardChanged)
        XCTAssertEqual(pb.string(forType: .string), "newer copy")

        // Also guard the handoff after content has been written, while AX
        // is still checking the destination.
        target = .target { current in
            pb.clearContents()
            pb.setString("latest", forType: .string)
            XCTAssertFalse(current())
            return false
        }
        try doubleClick(id)
        XCTAssertEqual(line.feedback?.kind, .clipboardChanged)
        XCTAssertEqual(pb.string(forType: .string), "latest")

        // A focus change while the button is down must never retarget the
        // gesture to the new field on mouse-up.
        var originalIsFocused = true
        target = .target { current in originalIsFocused && current() }
        line.scheduleCopy(id)
        let originalClick = try XCTUnwrap(line.beginDoubleClick(id))
        originalIsFocused = false
        target = .target { _ in XCTFail("Pasted into a newly focused field"); return true }
        originalClick()
        XCTAssertEqual(line.feedback?.kind, .needsEditor)

        line.scheduleCopy(id)
        let beforeNewCopy = try XCTUnwrap(line.beginDoubleClick(id))
        pb.clearContents()
        pb.setString("copied while held", forType: .string)
        beforeNewCopy()
        XCTAssertEqual(line.feedback?.kind, .clipboardChanged)
        XCTAssertEqual(pb.string(forType: .string), "copied while held")

        // A second click on a different card, or one that becomes a drag or
        // hold, must not paste. Use the actual native mouse responder.
        var gestures = 0
        target = .target { _ in gestures += 1; return true }
        line.scheduleCopy(imageID)
        card.mouseDown(with: try clickEvent(.leftMouseDown, 2))
        card.mouseUp(with: try clickEvent(.leftMouseUp, 2))
        XCTAssertEqual(gestures, 0)
        line.cancelScheduledCopy()
        card.mouseDown(with: try clickEvent(.leftMouseDown, 1))
        card.mouseUp(with: try clickEvent(.leftMouseUp, 1))
        card.mouseDown(with: try clickEvent(.leftMouseDown, 2))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 75, y: 40),
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 2, pressure: 0))
        card.mouseDragged(with: drag)
        card.mouseUp(with: try clickEvent(.leftMouseUp, 2))
        XCTAssertEqual(gestures, 0)
        var held = false
        card.onLongPress = { held = true }
        card.mouseDown(with: try clickEvent(.leftMouseDown, 1))
        card.mouseUp(with: try clickEvent(.leftMouseUp, 1))
        card.mouseDown(with: try clickEvent(.leftMouseDown, 2))
        for _ in 0..<100 where !held { try await Task.sleep(for: .milliseconds(10)) }
        card.mouseUp(with: try clickEvent(.leftMouseUp, 2))
        XCTAssertTrue(held)
        XCTAssertEqual(gestures, 0)
    }
}

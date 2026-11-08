import AppKit
import SwiftUI
import XCTest
@testable import Notchline

final class ParticleScanPreviewTests: XCTestCase {
    /// Uses the production LineView, masks and scanner, with sample assets only.
    @MainActor
    func testRenderNativeScanFramesWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["NOTCHLINE_SCAN_PREVIEW_DIR"] else { return }
        let dark = ProcessInfo.processInfo.environment["NOTCHLINE_SCAN_APPEARANCE"] != "light"
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "ScanPreview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)), pb = NSPasteboard.withUniqueName()
        defer { defaults.removePersistentDomain(forName: name); pb.releaseGlobally() }
        let note = folder.appendingPathComponent("scan-note.txt")
        try Data("一个好点子\n让灵感有个落脚点。\n周末去山里走走，带上相机。".utf8).write(to: note)
        let line = Line(defaults: defaults, pasteboard: pb)
        line.soundOn = false; line.setTheme(.hologram)
        XCTAssertNotNil(line.hang(note, quietly: true))
        for (filename, size) in [("portrait.png", CGSize(width: 180, height: 300)),
                                 ("landscape.png", CGSize(width: 360, height: 180))] {
            let image = NSImage(size: size, flipped: false) { rect in
                if rect.height > rect.width {
                    NSColor(srgbRed: 0.70, green: 0.62, blue: 0.49, alpha: 1).setFill(); rect.fill()
                    NSColor(srgbRed: 0.28, green: 0.39, blue: 0.36, alpha: 1).setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 42, dy: 36), xRadius: 30, yRadius: 30).fill()
                } else {
                    NSColor(srgbRed: 0.35, green: 0.48, blue: 0.56, alpha: 1).setFill(); rect.fill()
                    let mountain = NSBezierPath(); mountain.move(to: .zero)
                    mountain.line(to: CGPoint(x: rect.midX, y: rect.maxY - 12))
                    mountain.line(to: CGPoint(x: rect.maxX - 30, y: 0)); mountain.close()
                    NSColor(srgbRed: 0.16, green: 0.31, blue: 0.32, alpha: 1).setFill(); mountain.fill()
                }
                return true
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let url = folder.appendingPathComponent(filename)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            XCTAssertNotNil(line.hang(url, quietly: true))
        }
        line.revealed = true
        func scene(_ progress: CGFloat) -> some View {
            LineView(line: line, presentationProgress: progress)
                .background(dark ? Color(red: 0.07, green: 0.105, blue: 0.15) : Color(white: 0.93))
                .environment(\.colorScheme, dark ? .dark : .light)
        }
        let host = NSHostingView(rootView: scene(0))
        host.sizingOptions = []
        let window = LinePanel(content: host)
        window.alphaValue = 0
        window.setFrame(CGRect(x: 100, y: 100, width: 760, height: Layout.panelHeight), display: false)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(700))
        for step in 0...50 {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { host.rootView = scene(CGFloat(step) / 50) }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            host.needsDisplay = true; host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent(String(format: "scan-%03d.png", step)))
        }
    }
}

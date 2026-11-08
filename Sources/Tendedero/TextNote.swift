import SwiftUI
import Darwin

/// A clipping's stock is stored on its file, so moving it (including Trash and
/// Put back) preserves its color without changing the plain text or its name.
enum PaperStock: UInt8, CaseIterable {
    case parchment = 0, butter = 1, mint = 2, rose = 3, sky = 4, lilac = 5, peach = 6

    private static let attribute = "local.notchline.personal.paper-stock"

    static func randomColor(after previous: PaperStock?) -> PaperStock {
        allCases.filter { $0 != .parchment && $0 != previous }.randomElement()!
    }

    static func read(from url: URL) -> PaperStock {
        var value: UInt8 = 0
        let size = url.withUnsafeFileSystemRepresentation { path in
            getxattr(path, attribute, &value, 1, 0, XATTR_NOFOLLOW)
        }
        return size == 1 ? PaperStock(rawValue: value) ?? .parchment : .parchment
    }

    func mark(_ url: URL) {
        var value = rawValue
        let result = url.withUnsafeFileSystemRepresentation { path in
            setxattr(path, Self.attribute, &value, 1, 0, XATTR_NOFOLLOW)
        }
        if result != 0 { log.error("Could not save the clipping’s paper color") }
    }

    fileprivate var palette: PaperPalette {
        switch self {
        case .parchment: PaperPalette(face: 0xFCF7E8, shade: 0xF2EBD6, fold: 0xC4B397, accent: 0x943B29)
        case .butter:    PaperPalette(face: 0xFBEFBA, shade: 0xF1DB95, fold: 0xCFB56E, accent: 0x72551F)
        case .mint:      PaperPalette(face: 0xD8EDDD, shade: 0xBFDCC7, fold: 0x97B89F, accent: 0x365E4C)
        case .rose:      PaperPalette(face: 0xF9DFE3, shade: 0xEBC4CC, fold: 0xC9A0AC, accent: 0x794052)
        case .sky:       PaperPalette(face: 0xDCECF7, shade: 0xC1D9EB, fold: 0x9CB8CE, accent: 0x395770)
        case .lilac:     PaperPalette(face: 0xEAE2F5, shade: 0xD6C8E8, fold: 0xB4A3C9, accent: 0x59496F)
        case .peach:     PaperPalette(face: 0xFBE5CF, shade: 0xF0CDAF, fold: 0xCCA789, accent: 0x754732)
        }
    }
}

private struct PaperPalette {
    let face, shade, fold, accent: Color

    init(face: UInt32, shade: UInt32, fold: UInt32, accent: UInt32) {
        func color(_ rgb: UInt32) -> Color {
            Color(.sRGB, red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255)
        }
        self.face = color(face)
        self.shade = color(shade)
        self.fold = color(fold)
        self.accent = color(accent)
    }
}

/// The file holds the original UTF-8 bytes. Only the two paper views use an excerpt.
struct TextNote {
    static let folder = Inbox.folder.deletingLastPathComponent().appendingPathComponent("Text Clips", isDirectory: true)
    static let maxBytes = 1_048_576
    let excerpt: String
    let count: Int
    let stock: PaperStock

    init(_ text: String, stock: PaperStock = .parchment) {
        self.stock = stock
        count = text.count
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sample = trimmed.prefix(1600)
        excerpt = String(sample) + (sample.endIndex == trimmed.endIndex ? "" : "…")
    }

    static func accepts(_ url: URL) -> Bool { url.pathExtension.lowercased() == "txt" }

    init?(contentsOf url: URL) {
        guard let text = Self.read(url) else { return nil }
        self.init(text, stock: PaperStock.read(from: url))
    }

    static func read(_ url: URL) -> String? {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= maxBytes,
              let data = try? Data(contentsOf: url), data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @MainActor
    func thumbnail(scale: CGFloat) -> NSImage? {
        render(NotePaper(note: self, expanded: false, lines: 4).frame(width: 144, height: 104), scale: scale)
    }

    @MainActor
    func preview(width: CGFloat, height: CGFloat, scale: CGFloat, showsGestureHint: Bool = false) -> NSImage? {
        let lines = min(12, max(1, Int((height - 76 - (showsGestureHint ? 34 : 0)) / 27)))
        return render(NotePaper(note: self, expanded: true, lines: lines, showsGestureHint: showsGestureHint)
            .frame(width: min(420, width)).fixedSize(horizontal: false, vertical: true), scale: scale)
    }

    @MainActor
    private func render(_ view: some View, scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        image.accessibilityDescription = String(excerpt.prefix(160))
        return image
    }
}

/// A printer's mark, a ruled margin and a turned corner give the slip its
/// identity even when there's only one word on it.
private struct NotePaper: View {
    let note: TextNote
    let expanded: Bool
    let lines: Int
    var showsGestureHint = false

    private let ink = Color(red: 0.19, green: 0.17, blue: 0.15)
    private var palette: PaperPalette { note.stock.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 10 : 4) {
            HStack(spacing: expanded ? 7 : 4) {
                Image(systemName: "quote.opening")
                    .font(.system(size: expanded ? 14 : 10, weight: .black, design: .serif))
                if expanded {
                    Text(verbatim: L("Clipping").localizedUppercase)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.8)
                    Rectangle().fill(palette.accent.opacity(0.28)).frame(height: 0.6)
                }
            }
            .foregroundStyle(palette.accent)

            Text(verbatim: note.excerpt)
                .font(.system(size: expanded ? 19 : (note.count <= 16 ? 18 : 14), design: .serif))
                .foregroundStyle(ink)
                .lineSpacing(expanded ? 3 : 1)
                .lineLimit(lines)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if expanded {
                Text(verbatim: String(format: L("Characters · %@"), note.count.formatted()))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.72))
                if showsGestureHint {
                    Text(verbatim: L("Click to copy the full text · Double-click to paste"))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.accent)
                }
            }
        }
        .padding(.leading, expanded ? 26 : 14)
        .padding(.trailing, expanded ? 23 : 12)
        .padding(.vertical, expanded ? 17 : 9)
        .frame(maxWidth: .infinity, maxHeight: expanded ? nil : .infinity, alignment: .topLeading)
        .background {
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let fold: CGFloat = expanded ? 19 : 12
                let margin: CGFloat = expanded ? 15 : 8
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [palette.face, palette.shade]),
                    startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
                var rule = Path()
                rule.move(to: CGPoint(x: margin, y: 0))
                rule.addLine(to: CGPoint(x: margin, y: h))
                ctx.stroke(rule, with: .color(palette.accent.opacity(0.27)), lineWidth: 0.6)
                var corner = Path()
                corner.move(to: CGPoint(x: w - fold, y: h))
                corner.addLine(to: CGPoint(x: w, y: h - fold))
                corner.addLine(to: CGPoint(x: w, y: h))
                corner.closeSubpath()
                ctx.fill(corner, with: .linearGradient(Gradient(colors: [
                    palette.fold, palette.face]),
                    startPoint: CGPoint(x: w - fold / 2, y: h - fold / 2), endPoint: CGPoint(x: w, y: h)))
            }
        }
    }
}

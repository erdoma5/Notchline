import AppKit
import ImageIO
import QuartzCore

/// A passive enlargement below the line. It never takes focus or mouse events,
/// so moving across the hanging photos can replace it without closing anything.
@MainActor
final class HoverPreviewPanel: NSPanel {
    private let imageView = NSImageView()
    private let background = NSVisualEffectView()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let edgeGlow = CAShapeLayer()
    private let defaults: UserDefaults
    private(set) var itemID: UUID?
    private var requestGeneration = 0
    private var cached: [URL: (image: NSImage, modified: Date?)] = [:]
    private var cacheOrder: [URL] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        ignoresMouseEvents = true

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        edgeGlow.fillColor = nil
        edgeGlow.lineWidth = 1.4
        edgeGlow.shadowOffset = .zero
        edgeGlow.shadowRadius = 4
        edgeGlow.shadowOpacity = 0.35
        edgeGlow.isHidden = true
        rim.startPoint = CGPoint(x: 0.15, y: 1)
        rim.endPoint = CGPoint(x: 0.85, y: 0)
        rim.locations = [0, 0.48, 1]
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = 0.55
        rim.mask = rimMask
        rim.isHidden = true
        background.layer?.addSublayer(edgeGlow)
        background.layer?.addSublayer(rim)
        let content = NSView()
        contentView = content
        content.addSubview(background)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        content.addSubview(imageView)
    }

    func show(_ item: Pegged, anchor: NSRect, below linePanel: LinePanel) {
        guard let screen = linePanel.screen else { return }
        let visible = screen.visibleFrame
        let roomBelow = linePanel.frame.minY - visible.minY
        guard roomBelow > 130 else { return }

        let maxWidth = min(580, visible.width - 40)
        let maxHeight = min(440, roomBelow * 0.7 - 28)
        let paper: NSImage?
        let hintKey = "didShowDoubleClickPasteHint"
        let showsHint = item.isText && !defaults.bool(forKey: hintKey)
        if item.isText {
            guard let preview = TextNote(contentsOf: item.url)?.preview(width: maxWidth, height: maxHeight,
                scale: screen.backingScaleFactor, showsGestureHint: showsHint) else {
                hide()
                return
            }
            paper = preview
        } else {
            paper = nil
        }
        let sourceSize = paper?.size ?? item.thumb.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let fit = min(maxWidth / sourceSize.width, maxHeight / sourceSize.height)
        let scale = paper == nil ? fit : min(1, fit)
        let imageSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let holographic = LineTheme.current == .hologram
        let inset: CGFloat = item.isText ? (holographic ? 6 : 0) : 10
        let width = imageSize.width + 2 * inset
        let height = imageSize.height + 2 * inset
        let x = min(max(anchor.midX - width / 2, visible.minX + 12), visible.maxX - width - 12)
        let y = linePanel.frame.minY - height - 12
        let modified = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let sharp = cached[item.url].flatMap { $0.modified == modified ? $0.image : nil }

        itemID = item.id
        requestGeneration += 1
        imageView.image = paper ?? sharp ?? item.thumb
        background.isHidden = item.isText && !holographic
        background.material = holographic ? .hudWindow : .popover
        background.layer?.borderWidth = 0
        imageView.layer?.cornerRadius = item.isText ? Frame.paperRadius : 8
        background.frame = NSRect(x: 0, y: 0, width: width, height: height)
        imageView.frame = NSRect(x: inset, y: inset, width: imageSize.width, height: imageSize.height)
        // Light belongs to the narrow material inset. The original image
        // stays above it, at its full resolution and without a color wash.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.isHidden = !holographic
        edgeGlow.isHidden = !holographic
        if holographic {
            let highlight = Hologram.color.blended(withFraction: 0.72, of: .white) ?? .white
            rim.colors = [highlight.withAlphaComponent(0.63).cgColor,
                          Hologram.color.withAlphaComponent(0.08).cgColor,
                          highlight.withAlphaComponent(0.27).cgColor]
            rim.frame = background.bounds
            rimMask.frame = background.bounds
            rim.contentsScale = screen.backingScaleFactor
            let path = CGPath(roundedRect: background.bounds.insetBy(dx: 1, dy: 1),
                              cornerWidth: 13, cornerHeight: 13, transform: nil)
            rimMask.path = path
            edgeGlow.frame = background.bounds
            edgeGlow.path = path
            edgeGlow.strokeColor = Hologram.color.withAlphaComponent(0.12).cgColor
            edgeGlow.shadowColor = Hologram.color.cgColor
            edgeGlow.contentsScale = screen.backingScaleFactor
        }
        CATransaction.commit()
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        invalidateShadow()
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                animator().alphaValue = 1
            }
        }
        if showsHint { defaults.set(true, forKey: hintKey) }
        if sharp == nil, !item.isRecording, !item.isText {
            loadSharpImage(for: item.url, id: item.id, modified: modified,
                           generation: requestGeneration)
        }
    }

    func hide() {
        guard itemID != nil else { return }
        requestGeneration += 1
        itemID = nil
        orderOut(nil)
        imageView.image = nil
    }

    private func loadSharpImage(for url: URL, id: UUID, modified: Date?, generation: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.cached[url] = (image, modified)
                self.cacheOrder.removeAll { $0 == url }
                self.cacheOrder.append(url)
                if self.cacheOrder.count > 4 {
                    self.cached[self.cacheOrder.removeFirst()] = nil
                }
                if self.itemID == id, self.requestGeneration == generation {
                    self.imageView.image = image
                }
            }
        }
    }
}

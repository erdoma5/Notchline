import AppKit
import QuartzCore

/// A small, mouse-transparent window travels beneath the original grab point.
/// The line keeps receiving the drag. The margin lets the final particles pass
/// the edges of the card without creating a screen-sized drawing surface.
@MainActor
final class LoosePhotoPanel: NSPanel {
    private let surface: LoosePhotoSurface
    private let grip: CGPoint
    private let dockFrame: CGRect
    private static let margin: CGFloat = 128
    private var animationTimer: Timer?
    private var animationStart = CACurrentMediaTime()
    private var readinessStart = CACurrentMediaTime()
    private var readinessFrom: CGFloat = 0
    private(set) var removalArmed = false
    private enum Motion { case held, dispersing, returning, hidden }
    private var motion: Motion = .held

    var isAnimating: Bool { animationTimer?.isValid == true }
    var removalReadiness: CGFloat { surface.readiness }

    init?(item: Pegged, grab: PhotoGrab, theme: LineTheme = .clothesline) {
        let size = grab.card.size
        guard size.width > 0, size.height > 0,
              let snapshot = Self.snapshot(item, size: size, theme: theme) else { return nil }
        let frame = grab.card.insetBy(dx: -Self.margin, dy: -Self.margin)
        let card = CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: size)
        surface = LoosePhotoSurface(frame: CGRect(origin: .zero, size: frame.size), image: snapshot, card: card)
        surface.holographic = theme == .hologram
        dockFrame = grab.card
        grip = CGPoint(x: grab.pointer.x - grab.card.minX, y: grab.pointer.y - grab.card.minY)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = surface
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func orderOut(_ sender: Any?) {
        stopAnimating()
        motion = .hidden
        super.orderOut(sender)
    }

    func follow(_ card: CGRect) {
        guard motion == .held else { return }
        setFrameOrigin(CGPoint(x: card.minX - Self.margin, y: card.minY - Self.margin))
        if !isVisible { orderFrontRegardless() }
        if surface.holographic && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { startAnimating() }
    }

    /// Uses the same hysteresis and docking decision as the actual removal.
    /// Crossing back into the slot reverses the light cue without erasing pixels.
    func setRemovalArmed(_ armed: Bool) {
        guard motion == .held, removalArmed != armed else { return }
        updateReadiness(at: CACurrentMediaTime())
        readinessFrom = surface.readiness
        readinessStart = CACurrentMediaTime()
        removalArmed = armed
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { surface.readiness = armed ? 1 : 0 }
        surface.needsDisplay = true
    }

    func disperse() {
        guard motion == .held else { return }
        stopAnimating()
        motion = .dispersing
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                animator().alphaValue = 0
            } completionHandler: { [self] in MainActor.assumeIsolated { orderOut(nil) } }
            return
        }
        if surface.holographic { surface.dissolving = true }
        else { surface.dust = PhotoDust(image: surface.image, size: surface.card.size, grip: grip) }
        animationStart = CACurrentMediaTime()
        surface.elapsed = 0
        surface.needsDisplay = true
        startAnimating()
    }

    func returnToDock() {
        guard motion == .held else { return }
        setRemovalArmed(false)
        motion = .returning
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { orderOut(nil); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrameOrigin(CGPoint(x: dockFrame.minX - Self.margin, y: dockFrame.minY - Self.margin))
            animator().alphaValue = 0
        } completionHandler: { [self] in MainActor.assumeIsolated { orderOut(nil) } }
    }

    private func updateReadiness(at time: TimeInterval) {
        let target: CGFloat = removalArmed ? 1 : 0
        let t = Hologram.ease(CGFloat((time - readinessStart) / 0.16))
        surface.readiness = readinessFrom + (target - readinessFrom) * t
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        // This temporary window is retained only while following the gesture,
        // returning, or evaporating. orderOut also ends its display timer.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if motion == .dispersing {
                    surface.elapsed = now - animationStart
                    let duration = surface.holographic ? ParticleEvaporation.duration : PhotoDust.lifetime
                    if surface.elapsed >= duration { orderOut(nil); return }
                } else {
                    updateReadiness(at: now)
                    surface.heldTime = now - animationStart
                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        surface.readiness = removalArmed ? 1 : 0
                        stopAnimating()
                    }
                }
                surface.needsDisplay = true
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Flatten the frame and thumbnail together, so the very same pixels
    /// that follow the pointer become the fragments. Includes video badges.
    static func snapshot(_ item: Pegged, size: CGSize, theme: LineTheme) -> CGImage? {
        let width = Int(ceil(size.width * 2)), height = Int(ceil(size.height * 2))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let photo = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        ctx.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        let card = CGRect(origin: .zero, size: size)
        func round(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
            CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        if item.isText {
            ctx.addPath(round(card, Frame.paperRadius))
            ctx.clip()
            ctx.draw(photo, in: card)
            return ctx.makeImage()
        }
        ctx.addPath(round(card, Frame.radius))
        if theme == .hologram { ctx.setFillColor(NSColor(srgbRed: 0.035, green: 0.10, blue: 0.16, alpha: 0.6).cgColor) }
        else { ctx.setFillColor(gray: 0.96, alpha: 0.92) }
        ctx.fillPath()
        let inset = card.insetBy(dx: Frame.inset, dy: Frame.inset)
        ctx.addPath(round(inset, Frame.radius - Frame.inset))
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(photo, in: inset)
        if item.isRecording {
            ctx.translateBy(x: card.midX, y: card.midY)
            ctx.setFillColor(gray: 0.14, alpha: 0.64)
            ctx.fillEllipse(in: CGRect(x: -13, y: -13, width: 26, height: 26))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.move(to: CGPoint(x: -3, y: -5))
            ctx.addLine(to: CGPoint(x: 5, y: 0))
            ctx.addLine(to: CGPoint(x: -3, y: 5))
            ctx.closePath()
            ctx.fillPath()
        }
        return ctx.makeImage()
    }
}

private final class LoosePhotoSurface: NSView {
    var holographic = false
    var dissolving = false
    let image: CGImage
    let card: CGRect
    var dust: PhotoDust?
    var elapsed: Double = 0
    var readiness: CGFloat = 0
    var heldTime: TimeInterval = 0

    init(frame: CGRect, image: CGImage, card: CGRect) {
        self.image = image
        self.card = card
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)
        ctx.saveGState()
        ctx.translateBy(x: card.minX, y: card.minY)
        if dissolving {
            Hologram.dissolve(image: image, in: ctx, size: card.size, progress: elapsed / ParticleEvaporation.duration)
        } else if let dust {
            dust.draw(in: ctx, elapsed: elapsed)
        } else if holographic {
            let accessibility = NSWorkspace.shared
            ParticleEvaporation.drawHeld(image: image, in: ctx, size: card.size, readiness: readiness,
                time: heldTime, reducedMotion: accessibility.accessibilityDisplayShouldReduceMotion,
                reducedTransparency: accessibility.accessibilityDisplayShouldReduceTransparency,
                increasedContrast: accessibility.accessibilityDisplayShouldIncreaseContrast)
        } else {
            ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 9,
                          color: NSColor.black.withAlphaComponent(0.22).cgColor)
            ctx.draw(image, in: CGRect(origin: .zero, size: card.size))
        }
        ctx.restoreGState()
    }
}

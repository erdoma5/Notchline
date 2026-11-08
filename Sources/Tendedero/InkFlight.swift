import AppKit
import QuartzCore

enum InkSpeed: String {
    case fast, medium, slow

    var timing: (fold: TimeInterval, hold: TimeInterval, glide: TimeInterval) {
        switch self {
        case .fast:   (0.56, 0.09, 0.68)
        case .medium: (0.72, 0.09, 0.92)
        case .slow:   (0.90, 0.10, 1.18)
        }
    }

    var duration: TimeInterval { timing.fold + timing.hold + timing.glide }
    var particleDuration: TimeInterval {
        switch self { case .fast: 1.28; case .medium: 1.68; case .slow: 2.18 }
    }

    static var current: Self {
        get { UserDefaults.standard.string(forKey: "inkFlightSpeed").flatMap(Self.init(rawValue:)) ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "inkFlightSpeed") }
    }
}

struct InkFlightMotion {
    let start, end: CGPoint
    let tilt: CGFloat  // clockwise degrees on the line
    let speed: InkSpeed
    let pointsLeft: Bool
    private let departure, approach: CGPoint  // control points of the cubic
    private let turnsBack: Bool

    init(start: CGPoint, end: CGPoint, tilt: CGFloat, speed: InkSpeed = .medium,
         sourceScreen: CGRect? = nil, launchLeft: Bool? = nil) {
        self.start = start
        self.end = end
        self.tilt = tilt
        self.speed = speed
        let dx = end.x - start.x, dy = end.y - start.y
        let distance = hypot(dx, dy)
        let rise = min(10, distance * 0.025, max(0, (sourceScreen?.maxY ?? .infinity) - start.y - 32))
        // A second paste can move the caret while this sheet is folding.
        // Keep the same paper nose and turn in flight if it now faces away.
        let facesAway = dx != 0 && launchLeft.map { $0 != (dx < 0) } == true
        turnsBack = abs(dx) < abs(dy) * 0.36 || facesAway
        if turnsBack {
            // A field immediately below the peg gives a glider no runway.
            // Swing into the open side, then come back level with the field.
            let reach = min(220, distance * 0.43)
            let leftmost = min(start.x, end.x), rightmost = max(start.x, end.x)
            let leftRoom = max(0, leftmost - (sourceScreen?.minX ?? -.infinity) - 28)
            let rightRoom = max(0, (sourceScreen?.maxX ?? .infinity) - rightmost - 28)
            let leftReach = min(reach, leftRoom), rightReach = min(reach, rightRoom)
            pointsLeft = launchLeft ?? (leftReach == rightReach ? dx < 0 : leftReach > rightReach)
            let shoulder = pointsLeft ? leftmost - leftReach : rightmost + rightReach
            let dip = min(45, distance * 0.18, max(0, start.y - (sourceScreen?.minY ?? -.infinity) - 24))
            let lift = facesAway && abs(dy) < dip ? -dip : rise
            departure = CGPoint(x: shoulder, y: start.y + lift)
            approach = CGPoint(x: shoulder, y: end.y)
        } else {
            // Both tangents are nearly horizontal. The middle of the curve
            // carries the change in altitude, leaving room to flare on arrival.
            pointsLeft = launchLeft ?? (dx < 0)
            departure = CGPoint(x: start.x + dx * 0.48, y: start.y + rise)
            approach = CGPoint(x: end.x - dx * 0.38, y: end.y)
        }
    }

    struct State {
        var center: CGPoint
        var fold, scale, bankScale, angle, opacity: CGFloat
        var sourceReleased: Bool
    }

    func state(at fraction: Double) -> State {
        func unit(_ t: CGFloat) -> CGFloat { min(1, max(0, t)) }
        func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

        let elapsed = unit(fraction) * speed.duration
        let timing = speed.timing
        let fold = unit(elapsed / timing.fold)
        let glide = unit((elapsed - timing.fold - timing.hold) / timing.glide)
        let t = ease(glide), u = 1 - t
        func position(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
        }
        func tangent(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            u * u * (b - a) + 2 * u * t * (c - b) + t * t * (d - c)
        }
        let center = CGPoint(x: position(start.x, departure.x, approach.x, end.x),
                             y: position(start.y, departure.y, approach.y, end.y))
        let direction: CGFloat = pointsLeft ? -1 : 1
        let vx = direction * tangent(start.x, departure.x, approach.x, end.x)
        let vy = direction * tangent(start.y, departure.y, approach.y, end.y)
        // The glide is seen slightly from above. Keep the silhouette open on
        // the descent and show the bank by foreshortening the wings in the turn.
        var pitch = atan2(vy * 0.56, vx)
        if turnsBack && vx < 0 && abs(vy) < 0.00001 {
            pitch = direction * (end.y < start.y ? -.pi : .pi)
        }
        let turn = ease(unit((fold - 0.70) / 0.30))
        let bank = sin(.pi * t)
        let flare = ease(unit((glide - 0.71) / 0.29))
        let traveled = hypot(center.x - start.x, center.y - start.y)
        let clearDistance = min(52, 0.23 * hypot(end.x - start.x, end.y - start.y))
        return State(center: center, fold: fold,
                     scale: 1 - 0.07 * ease(fold) - 0.16 * t - 0.47 * flare,
                     bankScale: 1 - (turnsBack ? 0.25 : 0.14) * bank * bank,
                     angle: -tilt * .pi / 180 * (1 - turn) + pitch * turn,
                     opacity: 1 - ease(unit((glide - 0.80) / 0.20)),
                     sourceReleased: glide > 0 && (traveled >= clearDistance || glide >= 0.55))
    }
}

private final class FoldingPaperLayer: CALayer {
    var plane: PaperPlane?
    var holographicImage: CGImage?
    var particleSource: CGImage?
    var fold: CGFloat = 0
    override func draw(in ctx: CGContext) {
        if let particleSource { ParticleRendering.departure(image: particleSource, in: ctx, size: bounds.size, progress: fold) }
        else if let holographicImage { Hologram.transmission(image: holographicImage, in: ctx, size: bounds.size, progress: fold) }
        else { plane?.draw(in: ctx, size: bounds.size, fold: fold) }
    }
}

/// A fold belongs to its clipping. Repeated pastes can update its destination
/// before launch; other clippings can fold at the same time without a queue.
@MainActor
final class InkFlights {
    private var panels: [InkFlight] = []
    var isVisible: Bool { panels.contains { $0.isVisible } }

    func cancelAll() { panels.forEach { $0.cancel() } }

    func play(itemID: UUID, image: CGImage, card: CGRect, tilt: Double, to end: CGPoint,
              speed: InkSpeed, sourceWindow: NSWindow, theme: LineTheme = .clothesline, onDepart: @escaping () -> Void) -> Bool {
        guard NSScreen.screens.contains(where: { $0.frame.contains(end) }) else { return false }
        if panels.contains(where: { $0.foldingID == itemID && $0.redirect(to: end, from: card) }) { return true }
        let panel: InkFlight
        if let idle = panels.first(where: { !$0.isPlaying }) {
            panel = idle
        } else if panels.count < 3 {
            panel = InkFlight()
            panels.append(panel)
        } else if let airborne = panels.first(where: { $0.foldingID == nil }) {
            panel = airborne  // oldest already clear of its pin
        } else {
            return false
        }
        let started = panel.play(image: image, card: card, tilt: tilt, to: end, speed: speed,
                                 sourceWindow: sourceWindow, itemID: itemID, theme: theme) { [weak self] in
            if self?.panels.contains(where: { $0.foldingID == itemID }) != true { onDepart() }
        }
        if started {
            panels.removeAll { $0 === panel }
            panels.append(panel)
        }
        return started
    }
}

/// A mouse-transparent, nonactivating panel follows the paper across displays.
/// Once folded, the same raster travels the whole arc without being redrawn.
@MainActor
final class InkFlight: NSPanel {
    private let paper = FoldingPaperLayer()
    private let transfer = ParticleTransferVisuals()
    private var timer: Timer?
    private var restoreSource: (() -> Void)?
    private var retarget: ((CGPoint, CGRect) -> Bool)?
    private(set) var foldingID: UUID?
    var isPlaying: Bool { timer != nil }

    fileprivate func redirect(to end: CGPoint, from card: CGRect) -> Bool {
        retarget?(end, card) ?? false
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSView()
        host.wantsLayer = true
        contentView = host
        host.layer?.addSublayer(paper)
        host.layer?.addSublayer(transfer.layer)
        paper.shadowColor = NSColor.black.cgColor
        paper.shadowOpacity = 0.22
        paper.shadowRadius = 2.5
        paper.shadowOffset = CGSize(width: 0, height: -2)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func play(image: CGImage, card: CGRect, tilt: Double, to end: CGPoint, speed: InkSpeed,
              sourceWindow: NSWindow? = nil, itemID: UUID? = nil, theme: LineTheme = .clothesline, onDepart: @escaping () -> Void) -> Bool {
        let start = CGPoint(x: card.midX, y: card.midY)
        let visibleCard = sourceWindow.map { $0.frame.intersection(card) } ?? card
        let screen = sourceWindow?.screen ?? NSScreen.screens.first { $0.frame.intersects(visibleCard) }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !visibleCard.isEmpty,
              let screen, screen.frame.intersects(visibleCard), let host = contentView else { return false }
        stop()
        if theme == .hologram {
            return playParticleTransfer(image: image, card: card, to: end, speed: speed,
                                        sourceWindow: sourceWindow, itemID: itemID, screen: screen,
                                        onDepart: onDepart)
        }
        foldingID = itemID
        restoreSource = onDepart
        var motion = InkFlightMotion(start: start, end: end, tilt: tilt, speed: speed, sourceScreen: screen.frame)
        let side = ceil(hypot(card.width, card.height)) + 16
        setContentSize(CGSize(width: side, height: side))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paper.bounds = CGRect(origin: .zero, size: card.size)
        paper.position = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        paper.contentsScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        paper.plane = PaperPlane(image: image, pointsLeft: motion.pointsLeft)
        paper.holographicImage = theme == .hologram ? image : nil
        paper.shadowColor = theme == .hologram ? Hologram.color.cgColor : NSColor.black.cgColor
        paper.shadowOpacity = theme == .hologram ? 0.38 : 0.22
        paper.fold = -1  // also redraw when a second flight replaces the first
        CATransaction.commit()

        let began = CACurrentMediaTime()
        let targetApp = NSWorkspace.shared.frontmostApplication
        retarget = { point, source in
            guard card == source, targetApp == NSWorkspace.shared.frontmostApplication,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  CACurrentMediaTime() - began < speed.timing.fold + speed.timing.hold else { return false }
            motion = InkFlightMotion(start: start, end: point, tilt: tilt, speed: speed,
                                     sourceScreen: screen.frame, launchLeft: motion.pointsLeft)
            return true
        }
        func drawFrame(_ fraction: Double) {
            let state = motion.state(at: fraction)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if paper.fold != state.fold {
                paper.fold = state.fold
                paper.setNeedsDisplay()
            }
            paper.setAffineTransform(CGAffineTransform(rotationAngle: theme == .hologram ? -tilt * .pi / 180 * (1 - state.fold) : state.angle)
                .scaledBy(x: state.scale, y: state.scale * state.bankScale))
            paper.opacity = Float(state.opacity)
            CATransaction.commit()
            setFrameOrigin(CGPoint(x: state.center.x - frame.width / 2, y: state.center.y - frame.height / 2))
            if state.sourceReleased, restoreSource != nil {
                // The original can reappear under the glider as it clears the pin.
                level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
                orderFrontRegardless()
                releaseSource()
            }
        }
        drawFrame(0)
        if let sourceWindow {
            // Let the actual wooden peg cover the folding copy of its clipping.
            level = sourceWindow.level
            order(.below, relativeTo: sourceWindow.windowNumber)
        } else {
            level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            orderFrontRegardless()
        }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                let fraction = (CACurrentMediaTime() - began) / speed.duration
                guard fraction < 1, targetApp == NSWorkspace.shared.frontmostApplication,
                      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { stop(); return }
                drawFrame(fraction)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    private func playParticleTransfer(image: CGImage, card: CGRect, to end: CGPoint, speed: InkSpeed,
                                      sourceWindow: NSWindow?, itemID: UUID?, screen: NSScreen,
                                      onDepart: @escaping () -> Void) -> Bool {
        foldingID = itemID
        restoreSource = onDepart
        var destination = end
        var motion = ParticleTransferMotion(card: card, destination: end, sourceScreen: screen.frame,
                                            destinationScreen: NSScreen.screens.first { $0.frame.contains(end) }?.frame)
        var previousMotion: ParticleTransferMotion?
        var redirectProgress: CGFloat = 0
        var renderBounds = motion.bounds
        let began = CACurrentMediaTime()
        let targetApp = NSWorkspace.shared.frontmostApplication
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        func placeSource() {
            setFrame(renderBounds, display: false)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            paper.bounds = CGRect(origin: .zero, size: card.size)
            paper.position = CGPoint(x: card.midX - renderBounds.minX, y: card.midY - renderBounds.minY)
            paper.setAffineTransform(.identity)
            paper.contentsScale = scale
            paper.shadowColor = Hologram.color.cgColor
            paper.shadowOpacity = 0.20
            paper.opacity = 1
            CATransaction.commit()
        }
        paper.particleSource = image
        paper.plane = nil
        paper.holographicImage = nil
        paper.fold = -1
        placeSource()
        func drawFrame(_ fraction: CGFloat) {
            var state = motion.frame(at: fraction)
            if let previousMotion {
                let blend = Hologram.ease((fraction - redirectProgress) / 0.10)
                let before = previousMotion.frame(at: fraction)
                func point(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                    CGPoint(x: a.x + (b.x - a.x) * blend, y: a.y + (b.y - a.y) * blend)
                }
                let particles = zip(before.particles, state.particles).map { a, b in
                    ParticleTransferMotion.Particle(position: point(a.position, b.position), tail: point(a.tail, b.tail),
                                                    opacity: b.opacity, radius: b.radius, warm: b.warm)
                }
                state = ParticleTransferMotion.Frame(particles: particles, sourceProgress: state.sourceProgress,
                                                     sourceReleased: state.sourceReleased, arrival: state.arrival,
                                                     opacity: state.opacity, landing: state.landing)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if paper.fold != state.sourceProgress {
                paper.fold = state.sourceProgress
                paper.setNeedsDisplay()
            }
            paper.opacity = Float(state.opacity)
            transfer.update(state, bounds: renderBounds, destination: destination, scale: scale)
            CATransaction.commit()
            if state.sourceReleased, restoreSource != nil {
                level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
                orderFrontRegardless()
                releaseSource()
            }
        }
        retarget = { point, source in
            let fraction = (CACurrentMediaTime() - began) / speed.particleDuration
            guard source == card, fraction < 0.30, targetApp == NSWorkspace.shared.frontmostApplication,
                  previousMotion == nil || fraction >= redirectProgress + 0.10,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
            destination = point
            previousMotion = motion
            redirectProgress = fraction
            motion = ParticleTransferMotion(card: card, destination: point, sourceScreen: screen.frame,
                                             destinationScreen: NSScreen.screens.first { $0.frame.contains(point) }?.frame)
            renderBounds = renderBounds.union(motion.bounds)
            placeSource()
            drawFrame(fraction)
            return true
        }
        drawFrame(0)
        if let sourceWindow {
            level = sourceWindow.level
            order(.below, relativeTo: sourceWindow.windowNumber)
        } else { orderFrontRegardless() }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                let fraction = (CACurrentMediaTime() - began) / speed.particleDuration
                guard fraction < 1, targetApp == NSWorkspace.shared.frontmostApplication,
                      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { stop(); return }
                drawFrame(fraction)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    fileprivate func cancel() { stop() }

    private func releaseSource() {
        let release = restoreSource
        foldingID = nil
        restoreSource = nil
        retarget = nil
        release?()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
        releaseSource()
        paper.plane = nil
        paper.holographicImage = nil
        paper.particleSource = nil
        paper.contents = nil
        transfer.clear()
    }
}

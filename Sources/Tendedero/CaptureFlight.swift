import AppKit
import QuartzCore

/// Reads where on screen a screenshot was taken. macOS stores the captured
/// area on the file, in global points with the origin at the top left of
/// the main display. Returned in AppKit screen coordinates.
func captureRect(of url: URL) -> CGRect? {
    let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
    let data: Data? = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return nil }
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = Data(count: size)
        let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? buffer : nil
    }
    guard let data,
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [NSNumber],
          values.count == 4, let main = NSScreen.screens.first else { return nil }
    let x = CGFloat(truncating: values[0]), y = CGFloat(truncating: values[1])
    let w = CGFloat(truncating: values[2]), h = CGFloat(truncating: values[3])
    guard w > 2, h > 2 else { return nil }
    return CGRect(x: x, y: main.frame.maxY - y - h, width: w, height: h)
}

/// The capture lifting off the screen and flying up to the line. It turns
/// into the hanging card on the way: it shrinks, tilts into place and grows
/// its frame, so there is nothing left to change on landing. The particle
/// theme condenses fine lights outside the image; the clothesline adds a clip.
@MainActor
final class CaptureFlight {
    static let duration: CFTimeInterval = 0.65
    /// How high the gentle arc rises halfway, in points.
    private static let arc: CGFloat = 30

    private let window: NSWindow
    private let container = CALayer()
    private let glass = CALayer()
    private let edge = CAGradientLayer()
    private let edgeMask = CAShapeLayer()
    private let photo = CALayer()
    private let clip = CAGradientLayer()
    private let particleCore = CAShapeLayer()
    private let particleSoft = CAShapeLayer()

    private let from: CGRect
    private let to: CGRect
    private let tilt: CGFloat
    private let isPaper: Bool
    private let holographic = LineTheme.current == .hologram
    private var falling = false
    private var duration: CFTimeInterval = CaptureFlight.duration
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    private var completion: () -> Void = {}

    private static var current: [CaptureFlight] = []

    /// Captures flying to the line right now. Each one holds a large image,
    /// so in a burst of captures only a couple fly and the rest drop in.
    static var flightsInProgress: Int { current.filter { !$0.falling }.count }

    /// - Parameters:
    ///   - from: the captured area, in screen coordinates.
    ///   - to: the card's frame on the line, in screen coordinates, unrotated.
    ///   - tilt: the card's resting tilt in degrees, clockwise, as SwiftUI uses.
    static func fly(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, isPaper: Bool, on screen: NSScreen,
                    completion: @escaping () -> Void) {
        let flight = CaptureFlight(image: image, from: from, to: to, tilt: tilt, isPaper: isPaper, screen: screen)
        current.append(flight)
        flight.completion = { [weak flight] in
            completion()
            current.removeAll { $0 === flight }
        }
        flight.run()
    }

    /// A discarded card falling off the line, drawn over the whole screen so
    /// it is never cut by the line's strip.
    static func fall(image: CGImage, card: CGRect, tilt: CGFloat, isPaper: Bool, on screen: NSScreen) {
        let flight = CaptureFlight(image: image, from: card, to: card, tilt: tilt, isPaper: isPaper, screen: screen)
        flight.falling = true
        flight.duration = 0.55
        current.append(flight)
        flight.completion = { [weak flight] in current.removeAll { $0 === flight } }
        flight.run()
    }

    private init(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, isPaper: Bool, screen: NSScreen) {
        self.from = from
        self.to = to
        self.tilt = tilt
        self.isPaper = isPaper
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        window.contentView = host
        let scale = screen.backingScaleFactor

        container.anchorPoint = CGPoint(x: 0.5, y: 1)   // the card's top center
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.24
        container.shadowRadius = isPaper ? 2 : 10
        container.shadowOffset = CGSize(width: 0, height: isPaper ? -2 : -5)

        let particleBase = Hologram.color.blended(withFraction: 0.87, of: .black) ?? .black
        let particleWhite = Hologram.color.blended(withFraction: 0.72, of: .white) ?? .white
        glass.backgroundColor = holographic ? particleBase.withAlphaComponent(0.48).cgColor : NSColor(white: 0.97, alpha: 0.72).cgColor
        edge.colors = [NSColor(white: 1, alpha: 0.9).cgColor, NSColor(white: 1, alpha: 0.25).cgColor]
        if holographic { edge.colors = [particleWhite.withAlphaComponent(0.55).cgColor, Hologram.color.withAlphaComponent(0.12).cgColor] }
        edge.startPoint = CGPoint(x: 0.5, y: 1); edge.endPoint = CGPoint(x: 0.5, y: 0)
        edgeMask.fillColor = nil
        edgeMask.strokeColor = NSColor.black.cgColor
        edgeMask.lineWidth = holographic ? 0.75 : 1.5
        edge.mask = edgeMask

        photo.contents = image
        photo.contentsGravity = .resizeAspectFill
        photo.masksToBounds = true
        photo.contentsScale = scale

        clip.colors = [NSColor(white: 0.70, alpha: 1).cgColor, NSColor(white: 0.93, alpha: 1).cgColor,
                       NSColor(white: 0.82, alpha: 1).cgColor, NSColor(white: 0.62, alpha: 1).cgColor]
        clip.locations = [0, 0.35, 0.65, 1]
        if isPaper { clip.colors = Clothespin.woodColors.map(\.cgColor) }
        clip.startPoint = CGPoint(x: 0, y: 0.5); clip.endPoint = CGPoint(x: 1, y: 0.5)
        clip.cornerRadius = 3.5
        clip.borderColor = NSColor(white: 1, alpha: 0.7).cgColor
        clip.borderWidth = 0.6

        for layer in [container, glass, edge, photo, clip, particleCore, particleSoft] as [CALayer] { layer.contentsScale = scale }
        if !isPaper { container.addSublayer(glass) }
        container.addSublayer(photo)
        if !isPaper { container.addSublayer(edge) }
        if holographic {
            particleSoft.fillColor = Hologram.color.withAlphaComponent(0.65).cgColor
            particleCore.fillColor = particleWhite.cgColor
            particleCore.shadowColor = Hologram.color.cgColor
            particleCore.shadowOpacity = 0.35
            particleCore.shadowRadius = 2.5
            particleCore.shadowOffset = .zero
            container.addSublayer(particleSoft)
            container.addSublayer(particleCore)
        } else {
            container.addSublayer(clip)
        }
        host.layer?.addSublayer(container)
    }

    private func run() {
        if falling { update(1); updateFall(0) } else { update(0) }
        window.orderFrontRegardless()
        start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let k = min(1, (CACurrentMediaTime() - start) / duration)
        if falling { updateFall(k) } else { update(k) }
        guard k >= 1 else { return }
        timer?.invalidate()
        timer = nil
        completion()
        if falling {
            window.orderOut(nil)
            return
        }
        // The real card fades in underneath; this one fades out over it.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    private func updateFall(_ raw: Double) {
        let e = CGFloat(raw * raw * raw)
        let origin = window.frame.origin
        let angle = tilt + (tilt * 7 + 20) * e
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: to.midX - origin.x, y: to.maxY - origin.y - 520 * e)
        container.setAffineTransform(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        container.opacity = Float(1 - e)
        CATransaction.commit()
    }

    private static func easeInOutCubic(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private func update(_ raw: Double) {
        let k = CGFloat(Self.easeInOutCubic(raw))
        let chrome = Float(Self.smooth(Double(k), 0.35, 1))
        let origin = window.frame.origin
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }

        let w = lerp(from.width, to.width), h = lerp(from.height, to.height)
        let topX = lerp(from.midX, to.midX) - origin.x
        let topY = lerp(from.maxY, to.maxY) - origin.y + sin(.pi * k) * Self.arc
        let inset = isPaper ? 0 : Frame.inset * k
        let radius = lerp(0, isPaper ? Frame.paperRadius : Frame.radius)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        container.position = CGPoint(x: topX, y: topY)
        // SwiftUI tilts clockwise for positive angles; Core Animation the other way.
        container.setAffineTransform(CGAffineTransform(rotationAngle: -tilt * .pi / 180 * k))
        container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        glass.frame = container.bounds
        glass.cornerRadius = radius
        glass.opacity = chrome
        edge.frame = container.bounds
        edgeMask.path = CGPath(roundedRect: container.bounds.insetBy(dx: 0.75, dy: 0.75),
                               cornerWidth: max(0, radius - 0.75), cornerHeight: max(0, radius - 0.75), transform: nil)
        edge.opacity = chrome
        photo.frame = container.bounds.insetBy(dx: inset, dy: inset)
        photo.cornerRadius = max(0, radius - inset)
        // The clip grips the top edge: 26 points tall, 12 of them over the card.
        clip.frame = CGRect(x: w / 2 - 4.5, y: h - 12, width: 9, height: 26)
        clip.opacity = holographic ? 0 : chrome
        if holographic { updateParticles(width: w, height: h, progress: raw) }
        CATransaction.commit()
    }

    /// Two small shape layers cover the whole effect. Fixed seeds keep the
    /// particles coherent between frames and away from text and photo details.
    private func updateParticles(width: CGFloat, height: CGFloat, progress: Double) {
        let launch = pow(sin(.pi * min(1, progress / 0.36)), 2) * 0.42
        let landing = pow(sin(.pi * Self.smooth(progress, 0.48, 1)), 2) * 0.76
        let intensity = Float(launch + landing)
        particleCore.frame = container.bounds
        particleSoft.frame = container.bounds
        particleCore.opacity = intensity
        particleSoft.opacity = intensity * 0.72
        guard intensity > 0.001 else { return }
        let core = CGMutablePath(), soft = CGMutablePath()
        for index in 0..<32 {
            let seed = Double((index * 17 + 7) % 31) / 31
            let along = (CGFloat(index / 4) + 0.24 + CGFloat(seed) * 0.46) / 8
            let convergence = CGFloat(Self.smooth(progress, 0.48 + seed * 0.08, 0.90 + seed * 0.10))
            let gap = 2.1 + (1 - convergence) * (5 + CGFloat(seed) * 11)
            let drift = sin(CGFloat(seed * 8 + progress * 4)) * (1 - convergence) * 2
            let point: CGPoint
            switch index % 4 {
            case 0: point = CGPoint(x: width * along + drift, y: height + gap)
            case 1: point = CGPoint(x: width + gap, y: height * along + drift)
            case 2: point = CGPoint(x: width * along + drift, y: -gap)
            default: point = CGPoint(x: -gap, y: height * along + drift)
            }
            let diameter = 0.65 + CGFloat(seed) * 0.85
            let bounds = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                width: diameter, height: diameter)
            if index % 3 == 0 { core.addEllipse(in: bounds) }
            else { soft.addEllipse(in: bounds) }
        }
        particleCore.path = core
        particleSoft.path = soft
    }
}

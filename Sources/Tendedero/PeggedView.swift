import SwiftUI

/// One photo with its clothespin. All the charm lives here: it drops onto
/// the line, swings, sways with the breeze and falls when you pull it off.
struct PeggedView: View {
    let item: Pegged
    @ObservedObject var line: Line
    let ropeDrop: CGFloat
    let tapAngle: Double
    let tapHighlight: Double
    var revealProgress: CGFloat = 1
    var scanCard: ParticleScanCard? = nil
    let onClick: (CGFloat) -> Void

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hovering = false
    @State private var particleArrival: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pulling: Bool { line.pull.id == item.id }
    private var folding: Bool { line.foldingIDs.contains(item.id) }
    private var pressed: Bool { line.pressedID == item.id }
    private var cardScale: CGFloat { pressed ? 0.95 : (hovering && !pulling ? 1.035 : 1) }
    private var emptyPin: Bool {
        guard case .removed? = line.feedback?.kind else { return false }
        return line.feedback?.itemID == item.id
    }

    var body: some View {
        VStack(spacing: -12) {
            Group {
                if line.theme == .hologram { Color.clear.frame(width: 9, height: 26) }
                else { Clothespin(wooden: item.isText) }
            }
                .offset(y: ropeDrop)
                .opacity(!item.falling || emptyPin ? 1 : 0)
                .zIndex(1)
            card
                .offset(y: ropeDrop)
                .opacity(item.falling ? 0 : 1)
                // The falling photo takes over in its own window. The empty
                // pin stays on the rope until the removal cue disappears.
                .transaction { if item.falling { $0.animation = nil } }
        }
        .rotationEffect(.degrees(line.theme == .hologram ? 0 : swing), anchor: .top)
        // The paper and pin sway, but two presses at the same spot must
        // keep hitting the same card. Only an actual pull moves its target.
        .overlay(alignment: .bottom) {
            let size = Self.cardSize(for: item)
            GrabArea(item: item, line: line, onClick: onClick)
                .frame(width: size.width, height: size.height)
                .onHover { hovering = $0 }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: HitRectsKey.self, value:
                            item.falling ? [:] : [item.id: geometry.frame(in: .global)])
                    }
                }
                .offset(y: line.pull.id == nil ? 0 : ropeDrop)
        }
        .rotationEffect(.degrees(line.theme == .hologram ? 0 : item.tilt), anchor: .top)
        .offset(y: line.theme == .hologram || arrived ? 0 : -46)
        .opacity(!item.flying && arrived ? 1 : 0)
        .allowsHitTesting(!item.falling)
        .animation(.easeOut(duration: 0.16), value: item.flying)
        .onAppear(perform: arrive)
        .onChange(of: item.flying) { was, now in if was && !now { land() } }
        .onChange(of: line.gust) { _, _ in breeze() }
        .onChange(of: pulling || folding) { _, detached in
            guard line.theme == .hologram, !item.falling else { return }
            if detached {
                particleArrival = reduceMotion ? 1 : 0.56
            } else {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { particleArrival = 1 }
            }
        }
    }

    /// The photo fits inside the card area keeping its proportions, so the
    /// white border hugs it whether the screenshot is wide or tall.
    static func photoSize(for size: CGSize) -> CGSize {
        let maxW = Layout.cardWidth - 14, maxH = Layout.photoMaxHeight
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The card around the photo: the photo plus the glass inset.
    static func cardSize(for item: Pegged) -> CGSize {
        let p = photoSize(for: item.thumb.size)
        if item.isText { return p }
        return CGSize(width: p.width + Frame.inset * 2, height: p.height + Frame.inset * 2)
    }

    /// Distance from the top of the hanging view (the clip) to the card.
    static let cardOffsetBelowTop: CGFloat = 26 - 12

    private var photoSize: CGSize { Self.photoSize(for: item.thumb.size) }

    private var thumbnail: some View {
        Image(nsImage: item.thumb)
            .resizable()
            .interpolation(.high)
            .frame(width: photoSize.width, height: photoSize.height)
    }

    @ViewBuilder private var surface: some View {
        if line.theme == .hologram {
            let size = Self.cardSize(for: item)
            thumbnail
                .clipShape(RoundedRectangle(cornerRadius: item.isText ? Frame.paperRadius : Frame.radius - Frame.inset))
                .padding(item.isText ? 0 : Frame.inset)
                .background(item.isText ? Color.clear : Hologram.ink.opacity(0.48), in: RoundedRectangle(cornerRadius: Frame.radius))
                .overlay {
                    HolographicCardEdge(active: hovering || pressed, pulse: tapHighlight)
                    if item.isRecording {
                        Image(systemName: "play.fill").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Hologram.white).padding(8)
                            .background(Hologram.ink.opacity(0.8), in: Circle())
                    }
                }
                .frame(width: size.width, height: size.height)
                .scaleEffect(cardScale, anchor: .bottom)
                .shadow(color: .black.opacity(0.19), radius: hovering ? 9 : 5, y: 3)
        } else if item.isText {
            thumbnail.clipShape(RoundedRectangle(cornerRadius: Frame.paperRadius))
                .scaleEffect(cardScale, anchor: .center)
                .shadow(color: .black.opacity(hovering ? 0.24 : 0.18), radius: hovering ? 4 : 2, y: 2)
        } else {
            PhotoCard(image: item.thumb, photoSize: photoSize, scale: cardScale, isRecording: item.isRecording)
                .shadow(color: .black.opacity(hovering ? 0.26 : 0.18), radius: hovering ? 14 : 10, y: hovering ? 8 : 5)
        }
    }

    private var card: some View {
        surface
            .overlay {
                if tapHighlight > 0 && line.theme != .hologram {
                    RoundedRectangle(cornerRadius: item.isText ? Frame.paperRadius : Frame.radius, style: .continuous)
                        .strokeBorder(.primary.opacity(tapHighlight), lineWidth: 1.5)
                        .scaleEffect(cardScale, anchor: .center)
                }
            }
            // Animate the surface's centered resize while the original slot
            // and its native click target stay fixed.
            .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .rotationEffect(.degrees(tapAngle), anchor: .top)
            .opacity(pulling || folding ? 0 : 1)
            .animation(folding ? nil : .easeOut(duration: 0.14), value: folding)
            .transaction { if pulling { $0.animation = nil } }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .modifier(ParticleAppearance(progress: line.theme == .hologram ? revealProgress : 1,
                                         seed: ParticleMotion.seed(item.url.lastPathComponent),
                                         enabled: line.theme == .hologram,
                                         arrivalProgress: particleArrival, scan: scanCard))
            // The stable GrabArea above is the only mouse responder for
            // both photos and paper; the moving artwork never steals a tap.
            .allowsHitTesting(false)
    }

    private func arrive() {
        // A capture that flew in is already in place; the flight did the arriving.
        if item.flying {
            arrived = true
            particleArrival = 1
            return
        }
        if line.theme == .hologram {
            arrived = true
            withAnimation(reduceMotion ? nil : .easeOut(duration: ParticleMotion.arrivalDuration)) { particleArrival = 1 }
            return
        }
        particleArrival = 1
        swing = 16
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
    }

    /// Landing after the flight: no jump, just a small sway from rest.
    private func land() {
        guard line.theme != .hologram else { return }
        nudge(2.2)
    }

    private func breeze() {
        guard line.theme != .hologram else { return }
        let delay = Double.random(in: 0...0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            nudge(Double.random(in: 1.6...3.4))
        }
    }

    private func nudge(_ degrees: Double) {
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }
}

/// Use layout sizes for both the image and its glass. Scaling a rendered
/// glass effect can resize only the extracted material, leaving the image
/// at its original size. The outer slot keeps the peg and hit target still.
struct PhotoCard: View {
    let image: NSImage
    let photoSize: CGSize
    let scale: CGFloat
    let isRecording: Bool

    var body: some View {
        surface
            .overlay {
                if isRecording {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11 * scale, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 28 * scale, height: 28 * scale)
                        .glassFrame(circle: true)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: photoSize.width + Frame.inset * 2,
                   height: photoSize.height + Frame.inset * 2, alignment: .center)
    }

    @ViewBuilder private var surface: some View {
        if #available(macOS 26.0, *) {
            PhotoGlass(image: image, inset: Frame.inset * scale, radius: Frame.radius * scale)
                .frame(width: (photoSize.width + Frame.inset * 2) * scale,
                       height: (photoSize.height + Frame.inset * 2) * scale)
        } else {
            frostedPhoto
        }
    }

    private var frostedPhoto: some View {
        let innerRadius = (Frame.radius - Frame.inset) * scale
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: photoSize.width * scale, height: photoSize.height * scale)
            .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .padding(Frame.inset * scale)
            .glassFrame(cornerRadius: Frame.radius * scale)
    }
}

enum Frame {
    static let paperRadius: CGFloat = 1.5
    static let radius: CGFloat = 16
    static let inset: CGFloat = 4
}

extension View {
    /// A crisp glass: the system's blurred material with a thin specular
    /// edge, lit from above. No refraction, so the background stays sharp
    /// around the frame instead of bending like gel.
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
    }
}

/// Maple for paper, brushed metal for photos and recordings.
struct Clothespin: View {
    var wooden = false
    static let woodColors = [
        NSColor(srgbRed: 0.61, green: 0.40, blue: 0.23, alpha: 1),
        NSColor(srgbRed: 0.92, green: 0.78, blue: 0.59, alpha: 1),
        NSColor(srgbRed: 0.81, green: 0.64, blue: 0.45, alpha: 1),
        NSColor(srgbRed: 0.68, green: 0.49, blue: 0.31, alpha: 1)
    ]
    private let wood = LinearGradient(colors: woodColors.map(Color.init(nsColor:)),
                                      startPoint: .leading, endPoint: .trailing)
    private let metal = LinearGradient(
        stops: [
            .init(color: Color(white: 0.70), location: 0),
            .init(color: Color(white: 0.93), location: 0.35),
            .init(color: Color(white: 0.82), location: 0.65),
            .init(color: Color(white: 0.62), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(wooden ? wood : metal)
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                // The slot the line passes through.
                Capsule()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 5, height: 1.4)
                    .padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .allowsHitTesting(false)
    }
}

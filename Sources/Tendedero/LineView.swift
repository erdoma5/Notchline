import SwiftUI

enum Layout {
    /// How big the photos hang, from Size in the menu bar. The clip, the rope
    /// and the glass frame keep their size; the photos and the room they take
    /// grow or shrink. Medium is the original size.
    enum Size: String, CaseIterable {
        case small, medium, large

        var scale: CGFloat {
            switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.35
            }
        }
    }

    static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: "lineSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lineSize") }
    }

    static var photoMaxHeight: CGFloat { (104 * size.scale).rounded() }
    static var cardWidth: CGFloat { (150 * size.scale).rounded() }
    static var spacing: CGFloat { cardWidth + 24 }
    static var panelHeight: CGFloat { photoMaxHeight + 106 }
    static let ropeTop: CGFloat = 10
    static let pinAbove: CGFloat = 9.5
    /// A straight, shared lower edge, independent of card height and screen x.
    static var particleBaseline: CGFloat { photoMaxHeight + 46 }

    static func cardRect(centerX: CGFloat, size: CGSize, width: CGFloat,
                         theme: LineTheme, drop: CGFloat = 0) -> CGRect {
        let top = theme == .hologram ? particleBaseline - size.height
            : ropeY(x: centerX, width: width) - pinAbove + PeggedView.cardOffsetBelowTop + drop
        return CGRect(x: centerX - size.width / 2, y: top, width: size.width, height: size.height)
    }

    static func particleShelfRect(cards: [CGRect], width: CGFloat) -> CGRect {
        let visible = cards.filter { $0.maxX > 0 && $0.minX < width }
        let left = max(8, (visible.map(\.minX).min() ?? width / 2 - 160) - 22)
        let right = min(width - 8, (visible.map(\.maxX).max() ?? width / 2 + 160) + 22)
        return CGRect(x: left, y: particleBaseline - 7, width: max(0, right - left), height: 16)
    }

    /// AppKit screen coordinates. A card docks by its lower edge, as shown by
    /// the recessed slot, rather than by crossing the old curved rope.
    static func touchesDock(_ card: CGRect, in panel: CGRect, theme: LineTheme, shelf: CGRect) -> Bool {
        guard theme == .hologram else { return touchesRope(card, in: panel) }
        guard panel.width > 0, shelf.width > 0,
              card.maxX >= panel.minX + shelf.minX, card.minX <= panel.minX + shelf.maxX else { return false }
        return abs(card.minY - (panel.maxY - particleBaseline)) <= 14
    }

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = min(1, max(0, x / width))
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// Both rectangles are in AppKit screen coordinates. Over the part of
    /// the rope covered by the card, its highest point is at one of the
    /// ends and its lowest point is the one nearest the middle of the line.
    static func touchesRope(_ card: CGRect, in panel: CGRect) -> Bool {
        let left = max(0, card.minX - panel.minX)
        let right = min(panel.width, card.maxX - panel.minX)
        guard panel.width > 0, left <= right else { return false }

        let middle = min(right, max(left, panel.width / 2))
        let highest = min(ropeY(x: left, width: panel.width), ropeY(x: right, width: panel.width))
        let lowest = ropeY(x: middle, width: panel.width)
        let allowance: CGFloat = 14
        return card.maxY >= panel.maxY - lowest - allowance
            && card.minY <= panel.maxY - highest + allowance
    }

    /// Center the full cards. On a long line, scroll moves older cards in
    /// from the left, with one partially visible neighbour beyond each end.
    static func x(index: Int, count: Int, width: CGFloat, visible: Int, scroll: CGFloat, itemWidth: CGFloat) -> CGFloat {
        if count > visible {
            let last = CGFloat(visible - 1)
            let slot = CGFloat(index - (count - visible)) + scroll / spacing
            let step = min(spacing, width / CGFloat(visible + 1))
            let firstX = (width - last * step) / 2
            // The next real card crosses the window edge. Even a narrow
            // portrait shows a sliver at either end of a full row.
            let peek = min(18, itemWidth / 3)
            let endStep = firstX + itemWidth / 2 - peek
            if slot < 0 { return firstX + slot * endStep }
            if slot > last { return width - firstX + (slot - last) * endStep }
            return firstX + slot * step
        }
        let gaps = CGFloat(max(count - 1, 0))
        let step = gaps > 0 ? min(spacing, max(0, width - 200) / gaps) : spacing
        return width / 2 - gaps * step / 2 + CGFloat(index) * step
    }
}

/// Every point along the rope plays the same tap, after its travel time.
private struct TapWave {
    static let secondsPerGap = 0.07
    static let pulse = KeyframeTimeline(initialValue: 0.0) {
        CubicKeyframe(1, duration: 0.075)
        CubicKeyframe(-0.34, duration: 0.14)
        CubicKeyframe(0.09, duration: 0.12)
        CubicKeyframe(0, duration: 0.11)
    }

    let origin: CGFloat
    let width: CGFloat
    let spacing: CGFloat
    let elapsed: TimeInterval

    func sample(at x: CGFloat) -> (swing: Double, drop: CGFloat) {
        let distance = abs(x - origin) / spacing
        let time = elapsed - distance * Self.secondsPerGap
        guard time > 0, time < Self.pulse.duration else { return (0, 0) }
        let swing = Self.pulse.value(time: time) * exp(-0.6 * distance)
        // Taper the vertical motion at the two fixed ends.
        let endWeight = min(1, max(0, min(x, width - x) / (spacing / 2)))
        return (swing, 4 * swing * endWeight)
    }
}

struct LineView: View {
    @ObservedObject var line: Line
    /// Deterministic native previews can supply a presentation frame directly.
    /// Runtime callers leave this nil and follow the observed reveal state.
    var presentationProgress: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tap: Tap?
    @State private var hologramProgress: CGFloat = 0
    private var revealAmount: CGFloat { presentationProgress ?? hologramProgress }

    private struct Tap {
        let id = UUID()
        let itemID: UUID
        let anchor: CGFloat
        let offsetFromPeg: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let anchor = tap?.anchor ?? 0.5
            let travel = max(anchor, 1 - anchor) * width / Layout.spacing * TapWave.secondsPerGap
            let duration = TapWave.pulse.duration + (reduceMotion ? 0 : travel)
            ZStack(alignment: .topLeading) {
                KeyframeAnimator(initialValue: 0.0, trigger: tap?.id) { elapsed in
                    hangingItems(width: width, elapsed: elapsed)
                } keyframes: { _ in
                    MoveKeyframe(0)
                    LinearKeyframe(duration, duration: duration)
                    MoveKeyframe(0)
                }

                if line.items.isEmpty && line.feedback == nil {
                    Hint()
                        .position(x: width / 2, y: line.theme == .hologram ? Layout.particleBaseline - 30 : Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                        .opacity(line.theme == .hologram ? ParticleMotion.phase(revealAmount, 0.78, 0.94) : 1)
                }

                if let cue = cue(width: width) {
                    LineCue(text: cue.text, icon: cue.icon)
                        .visualEffect { content, geometry in
                            let size = geometry.size
                            let left = max(6, min(cue.x - size.width / 2, width - size.width - 6))
                            return content.offset(x: left, y: cue.y - size.height / 2)
                        }
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .opacity(line.theme == .hologram ? revealAmount : 1)
                }
            }
            // Direct manipulation has no lag; only the release is animated.
            .animation(line.pull.id == nil && !reduceMotion ? .spring(response: 0.33, dampingFraction: 0.66) : nil,
                       value: line.pull.id)
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.61), value: line.pull.armed)
            .animation(.easeOut(duration: 0.16), value: line.feedback?.id)
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.theme == .hologram || line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.theme == .hologram ? nil : (line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22)), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
        .onAppear { updateHologram(animated: line.revealed) }
        .onChange(of: line.revealed) { _, _ in updateHologram(animated: true) }
        .onChange(of: line.theme) { _, _ in tap = nil; updateHologram(animated: true) }
    }

    private func updateHologram(animated: Bool) {
        withAnimation(animated && !reduceMotion ? .linear(duration: line.revealed ? ParticleMotion.revealDuration : ParticleMotion.dismissDuration) : nil) {
            hologramProgress = line.revealed ? 1 : 0
        }
    }

    private func fieldRect(width: CGFloat) -> CGRect {
        let bounds = line.cardRects(width: width).filter { $0.maxX > 0 && $0.minX < width }
        let left = max(12, (bounds.map(\.minX).min() ?? width / 2 - 190) - 22)
        let right = min(width - 12, (bounds.map(\.maxX).max() ?? width / 2 + 190) + 22)
        let bottom = min(Layout.panelHeight - 9, (bounds.map(\.maxY).max() ?? 90) + 34)
        return CGRect(x: left, y: 3, width: max(1, right - left), height: max(90, bottom - 3))
    }

    private func hangingItems(width: CGFloat, elapsed: TimeInterval) -> some View {
        let wave = elapsed > 0 && !reduceMotion && line.pull.id == nil ? tap.map {
            TapWave(origin: $0.anchor * width, width: width, spacing: Layout.spacing, elapsed: elapsed)
        } : nil
        let highlight = reduceMotion ? 0.5 * max(0, TapWave.pulse.value(time: elapsed)) : 0
        let cards = line.cardRects(width: width)
        let shelf = Layout.particleShelfRect(cards: cards, width: width)
        let supported = line.items.indices.compactMap { index -> CGRect? in
            let item = line.items[index]
            return item.falling || item.id == line.pull.id ? nil : cards[index]
        }
        return ZStack(alignment: .topLeading) {
            if line.theme == .hologram {
                ParticleField(progress: revealAmount, field: fieldRect(width: width),
                                  pulseX: tap.map { $0.anchor * width }, pulse: TapWave.pulse.value(time: elapsed))
                ParticleShelf(progress: revealAmount, frame: shelf, cards: supported, pull: line.pull)
                ParticleScanLight(progress: revealAmount, span: shelf, shelf: shelf, cards: supported)
            } else {
                Rope(pull: line.pull, wave: wave)
            }
            ForEach(Array(line.items.enumerated()), id: \.element.id) { index, item in
                let x = line.centerX(at: index, width: width)
                let ropeY = Layout.ropeY(x: x, width: width)
                let top = cards[index].minY - PeggedView.cardOffsetBelowTop
                let slotHeight = line.theme == .hologram ? Layout.panelHeight - top : Layout.panelHeight - ropeY
                let sample = wave?.sample(at: x)
                let angle = 4.5 * (tap?.offsetFromPeg ?? 0) * (sample?.swing ?? 0)
                PeggedView(item: item, line: line, ropeDrop: line.theme == .hologram ? 0 : (sample?.drop ?? line.pull.offset(at: x, width: width)),
                           tapAngle: line.theme == .hologram ? 0 : angle,
                           tapHighlight: tap?.itemID == item.id ? (line.theme == .hologram ? max(0, TapWave.pulse.value(time: elapsed)) : highlight) : 0,
                           revealProgress: x >= -Layout.cardWidth && x <= width + Layout.cardWidth ? revealAmount : 1,
                           scanCard: line.theme == .hologram ? ParticleScanCard(span: shelf, card: cards[index]) : nil) { offsetFromPeg in
                    tap = Tap(itemID: item.id, anchor: x / max(1, width), offsetFromPeg: offsetFromPeg)
                }
                .frame(width: Layout.cardWidth, height: slotHeight, alignment: .top)
                .position(x: x, y: top + slotHeight / 2)
            }
            if line.theme == .hologram {
                ParticleShelf(progress: revealAmount, frame: shelf, cards: supported, pull: line.pull, foreground: true)
                ParticleScanLight(progress: revealAmount, span: shelf, shelf: shelf, cards: supported, foreground: true)
            }
        }
    }

    private func cue(width: CGFloat) -> (text: String, icon: String, x: CGFloat, y: CGFloat)? {
        if reduceMotion, line.pull.id != nil {
            // An explicit cue when the recoil is switched off.
            let x = line.pull.anchor * width
            let y = line.theme == .hologram ? Layout.particleBaseline + 25 : Layout.ropeY(x: x, width: width) + line.pull.depth - 21
            return (line.pull.armed ? L("Release to take down") : L("Pull down to remove"),
                    line.pull.armed ? "arrow.down.to.line" : "arrow.down", x, max(15, y))
        }
        guard let note = line.feedback, note.showsCue else { return nil }
        switch note.kind {
        case .removed(let anchor):
            let x = anchor * width
            return (note.message, "checkmark", x, line.theme == .hologram ? Layout.particleBaseline + 25 : Layout.ropeY(x: x, width: width) + 28)
        case .copied, .pasteRequested, .clipboardChanged, .needsEditor, .needsAccessibility:
            guard let index = line.items.firstIndex(where: { $0.id == note.itemID && !$0.falling }) else { return nil }
            let x = line.centerX(at: index, width: width)
            let bottom = line.cardRects(width: width)[index].maxY
            let needsHelp = note.kind == .needsEditor || note.kind == .needsAccessibility || note.kind == .clipboardChanged
            return (note.message, needsHelp ? "info.circle" : "checkmark", x, bottom + (line.theme == .hologram ? 25 : 19))
        }
    }
}

private struct LineCue: View {
    let text: String
    let icon: String
    @AppStorage(LineTheme.preferenceKey) private var theme = LineTheme.clothesline.rawValue

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .feedbackGlass()
        .overlay(Capsule().strokeBorder(theme == LineTheme.hologram.rawValue ? Hologram.light.opacity(0.45) : .clear, lineWidth: 0.65))
    }
}

private struct Hint: View {
    @AppStorage(ClipboardWatcher.imagesEnabledKey) private var imagesEnabled = true
    @AppStorage(ClipboardWatcher.textEnabledKey) private var textEnabled = true

    private var message: String {
        switch (imagesEnabled, textEnabled) {
        case (true, true): L("Copy text or an image to hang it here")
        case (true, false): L("Copy an image to hang it here")
        case (false, true): L("Copy text to hang a clipping")
        case (false, false): L("Take a screenshot and it will hang here")
        }
    }

    var body: some View {
        Text(verbatim: message)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .feedbackGlass()
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
private struct RopeCurve: Shape {
    var pull: LinePull
    var wave: TapWave?

    var animatableData: CGFloat {
        get { pull.depth }
        set { pull.depth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let anchor = width * pull.anchor
        func y(_ x: CGFloat) -> CGFloat { Layout.ropeY(x: x, width: width) + pull.offset(at: x, width: width) }
        return Path { p in
            p.move(to: CGPoint(x: 0, y: y(0)))
            if let wave {
                for x in stride(from: CGFloat(16), to: width, by: 16) {
                    p.addLine(to: CGPoint(x: x, y: y(x) + wave.sample(at: x).drop))
                }
                p.addLine(to: CGPoint(x: width, y: y(width)))
                return
            }
            // The resting parabola plus a straight slope on either side of
            // the peg is exactly quadratic on each side of the join.
            for (left, right) in [(0, anchor), (anchor, width)] {
                let mid = (left + right) / 2
                p.addQuadCurve(to: CGPoint(x: right, y: y(right)),
                               control: CGPoint(x: mid, y: 2 * y(mid) - (y(left) + y(right)) / 2))
            }
        }
    }
}

private struct Rope: View {
    let pull: LinePull
    let wave: TapWave?
    private var path: RopeCurve { RopeCurve(pull: pull, wave: wave) }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

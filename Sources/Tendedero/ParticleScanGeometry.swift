import CoreGraphics

/// One clock drives the scanner fronts and the material exposed behind them.
/// Positions use the same fixed, top-left layout coordinates as the card slots.
struct ParticleScanGeometry {
    let span: CGRect

    struct Frame {
        let leftX: CGFloat
        let rightX: CGFloat
        let beamOpacity: CGFloat
        let mergeOpacity: CGFloat
        let projection: CGFloat
    }

    func frame(at raw: CGFloat) -> Frame {
        let p = raw.isFinite ? Hologram.unit(raw) : 0
        let travel = ParticleMotion.phase(p, 0.10, 0.78)
        let awake = ParticleMotion.phase(p, 0, 0.10)
        let settle = ParticleMotion.phase(p, 0.78, 1)
        let merge = sin(ParticleMotion.phase(p, 0.74, 1) * .pi)
        return Frame(leftX: span.minX + span.width * 0.5 * travel,
                     rightX: span.maxX - span.width * 0.5 * travel,
                     beamOpacity: p >= 1 ? 0 : awake * (1 - settle),
                     mergeOpacity: p <= 0 || p >= 1 ? 0 : max(0, merge),
                     projection: awake)
    }

    /// No image coverage ahead of either light front. A small feather and
    /// final central fusion finish the exact midpoint without a permanent seam.
    func coverage(at x: CGFloat, progress raw: CGFloat, frame prepared: Frame? = nil) -> CGFloat {
        let p = raw.isFinite ? Hologram.unit(raw) : 0
        guard p > 0 else { return 0 }
        if p >= 1 { return 1 }
        let state = prepared ?? frame(at: p)
        let passed = max(state.leftX - x, x - state.rightX)
        let feather = min(14, max(3, span.width * 0.045))
        let swept = ParticleMotion.phase(passed, 0, feather)
        return max(swept * state.projection, ParticleMotion.phase(p, 0.78, 0.91))
    }
}

struct ParticleScanCard {
    let span: CGRect
    let card: CGRect
}

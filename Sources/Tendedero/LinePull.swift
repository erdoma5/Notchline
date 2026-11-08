import Foundation

/// Screen coordinates stay valid when the pointer leaves the line's window.
struct PhotoGrab {
    let card: CGRect
    let pointer: CGPoint

    func frame(at point: CGPoint) -> CGRect {
        card.offsetBy(dx: point.x - pointer.x, dy: point.y - pointer.y)
    }
}

/// Only the rope yields. The loose photo always uses the full pointer displacement.
struct LinePull: Equatable {
    var id: UUID?
    var anchor: CGFloat = 0.5
    var depth: CGFloat = 0
    var armed = false

    mutating func track(down: CGFloat, sideways: CGFloat, touchingRope: Bool) {
        let distance = hypot(down, sideways)
        let clearOfPeg = distance >= (armed ? 32 : 42)
        armed = clearOfPeg && !touchingRope
        // Returning to a distant part of the rope does not load the original pin.
        depth = clearOfPeg ? 0 : max(0, down) * 0.58
    }

    mutating func release() {
        id = nil
        depth = 0
        armed = false
    }

    func offset(at x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let f = min(1, max(0, x / width))
        let a = min(0.999, max(0.001, anchor))
        return depth * (f <= a ? f / a : (1 - f) / (1 - a))
    }
}

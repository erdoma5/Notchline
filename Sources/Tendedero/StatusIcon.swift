import AppKit

/// A monochrome mark for the selected theme. Filled details indicate watching.
enum StatusIcon {
    static func image(clipboardEnabled: Bool, accessibilityDescription: String, theme: LineTheme = .clothesline) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            if theme == .hologram {
                let frame = NSBezierPath(roundedRect: NSRect(x: 6.1, y: 4, width: 8.4, height: 10), xRadius: 1.4, yRadius: 1.4)
                frame.lineWidth = 1
                frame.stroke()
                let lines = NSBezierPath()
                lines.move(to: NSPoint(x: 8.2, y: 10.7)); lines.line(to: NSPoint(x: 12.3, y: 10.7))
                lines.move(to: NSPoint(x: 8.2, y: 7.8)); lines.line(to: NSPoint(x: 11.1, y: 7.8))
                lines.lineWidth = 0.75; lines.lineCapStyle = .round; lines.stroke()
                let motes: [(CGFloat, CGFloat, CGFloat)] = [
                    (2.3, 8.9, 1.6), (4.1, 14.7, 1.3), (10.4, 16.0, 1.0),
                    (16.3, 12.7, 1.6), (17.2, 6.3, 1.1), (12.5, 1.3, 1.4), (4.1, 2.6, 1.0)
                ]
                for (x, y, diameter) in motes {
                    let mote = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter))
                    if clipboardEnabled { NSColor.black.setFill(); mote.fill() }
                    else { mote.lineWidth = 0.55; mote.stroke() }
                }
                return true
            }

            let frame = NSBezierPath(roundedRect: NSRect(x: 4.6, y: 1.4, width: 10.8, height: 10.4),
                                     xRadius: 1.5, yRadius: 1.5)
            frame.lineWidth = 1.2
            frame.stroke()

            let mountains = NSBezierPath()
            mountains.move(to: NSPoint(x: 5.8, y: 3.0))
            mountains.line(to: NSPoint(x: 8.6, y: 6.5))
            mountains.line(to: NSPoint(x: 10.4, y: 4.5))
            mountains.line(to: NSPoint(x: 12.1, y: 6.0))
            mountains.line(to: NSPoint(x: 14.2, y: 3.0))
            mountains.close()
            NSColor.black.setFill()
            mountains.fill()
            NSBezierPath(ovalIn: NSRect(x: 12.5, y: 8.2, width: 1.3, height: 1.3)).fill()

            let rope = NSBezierPath()
            rope.move(to: NSPoint(x: 1.2, y: 14.5))
            rope.curve(to: NSPoint(x: 18.8, y: 14.5),
                       controlPoint1: NSPoint(x: 7, y: 12.4),
                       controlPoint2: NSPoint(x: 13, y: 12.4))
            rope.lineWidth = 1.4
            rope.lineCapStyle = .round
            rope.stroke()

            for x in [6.3, 12.1] {
                let peg = NSBezierPath(roundedRect: NSRect(x: x, y: 10.4, width: 1.7, height: 4.1),
                                       xRadius: 0.6, yRadius: 0.6)
                if clipboardEnabled {
                    NSColor.black.setFill()
                    peg.fill()
                } else {
                    peg.lineWidth = 0.75
                    peg.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}

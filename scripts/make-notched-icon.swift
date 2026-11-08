import AppKit
import CoreGraphics

let output = CommandLine.arguments[1]
let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon bitmap") }

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let ctx = graphics.cgContext
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// A dark, calm tile leaves the bright line legible even at Dock size.
let tile = rounded(CGRect(x: 48, y: 48, width: 928, height: 928), 205)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 36,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
ctx.addPath(tile)
ctx.setFillColor(color(0x102532))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [color(0x102532), color(0x20515E)] as CFArray,
                            locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 975),
                       end: CGPoint(x: 512, y: 48), options: [])

// The camera notch is cut from the tile's top edge.
let notch = CGMutablePath()
notch.move(to: CGPoint(x: 384, y: 1024))
notch.addLine(to: CGPoint(x: 640, y: 1024))
notch.addLine(to: CGPoint(x: 640, y: 863))
notch.addQuadCurve(to: CGPoint(x: 580, y: 803), control: CGPoint(x: 640, y: 803))
notch.addLine(to: CGPoint(x: 444, y: 803))
notch.addQuadCurve(to: CGPoint(x: 384, y: 863), control: CGPoint(x: 384, y: 803))
notch.closeSubpath()
ctx.addPath(notch)
ctx.setFillColor(color(0x07171F))
ctx.fillPath()

// One card is enough to read as a screenshot at small sizes.
let card = CGRect(x: 293, y: 240, width: 438, height: 420)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 24,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.26))
ctx.addPath(rounded(card, 58))
ctx.setFillColor(color(0xF6F1E5))
ctx.fillPath()
ctx.restoreGState()

let picture = rounded(CGRect(x: 325, y: 272, width: 374, height: 352), 30)
ctx.saveGState()
ctx.addPath(picture)
ctx.clip()
let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                     colors: [color(0x5DC7C4), color(0xBDE9D4)] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 624),
                       end: CGPoint(x: 512, y: 272), options: [])

ctx.addEllipse(in: CGRect(x: 552, y: 478, width: 92, height: 92))
ctx.setFillColor(color(0xFFD98D))
ctx.fillPath()

let ridge = CGMutablePath()
ridge.move(to: CGPoint(x: 325, y: 345))
ridge.addLine(to: CGPoint(x: 438, y: 505))
ridge.addLine(to: CGPoint(x: 520, y: 409))
ridge.addLine(to: CGPoint(x: 584, y: 465))
ridge.addLine(to: CGPoint(x: 699, y: 320))
ridge.addLine(to: CGPoint(x: 699, y: 272))
ridge.addLine(to: CGPoint(x: 325, y: 272))
ridge.closeSubpath()
ctx.addPath(ridge)
ctx.setFillColor(color(0x286D73))
ctx.fillPath()

let foreground = CGMutablePath()
foreground.move(to: CGPoint(x: 325, y: 328))
foreground.addCurve(to: CGPoint(x: 699, y: 333),
                    control1: CGPoint(x: 435, y: 385), control2: CGPoint(x: 572, y: 266))
foreground.addLine(to: CGPoint(x: 699, y: 272))
foreground.addLine(to: CGPoint(x: 325, y: 272))
foreground.closeSubpath()
ctx.addPath(foreground)
ctx.setFillColor(color(0x123E4B))
ctx.fillPath()
ctx.restoreGState()

let line = CGMutablePath()
line.move(to: CGPoint(x: 148, y: 725))
line.addCurve(to: CGPoint(x: 876, y: 725),
              control1: CGPoint(x: 388, y: 677), control2: CGPoint(x: 636, y: 677))
ctx.addPath(line)
ctx.setStrokeColor(color(0x78E6D5))
ctx.setLineWidth(22)
ctx.setLineCap(.round)
ctx.strokePath()

for x in [394.0, 588.0] {
    let peg = CGRect(x: x, y: 636, width: 42, height: 101)
    ctx.addPath(rounded(peg, 17))
    ctx.setFillColor(color(0xFFB977))
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: x + 15, y: 702, width: 12, height: 12))
    ctx.setFillColor(color(0x9E5A3F))
    ctx.fillPath()
}
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
try data.write(to: URL(fileURLWithPath: output))

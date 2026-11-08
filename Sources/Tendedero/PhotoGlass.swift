import AppKit
import SwiftUI

/// Keep the image inside AppKit's glass content view, so the two are one
/// surface when SwiftUI rotates the card. No shared glass container can
/// reorder this surface above its clothespin.
@available(macOS 26.0, *)
struct PhotoGlass: NSViewRepresentable {
    let image: NSImage
    let inset: CGFloat
    let radius: CGFloat

    func makeNSView(context: Context) -> PhotoGlassView {
        let view = PhotoGlassView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PhotoGlassView, context: Context) {
        view.photo.image = image
        view.inset = inset
        view.cornerRadius = radius
        view.photo.layer?.cornerRadius = max(0, radius - inset)
        view.needsLayout = true
    }
}

@available(macOS 26.0, *)
final class PhotoGlassView: NSGlassEffectView {
    let photo = NSImageView()
    private let imageContent = NSView()
    var inset: CGFloat = 0

    init() {
        super.init(frame: .zero)
        style = .regular
        imageContent.autoresizingMask = [.width, .height]
        contentView = imageContent
        photo.imageScaling = .scaleAxesIndependently
        photo.wantsLayer = true
        photo.layer?.masksToBounds = true
        photo.layer?.borderWidth = 0.5
        photo.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        imageContent.addSubview(photo)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        imageContent.frame = bounds
        photo.frame = imageContent.bounds.insetBy(dx: inset, dy: inset)
    }

    // Both image and paper route every gesture through the stable GrabView.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

import CoreGraphics
import ApplicationServices

extension AXUIElement {
    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func element(_ name: String) -> AXUIElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

private extension PasteFocus.Attributes {
    func axValue(_ name: String) -> AXValue? {
        guard let value = values[name], CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    var bounds: CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        guard let p = axValue(kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &position),
              let s = axValue(kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}

/// AX uses top-left global points. AppKit uses the bottom-left of the primary
/// display, including when other displays are to the left or above it.
struct InkLanding {
    var caret, field, window: CGRect?

    func point(on screens: [CGRect]) -> CGPoint? {
        guard let primary = screens.first else { return nil }
        func appKit(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: primary.maxY - r.maxY, width: r.width, height: r.height)
        }
        let window = window.flatMap { Self.valid($0) && !$0.isEmpty ? $0 : nil }
        let editor = field.flatMap { rect -> CGRect? in
            guard Self.valid(rect), !rect.isEmpty else { return nil }
            return window.map { rect.intersection($0) } ?? rect
        }
        if let editor, editor.isEmpty || editor.isNull { return nil }
        if let caret, Self.isCaret(caret) {
            let point = CGPoint(x: caret.midX, y: primary.maxY - caret.midY)
            // A zero-size insertion point can be meaningful inside a known
            // field. With no geometry to corroborate it, require line height.
            let bounds = editor ?? window
            if (bounds.map { appKit($0).insetBy(dx: -1, dy: -1).contains(point) } ?? (caret.height > 0)),
               screens.contains(where: { $0.contains(point) }) { return point }
        }
        guard let editor else { return nil }
        let visible = screens.map { appKit(editor).intersection($0) }.filter { !$0.isNull && $0.width >= 4 && $0.height >= 4 }
        return visible.max { $0.width * $0.height < $1.width * $1.height }
            .map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private static func valid(_ r: CGRect) -> Bool {
        !r.isInfinite && r.origin.x.isFinite && r.origin.y.isFinite && r.size.width.isFinite &&
            r.size.height.isFinite && r.size.width >= 0 && r.size.height >= 0
    }

    private static func isCaret(_ r: CGRect) -> Bool {
        r != .zero && valid(r) && (0...120).contains(r.height) && r.width <= max(1, r.height)
    }

    static func read(field: AXUIElement, window: AXUIElement?, editor verifiedEditor: AXUIElement? = nil) -> InkLanding {
        let reader = PasteFocus.Reader()
        let geometryNames = [kAXPositionAttribute, kAXSizeAttribute]
        let fieldNames = geometryNames + [kAXRoleAttribute, "AXEditable", kAXIsEditableAttribute,
            kAXSelectedTextRangeAttribute, kAXSelectedTextMarkerRangeAttribute, kAXEditableAncestorAttribute, kAXWindowAttribute]
        let leaf = reader.attributes(fieldNames, of: field)
        let owner = verifiedEditor ?? leaf.element(kAXEditableAncestorAttribute)
        let editor = owner ?? field
        let info = editor == field ? leaf : reader.attributes(fieldNames, of: editor)
        let role = info.values[kAXRoleAttribute] as? String ?? ""
        let parent = window ?? info.element(kAXWindowAttribute) ?? leaf.element(kAXWindowAttribute)
        let windowBounds = parent.flatMap { reader.attributes(geometryNames, of: $0).bounds }
        let isContainer = [kAXApplicationRole, kAXWindowRole, "AXWebArea"].contains(role) || editor == parent
        let isInput = !isContainer && (owner != nil || info.editable ||
            [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role))

        // A web area can expose a real caret even when it hides the field.
        // Only an edit control may supply a landing from its rectangle alone.
        func insertion(in element: AXUIElement, attributes: PasteFocus.Attributes) -> CGRect? {
            func bounds(_ name: String, for parameter: CFTypeRef) -> CGRect? {
                guard reader.prepare(element) else { return nil }
                var result: CFTypeRef?, rect = CGRect.zero
                guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success,
                      let result, CFGetTypeID(result) == AXValueGetTypeID(),
                      AXValueGetValue(result as! AXValue, .cgRect, &rect), isCaret(rect) else { return nil }
                return rect
            }
            var range = CFRange()
            if let selection = attributes.axValue(kAXSelectedTextRangeAttribute),
               AXValueGetValue(selection, .cfRange, &range), range.location >= 0, isInput || range.length == 0 {
                range.length = 0
                if let position = AXValueCreate(.cfRange, &range),
                   let rect = bounds(kAXBoundsForRangeParameterizedAttribute, for: position) { return rect }
            }
            guard let value = attributes.values[kAXSelectedTextMarkerRangeAttribute],
                  CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
            let selection = value as! AXTextMarkerRange
            let start = AXTextMarkerRangeCopyStartMarker(selection)
            guard isInput || CFEqual(start, AXTextMarkerRangeCopyEndMarker(selection)) else { return nil }
            return bounds(kAXBoundsForTextMarkerRangeParameterizedAttribute,
                          for: AXTextMarkerRangeCreate(nil, start, start))
        }

        let caret = insertion(in: editor, attributes: info) ?? (editor != field ? insertion(in: field, attributes: leaf) : nil)
        return InkLanding(caret: caret, field: isInput ? info.bounds : nil, window: windowBounds)
    }
}

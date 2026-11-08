import ApplicationServices
import Foundation

/// A focus identity captured on the second press. Missing AX support is common
/// in custom editors; a timed-out read is not evidence that support is missing.
struct PasteFocus {
    enum Status: String {
        case matched, changedWindow, changedField, blockedField, unavailable
    }

    enum FieldKind { case other, concreteEditor, container }

    let field, window: AXUIElement?
    let editor: AXUIElement?   // verified editable owner of an inline wrapper
    var status: Status
    var kind: FieldKind = .other
    var selection: NSRange?

    /// A mouse counter cannot identify the window that received the click.
    /// Compare insertion positions only within the exact same verified field.
    func hasSameInsertion(as current: Self) -> Bool {
        guard status == .matched, current.status == .matched,
              kind == .concreteEditor, current.kind == .concreteEditor,
              let window, window == current.window, let field, field == current.field,
              let selection else { return false }
        return current.selection == selection
    }

    static func capture(in application: AXUIElement) -> Self {
        let reader = Reader()
        let first = read(application, with: reader)
        guard first.status == .unavailable, reader.hasTime else { return first }
        // A partial first read can still identify a specific field or window.
        // Do not quietly adopt another destination during the retry.
        return first.checked(read(application, with: reader))
    }

    func revalidated(in application: AXUIElement) -> Self {
        guard status == .matched else { return self }
        let reader = Reader()
        let first = checked(Self.read(application, with: reader))
        guard first.status == .unavailable, reader.hasTime else { return first }
        return checked(Self.read(application, with: reader))
    }

    func checked(_ snapshot: Self) -> Self {
        var verified = snapshot
        verified.status = check(snapshot)
        return verified
    }

    func check(_ now: Self) -> Status {
        if now.status == .blockedField { return .blockedField }
        if let window, let current = now.window, !CFEqual(window, current) { return .changedWindow }
        if let field, let current = now.field, !CFEqual(field, current) {
            // A web accessibility tree can briefly report its root during
            // an update. Only a subsequent read of the original editor counts.
            if kind == .concreteEditor, now.kind == .container { return .unavailable }
            // Different wrappers can describe the same contenteditable. Two
            // independent input fields in the same window must never match.
            guard let editor, let currentEditor = now.editor,
                  CFEqual(editor, currentEditor) else {
                return .changedField
            }
        }
        if (window != nil && now.window == nil) || (field != nil && now.field == nil) { return .unavailable }
        return now.status
    }

    private static let focusNames = [kAXFocusedUIElementAttribute, kAXFocusedWindowAttribute]
    private static let fieldNames = [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute,
                                     "AXEditable", kAXIsEditableAttribute, kAXEditableAncestorAttribute,
                                     kAXSelectedTextRangeAttribute]

    private static func read(_ application: AXUIElement, with reader: Reader) -> Self {
        let focus = reader.attributes(focusNames, of: application)
        let field = focus.element(kAXFocusedUIElementAttribute)
        let window = focus.element(kAXFocusedWindowAttribute)
        var status: Status = focus.incomplete ? .unavailable : .matched
        var editor: AXUIElement?
        var kind = FieldKind.other
        var selection: NSRange?
        if let field {
            let info = reader.attributes(fieldNames, of: field, optional: kAXSelectedTextRangeAttribute)
            let role = info.values[kAXRoleAttribute] as? String ?? ""
            if PasteDestination.blocksPaste(attribute: { info.values[$0] }) {
                status = .blockedField
            } else if info.incomplete {
                status = .unavailable
            } else if [kAXStaticTextRole, kAXGroupRole].contains(role),
                      let owner = info.element(kAXEditableAncestorAttribute), !CFEqual(owner, field) {
                let ownerInfo = reader.attributes(fieldNames, of: owner, optional: kAXSelectedTextRangeAttribute)
                if PasteDestination.blocksPaste(attribute: { ownerInfo.values[$0] }) {
                    status = .blockedField
                } else if ownerInfo.incomplete {
                    status = .unavailable
                } else if info.editable {
                    // An independently editable child keeps its own identity.
                    editor = field
                } else if ownerInfo.editable {
                    editor = owner
                }
            } else if info.editable {
                editor = field
            }
            if CFEqual(field, application) || window == field ||
                [kAXWindowRole, kAXApplicationRole, "AXWebArea"].contains(role) {
                kind = .container
                editor = nil
            } else if editor != nil || [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) {
                kind = .concreteEditor
                if let raw = info.values[kAXSelectedTextRangeAttribute], CFGetTypeID(raw) == AXValueGetTypeID() {
                    var range = CFRange()
                    if AXValueGetValue(raw as! AXValue, .cfRange, &range),
                       range.location >= 0, range.location != NSNotFound,
                       range.length >= 0, range.length <= Int.max - range.location {
                        selection = NSRange(location: range.location, length: range.length)
                    }
                }
            }
        }
        return Self(field: field, window: window, editor: editor, status: status, kind: kind, selection: selection)
    }

    struct Attributes {
        var values = [String: CFTypeRef]()
        var incomplete = false

        var editable: Bool {
            (values["AXEditable"] ?? values[kAXIsEditableAttribute]) as? Bool == true
        }

        func element(_ name: String) -> AXUIElement? {
            guard let value = values[name], CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }

        mutating func record(_ error: AXError) {
            switch error {
            case .success, .noValue, .attributeUnsupported, .notImplemented: break
            default: incomplete = true
            }
        }

        mutating func record(_ value: CFTypeRef?, for name: String, optional: Bool) {
            guard let value, CFGetTypeID(value) != CFNullGetTypeID() else { return }
            if CFGetTypeID(value) == AXValueGetTypeID() {
                let ax = value as! AXValue
                if AXValueGetType(ax) == .axError {
                    if optional { return }
                    var error = AXError.failure
                    if AXValueGetValue(ax, .axError, &error) { record(error) } else { incomplete = true }
                    return
                }
            }
            values[name] = value
        }
    }

    struct Reader {
        // Bound the entire check, including providers that only implement
        // individual reads. Do not multiply the timeout by the attribute count.
        private let deadline = ProcessInfo.processInfo.systemUptime + 0.23
        var hasTime: Bool { ProcessInfo.processInfo.systemUptime < deadline }

        func prepare(_ element: AXUIElement) -> Bool {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(left, 0.10)))
            return true
        }

        func attributes(_ names: [String], of element: AXUIElement, optional: String? = nil) -> Attributes {
            guard prepare(element) else { return Attributes(incomplete: true) }
            var result = Attributes()
            var response: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &response)
            if error == .success, let values = response as? [AnyObject], values.count == names.count {
                for (name, value) in zip(names, values) { result.record(value, for: name, optional: name == optional) }
                // Some bridges implement individual reads but return nulls
                // or "unsupported" for every slot in an otherwise valid batch.
                if !result.values.isEmpty || result.incomplete { return result }
            }
            switch error {
            case .success, .notImplemented, .attributeUnsupported, .noValue, .illegalArgument:
                // A few providers reject an entire batch containing a missing
                // attribute. Check those attributes individually within budget.
                for name in names {
                    guard prepare(element) else {
                        if name != optional { result.incomplete = true }
                        continue
                    }
                    var value: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                    if status == .success { result.record(value, for: name, optional: name == optional) }
                    else if name != optional { result.record(status) }
                }
            default:
                result.record(error)
            }
            return result
        }
    }
}

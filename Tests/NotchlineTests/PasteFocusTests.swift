import ApplicationServices
import XCTest
@testable import Notchline

final class PasteFocusTests: XCTestCase {
    func testMouseActivityRequiresTheSameFieldAndSelection() {
        let field = AXUIElementCreateApplication(201), window = AXUIElementCreateApplication(202)
        var before = PasteFocus(field: field, window: window, editor: field, status: .matched, kind: .concreteEditor)
        before.selection = NSRange(location: 3, length: 2)
        XCTAssertTrue(before.hasSameInsertion(as: before))

        var moved = before
        moved.selection = NSRange(location: 3, length: 0)
        XCTAssertFalse(before.hasSameInsertion(as: moved), "The next paste would no longer replace the same text")
        moved.selection = nil
        XCTAssertFalse(before.hasSameInsertion(as: moved))
        var opaque = before
        opaque.kind = .container
        XCTAssertFalse(opaque.hasSameInsertion(as: opaque))
        let other = PasteFocus(field: AXUIElementCreateApplication(203), window: window, editor: nil,
                              status: .matched, kind: .concreteEditor, selection: before.selection)
        XCTAssertFalse(before.hasSameInsertion(as: other))
    }

    @MainActor
    func testFocusMustStayVerifiableAcrossAnAXHiccup() {
        // Opaque AX handles suffice for this identity check. No remote
        // controls are queried and no keyboard events are posted.
        let window = AXUIElementCreateApplication(101)
        let field = AXUIElementCreateApplication(102)
        let other = AXUIElementCreateApplication(103)
        func focus(_ field: AXUIElement?, _ window: AXUIElement?,
                   editor: AXUIElement? = nil, status: PasteFocus.Status = .matched,
                   kind: PasteFocus.FieldKind = .other) -> PasteFocus {
            PasteFocus(field: field, window: window, editor: editor, status: status, kind: kind)
        }

        let original = focus(field, window)
        XCTAssertEqual(original.check(focus(nil, window)), .unavailable)
        XCTAssertEqual(original.check(focus(field, nil)), .unavailable)
        XCTAssertEqual(original.check(focus(field, window, status: .unavailable)), .unavailable)
        XCTAssertEqual(original.check(focus(field, window)), .matched)
        XCTAssertEqual(original.check(focus(other, window)), .changedField)
        XCTAssertEqual(original.check(focus(field, other)), .changedWindow)
        XCTAssertEqual(original.check(focus(field, window, status: .blockedField)), .blockedField)

        // Losing a previously captured field differs from a custom editor
        // that consistently reports no field. Native paste still serves it.
        XCTAssertEqual(focus(nil, window).check(focus(nil, window)), .matched)
        XCTAssertEqual(focus(nil, window).check(focus(nil, other)), .changedWindow)
        XCTAssertEqual(focus(nil, window).check(focus(field, window, status: .blockedField)), .blockedField)

        let owner = AXUIElementCreateApplication(104)
        let wrapped = focus(field, window, editor: owner)
        let updated = wrapped.checked(focus(other, window, editor: owner))
        XCTAssertEqual(updated.status, .matched)
        XCTAssertEqual(updated.field, other, "Animation must locate the verified current wrapper")
        XCTAssertEqual(wrapped.check(focus(other, window, editor: other)), .changedField)
        XCTAssertEqual(wrapped.check(focus(other, window, editor: owner, status: .blockedField)), .blockedField)

        let input = focus(field, window, kind: .concreteEditor)
        let page = focus(other, window, kind: .container)
        XCTAssertEqual(input.check(page), .unavailable)
        XCTAssertEqual(input.check(input), .matched, "Only the return of the original input resolves the placeholder")
        XCTAssertEqual(input.check(focus(other, window, kind: .concreteEditor)), .changedField)
        XCTAssertEqual(input.check(focus(other, window, status: .blockedField, kind: .container)), .blockedField)
        XCTAssertEqual(page.check(page), .matched, "A stable container is not a reason to retry")
    }
}

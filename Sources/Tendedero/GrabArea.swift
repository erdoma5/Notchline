import AppKit
import SwiftUI

/// The glass card is one continuous hit target. AppKit tracks the pull in
/// screen coordinates even when the pointer leaves the original display.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line
    let onClick: (CGFloat) -> Void

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        let canMarkUp = !item.isRecording && !item.isText
        if item.isText {
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.button)
            view.setAccessibilityLabel(item.thumb.accessibilityDescription)
        }
        let tap = onClick
        view.onClick = { offset, press in
            line.scheduleCopy(id, press: press)
            tap(offset)
        }
        view.beginDoubleClick = { line.beginDoubleClick(id, press: $0) }
        view.onPull = { grab, point, panel in line.trackPull(id, from: grab, to: point, in: panel) }
        view.onRelease = { line.releasePull(id, cancelled: $0) }
        view.onLongPress = { line.markup(id) }
        view.onForceClick = { line.quickLook(id) }
        view.onPressChange = { pressed in
            if pressed { line.pressedID = id }
            else if line.pressedID == id { line.pressedID = nil }
        }
        view.menuProvider = {
            let menu = NSMenu()
            // Items say themselves whether they can be used.
            menu.autoenablesItems = false
            menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(id) })
            menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
            menu.addItem(ClosureMenuItem(L("Quick Look")) { line.quickLook(id) })
            if canMarkUp {
                menu.addItem(ClosureMenuItem(L("Markup")) { line.markup(id) })
            }
            menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
            let inInbox = line.isInInbox(id)
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Save to Desktop")) { line.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Discard")) { line.discard(id) })
            } else {
                menu.addItem(ClosureMenuItem(L("Take down")) { line.discard(id) })
                menu.addItem(ClosureMenuItem(L("Move to Trash")) { line.trash(id) })
            }
            let left = ClosureMenuItem(L("Take down everything to the left")) { line.takeDown(id, toTheLeft: true) }
            left.isEnabled = !line.neighbours(of: id, toTheLeft: true).isEmpty
            menu.addItem(left)
            let right = ClosureMenuItem(L("Take down everything to the right")) { line.takeDown(id, toTheLeft: false) }
            right.isEnabled = !line.neighbours(of: id, toTheLeft: false).isEmpty
            menu.addItem(right)
            return menu
        }
    }
}

/// Use the physical press time and screen position, which stay meaningful
/// while the hanging card swings or its native view is updated.
final class ClippingPress {
    let timestamp: TimeInterval
    let point: CGPoint
    let clickCount: Int
    let windowNumber: Int
    let eventNumber: Int
    private(set) var release: ClippingRelease?
    private(set) var lineClickProof: LineClickAttribution.Proof?
    private let leftClicks = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
    private let rightClicks = CGEventSource.counterForEventType(.combinedSessionState, eventType: .rightMouseDown)
    private let keys = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)

    init(event: NSEvent, in window: NSWindow) {
        timestamp = event.timestamp
        point = window.convertPoint(toScreen: event.locationInWindow)
        clickCount = event.clickCount
        windowNumber = event.windowNumber
        eventNumber = event.eventNumber
    }

    func follows(_ first: ClippingPress) -> Bool {
        guard (0...NSEvent.doubleClickInterval).contains(timestamp - first.timestamp) else { return false }
        if clickCount > 1 { return true }
        // AppKit can restart its count between two presses on a clipping.
        // Recover only nearby taps with no intervening click or keypress.
        return hypot(point.x - first.point.x, point.y - first.point.y) <= 12
            && (leftClicks &- first.leftClicks) <= 1 && rightClicks == first.rightClicks && keys == first.keys
    }

    func complete(with up: NSEvent) {
        guard up.type == .leftMouseUp, up.windowNumber == windowNumber,
              up.eventNumber == eventNumber, up.timestamp >= timestamp else { return }
        release = ClippingRelease(timestamp: up.timestamp, leftClicks:
            CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown))
        lineClickProof = LineClickAttribution.shared.proof(forRelease: up, lineWindow: windowNumber)
    }
}

struct ClippingRelease {
    let timestamp: TimeInterval
    let leftClicks: UInt32

    /// The button went down and came up on this clipping. Count the completed
    /// gesture as the paste intent, including a late update for its own down.
    /// A queued press newer than the physical up cannot belong to that click.
    func accountsForLeftPress(from captured: UInt32, to latest: UInt32, lastDown: TimeInterval) -> Bool {
        latest &- captured == 1 && (leftClicks == captured || leftClicks == latest)
            && lastDown <= timestamp
    }
}

final class GrabView: NSView {
    /// A photo's menu is open. It reaches past the line, so the line waits.
    static var isShowingMenu = false

    /// Horizontal distance from the peg, from -1 at the left edge to 1 at the right.
    var onClick: (CGFloat, ClippingPress?) -> Void = { _, _ in }
    var beginDoubleClick: (ClippingPress) -> (() -> Void)? = { _ in nil }
    var onPull: (PhotoGrab, CGPoint, CGRect) -> Void = { _, _, _ in }
    var onRelease: (Bool) -> Void = { _ in }
    var onLongPress: () -> Void = {}
    var onForceClick: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var grab: PhotoGrab?
    private var press: ClippingPress?
    private var tapOffset: CGFloat = 0
    private var moved = false
    private var pulling = false
    private var holdTimer: Timer?
    private var didLongPress = false
    private var doubleClickAction: (() -> Void)?
    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onClick(0, nil)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if window is LinePanel { LineClickAttribution.shared.startIfPermitted() }
        let press = ClippingPress(event: event, in: window)
        self.press = press
        doubleClickAction = beginDoubleClick(press)
        let contact = convert(event.locationInWindow, from: nil)
        tapOffset = min(1, max(-1, (contact.x - bounds.midX) / max(1, bounds.width / 2)))
        let center = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
        let card = CGRect(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2,
                          width: bounds.width, height: bounds.height)
        grab = PhotoGrab(card: card, pointer: window.convertPoint(toScreen: event.locationInWindow))
        moved = false
        pulling = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.grab != nil, !self.moved else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    /// A force click on a trackpad opens Quick Look, as it does in Finder.
    /// It counts instead of the click and of a long press.
    override func pressureChange(with event: NSEvent) {
        guard event.stage == 2, grab != nil, !moved, !didLongPress else { return }
        didLongPress = true
        endPress()
        onForceClick()
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab, !didLongPress, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let down = grab.pointer.y - point.y
        let sideways = abs(point.x - grab.pointer.x)
        if !moved {
            guard hypot(sideways, down) > 4 else { return }
            moved = true
            endPress()
        }
        // A horizontal or upward drag is neither a copy nor a removal.
        if !pulling {
            guard down > 4, down > sideways else { return }
            pulling = true
        }
        onPull(grab, point, window.frame)
    }

    override func mouseUp(with event: NSEvent) {
        if doubleClickAction != nil && !moved && !didLongPress { press?.complete(with: event) }
        endPress()
        if pulling, let grab, let window {
            onPull(grab, window.convertPoint(toScreen: event.locationInWindow), window.frame)
            onRelease(false)
        }
        if grab != nil && !moved && !didLongPress {
            if let doubleClickAction { doubleClickAction() }
            else { onClick(tapOffset, press) }
        }
        resetTracking()
    }

    private func resetTracking() {
        grab = nil
        press = nil
        pulling = false
        moved = false
        didLongPress = false
        doubleClickAction = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, grab != nil {
            if pulling { onRelease(true) }
            endPress()
            resetTracking()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func rightMouseDown(with event: NSEvent) {
        // The menu runs until it closes, and the line stays down meanwhile.
        GrabView.isShowingMenu = true
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
        GrabView.isShowingMenu = false
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

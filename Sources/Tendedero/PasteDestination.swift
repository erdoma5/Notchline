import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Paste uses the front app's ordinary Command-V handling. The AX field and
/// window, when exposed, help avoid stale destinations and locate the flight.
@MainActor
enum PasteDestination {
    case permissionRequired
    case noTarget
    case target(locateFlight: (() async -> CGPoint?)? = nil, sendPaste: (_ clipboardIsCurrent: () -> Bool) -> Bool)

    static var hasPasteAccess: Bool { CGPreflightPostEventAccess() }

    static func current(clippingPress: ClippingPress? = nil) -> Self {
        func unavailable(_ reason: String) -> Self {
            log.notice("Paste skipped at capture: \(reason, privacy: .public)")
            return .noTarget
        }
        guard sessionIsInteractive else { return unavailable("session inactive") }
        guard hasPasteAccess else { return .permissionRequired }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier > 0,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier != "com.apple.loginwindow" else { return unavailable("no front editor app") }

        let pid = app.processIdentifier
        let input = InputStamp()
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.10)
        let focus = AXIsProcessTrusted() ? PasteFocus.capture(in: application) : nil
        if let focus, focus.status != .matched { return unavailable(focus.status.rawValue) }

        var verifiedFocus: PasteFocus?
        let locate: (() async -> CGPoint?)?
        if focus != nil {
            locate = {
                // Animate from the focus actually verified for dispatch. A web
                // editor can replace its focused child between press and release.
                guard let verified = verifiedFocus, let field = verified.field,
                      field != verified.window, !CFEqual(field, application) else { return nil }
                let screens = NSScreen.screens.map(\.frame)
                let deadline = ContinuousClock.now + Line.flightLookupBudget
                let point = await Task.detached(priority: .userInitiated) { () -> CGPoint? in
                    let first = InkLanding.read(field: field, window: verified.window, editor: verified.editor).point(on: screens)
                    guard ContinuousClock.now < deadline else { return nil }
                    let fresh = verified.revalidated(in: application)
                    guard fresh.status == .matched else { return nil }
                    if let first, fresh.field == field { return first }
                    // A web renderer may have been busy applying the paste, or
                    // replaced the inline child while keeping the same editor.
                    guard ContinuousClock.now < deadline, let next = fresh.field,
                          next != fresh.window, next != application else { return nil }
                    let retry = InkLanding.read(field: next, window: fresh.window, editor: fresh.editor).point(on: screens)
                    guard let retry, ContinuousClock.now < deadline,
                          fresh.revalidated(in: application).status == .matched else { return nil }
                    return retry
                }.value
                guard !app.isTerminated, sessionIsInteractive, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let point, NSScreen.screens.contains(where: { $0.frame.contains(point) }) else { return nil }
                return point
            }
        } else { locate = nil }

        return .target(locateFlight: locate) { clipboardIsCurrent in
            func declined(_ reason: String) -> Bool {
                log.notice("Paste skipped before dispatch: \(reason, privacy: .public)")
                return false
            }
            guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return declined("front app changed")
            }
            let pasteKey = Shortcut.keyCode(typing: "v") ?? Shortcut.keyCode(typing: "v", in:
                TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
            guard let key = pasteKey,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false)
            else { return declined("paste key unavailable") }
            down.flags = .maskCommand
            up.flags = .maskCommand

            var beforeFocus = InputStamp()
            var current = focus?.revalidated(in: application)
            if let current, current.status != .matched { return declined(current.status.rawValue) }
            var latest = InputStamp()
            // If a new left press overlapped the AX read, get a selection
            // sampled after it. Retry the read at most once; post only below.
            if beforeFocus.clicks != latest.clicks, focus?.selection != nil,
               !latest.leftUnchanged(since: input, triggeringPress: clippingPress) {
                beforeFocus = latest
                current = focus?.revalidated(in: application)
                if let current, current.status != .matched { return declined(current.status.rawValue) }
                latest = InputStamp()
            }
            guard sessionIsInteractive else { return declined("session inactive") }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return declined("front app changed") }
            latest = InputStamp()
            guard input.keys == latest.keys else { return declined("intervening key press") }
            guard input.rightClicks == latest.rightClicks else { return declined("intervening right mouse press") }
            let samePress = latest.leftUnchanged(since: input, triggeringPress: clippingPress)
            if !samePress {
                guard beforeFocus.clicks == latest.clicks, let focus, let current,
                      focus.hasSameInsertion(as: current) else {
                    let delta = latest.clicks &- input.clicks
                    let onRelease = clippingPress?.release.map { String($0.leftClicks &- input.clicks) } ?? "unpaired"
                    log.notice("Paste skipped before dispatch: unattributed left press; down delta=\(delta), at release=\(onRelease, privacy: .public)")
                    return false
                }
            }
            guard clipboardIsCurrent() else { return declined("clipboard changed") }
            verifiedFocus = current
            down.postToPid(pid)
            up.postToPid(pid)
            if latest.clicks != input.clicks {
                let reason = samePress ? "matched clipping press" : "verified insertion position"
                log.notice("Paste dispatched after mouse activity: \(reason, privacy: .public)")
            }
            return true
        }
    }

    // No event monitor: counts catch clicks and keystrokes during a slow
    // image conversion, including switches inside an AX-opaque window.
    private struct InputStamp {
        let keys = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
        let clicks = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
        let rightClicks = CGEventSource.counterForEventType(.combinedSessionState, eventType: .rightMouseDown)

        func leftUnchanged(since original: Self, triggeringPress: ClippingPress?) -> Bool {
            if clicks == original.clicks { return true }
            guard let release = triggeringPress?.release else { return false }
            let lastDown = ProcessInfo.processInfo.systemUptime -
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
            if release.accountsForLeftPress(from: original.clicks, to: clicks, lastDown: lastDown) { return true }
            guard let proof = triggeringPress?.lineClickProof,
                  release.leftClicks &- original.clicks <= 1 else { return false }
            return LineClickAttribution.shared.provesOnlyLineClicks(since: proof, combinedCount: clicks)
        }
    }

    private static var sessionIsInteractive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    nonisolated static func blocksPaste(attribute: (String) -> Any?) -> Bool {
        if attribute(kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return true }
        guard let role = attribute(kAXRoleAttribute) as? String,
              [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) else { return false }
        return attribute(kAXEnabledAttribute) as? Bool == false ||
            (attribute("AXEditable") ?? attribute(kAXIsEditableAttribute)) as? Bool == false
    }
}

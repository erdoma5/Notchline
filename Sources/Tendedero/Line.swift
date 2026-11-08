import AppKit
import AVFoundation
import Combine
import os

let log = Logger(subsystem: "app.tendedero.Notchline", category: "line")

/// A photo, recording or text clipping hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { Notchline.isRecording(url) }
    var isText: Bool { TextNote.accepts(url) }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var theme: LineTheme = .clothesline

    func setTheme(_ theme: LineTheme) {
        if let id = pull.id { releasePull(id, cancelled: true) }
        // Pending destination lookups belong to the old visual theme. Paste
        // has already been dispatched; only its deferred animation is retired.
        feedback = nil
        self.theme = theme
        defaults.set(theme.rawValue, forKey: LineTheme.preferenceKey)
    }
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published private(set) var pull = LinePull()
    private(set) var loosePhoto: LoosePhotoPanel?
    @Published private(set) var feedback: Feedback?
    @Published var foldingIDs: Set<UUID> = []
    var onPasteFlight: ((Pegged, CGPoint) -> Bool)?

    struct Feedback: Identifiable {
        enum Kind: Equatable { case copied, pasteRequested, clipboardChanged, needsEditor, needsAccessibility, removed(anchor: CGFloat) }
        let id = UUID()
        let itemID: UUID
        let kind: Kind
        var showsCue = true

        var message: String {
            switch kind {
            case .copied: L("Copied to clipboard")
            case .pasteRequested: L("Paste requested")
            case .clipboardChanged: L("Paste cancelled · Clipboard changed")
            case .needsEditor: L("Copied · Click an input field and press ⌘V")
            case .needsAccessibility: L("Copied · Check Double-click paste access in the menu bar")
            case .removed: L("Taken off the line")
            }
        }
    }
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var onHitRectsChanged: (() -> Void)?
    var hitRects: [UUID: CGRect] = [:] {
        didSet { onHitRectsChanged?() }
    }

    var maxItems = 8
    /// How many photos fit across the screen. With Keep on line set, the
    /// line can hold more, and the rest are reached by scrolling.
    @Published var visibleCount = 8
    /// How far the line is scrolled towards older photos, in points; 0 shows
    /// the newest.
    @Published var scroll: CGFloat = 0

    /// Keep on line, from the menu bar: how many photos the line keeps, or
    /// nil for as many as fit across the screen.
    nonisolated static let keepChoices = [25, 50, 100]
    nonisolated static var keepOnLine: Int? {
        get {
            let n = UserDefaults.standard.integer(forKey: "keepOnLine")
            return keepChoices.contains(n) ? n : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "keepOnLine") }
    }


    var soundOn: Bool {
        get { !defaults.bool(forKey: "soundOff") }
        set { defaults.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let pasteDestination: (@MainActor () -> PasteDestination)?

    init(defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general,
         pasteDestination: (@MainActor () -> PasteDestination)? = nil) {
        self.defaults = defaults
        theme = LineTheme(rawValue: defaults.string(forKey: LineTheme.preferenceKey) ?? "") ?? .clothesline
        self.pasteboard = pasteboard
        self.pasteDestination = pasteDestination
        restore()
        scheduleGust()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        // The line moves anyway for a new photo, so the gaps close with it.
        sweepFallen()
        items.append(item)
        scroll = 0
        // A full line lets the oldest photo fall off the far end. Only one: a
        // line hung on a wider screen keeps its length here instead of losing
        // several photos to a single capture.
        if liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            letGo(oldest.id)
        }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false, animateFall: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        if animateFall {
            if pull.id == id { releasePull(id, cancelled: true) }
            onFall?(items[i])
        }
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        lastFall = Date()
    }

    /// When the last photo started falling. A fallen photo keeps its empty
    /// place briefly while the other cards are still being used.
    private var lastFall = Date.distantPast

    /// The pointer left the line: the gaps close, once the last photo has
    /// finished falling.
    func closeGaps() {
        guard items.contains(where: { $0.falling }),
              Date().timeIntervalSince(lastFall) >= 0.6 else { return }
        sweepFallen()
    }

    /// The fallen photos leave their places and the rest close up.
    private func sweepFallen() {
        items.removeAll { $0.falling }
        scroll(by: 0)  // The oldest scroll position may no longer exist.
    }

    /// "Take everything down" follows the inbox discard policy.
    func clear() {
        takeDown(items.filter { !$0.falling })
    }

    /// The photos hung before (left) or after (right) this one.
    func neighbours(of id: UUID, toTheLeft: Bool) -> [Pegged] {
        let live = items.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return [] }
        return toTheLeft ? Array(live[..<i]) : Array(live[(i + 1)...])
    }

    /// Takes down everything on one side of a photo. Each one goes the way
    /// of a discard: to the Trash from Notchline's folder, and
    /// only off the line from anywhere else.
    func takeDown(_ id: UUID, toTheLeft: Bool) {
        takeDown(neighbours(of: id, toTheLeft: toTheLeft))
    }

    /// One after another, and only the first makes a sound. They are one
    /// step, so Put back brings them all back at once.
    private func takeDown(_ live: [Pegged]) {
        let step = UUID()
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0, step: step)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func trackPull(_ id: UUID, from grab: PhotoGrab, to point: CGPoint, in panelFrame: CGRect) {
        let width = panelFrame.width
        guard revealed, width > 0 else { return }
        var next = pull
        if next.id != id {
            guard let index = items.firstIndex(where: { $0.id == id && !$0.falling && !$0.flying }),
                  let panel = LoosePhotoPanel(item: items[index], grab: grab, theme: theme) else { return }
            if let previous = pull.id { releasePull(previous, cancelled: true) }
            cancelScheduledCopy()
            feedback = nil
            let x = centerX(at: index, width: width)
            next = LinePull(id: id, anchor: min(0.999, max(0.001, x / width)))
            loosePhoto = panel
        }
        let card = grab.frame(at: point)
        next.track(down: grab.pointer.y - point.y, sideways: point.x - grab.pointer.x,
                   touchingRope: Layout.touchesDock(card, in: panelFrame, theme: theme,
                       shelf: Layout.particleShelfRect(cards: cardRects(width: width), width: width)))
        loosePhoto?.setRemovalArmed(next.armed)
        loosePhoto?.follow(card)
        if next.armed && !pull.armed {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if next != pull { pull = next }
    }

    func releasePull(_ id: UUID, cancelled: Bool) {
        guard pull.id == id else { return }
        if !cancelled, pull.armed, revealed, let index = liveIndex(of: id),
           let item = items.first(where: { $0.id == id }) {
            loosePhoto?.disperse()
            drop(id, animateFall: false)
            remember(TakenDown(url: item.url, index: index, trashed: nil), in: UUID())
            showFeedback(.removed(anchor: pull.anchor), for: id)
        } else {
            if theme == .hologram && revealed { loosePhoto?.returnToDock() }
            else { loosePhoto?.orderOut(nil) }
        }
        loosePhoto = nil
        pull.release()
    }

    private func showFeedback(_ kind: Feedback.Kind, for id: UUID, showsCue: Bool = true) {
        let notice = Feedback(itemID: id, kind: kind, showsCue: showsCue)
        feedback = notice
        if let app = NSApp {
            NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
                .announcement: notice.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
        }
        let hintDuration = (kind == .needsEditor || kind == .needsAccessibility) ? 4.0 : 1.35
        DispatchQueue.main.asyncAfter(deadline: .now() + hintDuration) { [weak self] in
            guard let self, self.feedback?.id == notice.id else { return }
            self.feedback = nil
            if self.pull.id == nil { self.closeGaps() }
        }
    }

    nonisolated static let flightLookupBudget: Duration = .milliseconds(450)

    private func showPasteFeedback(for item: Pegged, locateFlight: (() async -> CGPoint?)?) {
        guard (item.isText || theme == .hologram && !item.isRecording), let locateFlight, let onPasteFlight,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            showFeedback(.pasteRequested, for: item.id)
            return
        }
        showFeedback(.pasteRequested, for: item.id, showsCue: false)
        let notice = feedback?.id
        // A paste can briefly occupy the receiving editor's UI thread. Give
        // geometry a bounded chance to settle after dispatch. Only committed
        // feedback supersedes this flight, not the first press of the next pair.
        let deadline = ContinuousClock.now + Self.flightLookupBudget
        let fallback = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self, feedback?.id == notice else { return }
            feedback?.showsCue = true
        }
        Task { [weak self] in
            let point = await locateFlight()
            guard let self, feedback?.id == notice else { return }
            fallback.cancel()
            let onTime = ContinuousClock.now < deadline
            if onTime, let point,
               items.contains(where: { $0.id == item.id && !$0.falling }),
               onPasteFlight(item, point) { return }
            let reason = !onTime ? "lookup timed out" : (point == nil ? "no verified landing" : "source unavailable")
            log.notice("Paste animation skipped: \(reason, privacy: .public)")
            feedback?.showsCue = true
        }
    }

    private var scheduledCopy: (itemID: UUID, press: ClippingPress?, timer: Timer)?
    private var copyRequest = 0
    var awaitingSingleClick: Bool { scheduledCopy != nil }

    /// Copy on release. Keep the click armed only to recognize a possible
    /// second press; the system double-click interval must not delay feedback.
    func scheduleCopy(_ id: UUID, press: ClippingPress? = nil) {
        cancelScheduledCopy()
        // Give AppKit a frame to deliver a second press queued near the
        // deadline. Pairing uses event timestamps, not timer delivery time.
        let timer = Timer(timeInterval: NSEvent.doubleClickInterval + 1.0 / 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduledCopy = nil
            }
        }
        scheduledCopy = (id, press, timer)
        RunLoop.main.add(timer, forMode: .common)
        copy(id)
    }

    func cancelScheduledCopy() {
        scheduledCopy?.timer.invalidate()
        scheduledCopy = nil
        copyRequest &+= 1
    }

    func copy(_ id: UUID) {
        copy(id, forPaste: nil)
    }

    /// Pin the destination on the second press. Only a completed click
    /// invokes the returned action; a drag or hold simply drops it.
    func beginDoubleClick(_ id: UUID, press: ClippingPress? = nil) -> (() -> Void)? {
        guard let pending = scheduledCopy, pending.itemID == id,
              let item = items.first(where: { $0.id == id && !$0.falling }) else { return nil }
        if let press {
            guard let first = pending.press, press.follows(first) else { return nil }
        }
        cancelScheduledCopy()
        if item.isRecording { return { [weak self] in self?.open(id) } }
        let change = pasteboard.changeCount
        let request = copyRequest
        let destination = pasteDestination?() ?? PasteDestination.current(clippingPress: press)
        return { [weak self] in
            guard let self, copyRequest == request else { return }
            copy(id, forPaste: destination, unchangedSince: change)
        }
    }

    private func copy(_ id: UUID, forPaste destination: PasteDestination?, unchangedSince: Int? = nil) {
        guard let item = items.first(where: { $0.id == id && !$0.falling }) else { return }
        copyRequest &+= 1
        let request = copyRequest
        func writeAndFinish(png: Data? = nil) {
            guard putOnClipboard(item.url, preparedPNG: png, imageOnly: png != nil && destination != nil,
                                 unchangedSince: unchangedSince) else {
                if let unchangedSince, pasteboard.changeCount != unchangedSince {
                    showFeedback(.clipboardChanged, for: id)
                }
                return
            }
            let writtenChange = pasteboard.changeCount
            let kind: Feedback.Kind
            switch destination {
            case nil: kind = .copied
            case .permissionRequired: kind = .needsAccessibility
            case .noTarget: kind = .needsEditor
            case .target(let locateFlight, let send):
                if send({ pasteboard.changeCount == writtenChange }) {
                    showPasteFeedback(for: item, locateFlight: locateFlight)
                    return
                }
                kind = pasteboard.changeCount == writtenChange ? .needsEditor : .clipboardChanged
            }
            showFeedback(kind, for: id)
        }
        if item.isText || item.isRecording {
            writeAndFinish()
            return
        }
        let url = item.url
        Task {
            let png = await Task.detached(priority: .userInitiated) { Self.pngData(url) }.value
            guard let png, copyRequest == request,
                  items.contains(where: { $0.id == id && !$0.falling }) else { return }
            writeAndFinish(png: png)
        }
    }

    /// The file last put on the clipboard, and the clipboard's change count
    /// right after. While the count is the same, nothing else has been copied.
    private var onClipboard: (url: URL, change: Int)?

    @discardableResult
    private func putOnClipboard(_ url: URL, preparedPNG: Data? = nil, imageOnly: Bool = false,
                                unchangedSince: Int? = nil) -> Bool {
        let entry = NSPasteboardItem()
        // A recording is copied as the file, which apps paste as the video.
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let isText = TextNote.accepts(url)
        if isText {
            guard let text = TextNote.read(url), entry.setString(text, forType: .string) else { return false }
        } else if !isRecording(url) {
            guard let png = preparedPNG ?? Self.pngData(url), entry.setData(png, forType: .png) else { return false }
        }
        let linksFile = !isText && !imageOnly
        if linksFile {
            guard entry.setString(url.absoluteString, forType: .fileURL) else { return false }
        } else {
            guard entry.setData(Data(), forType: ClipboardWatcher.fromLine) else { return false }
        }
        let pb = pasteboard
        if let unchangedSince, pb.changeCount != unchangedSince { return false }
        pb.clearContents()
        guard pb.writeObjects([entry]) else { return false }
        onClipboard = linksFile ? (url, pb.changeCount) : nil
        return true
    }

    /// Apps like Finder or a chat window paste the copied file rather than the
    /// picture. When the file moves after a copy, to the Trash or the Desktop,
    /// the clipboard follows it, or those apps would find nothing to paste.
    private func clipboardFollows(_ url: URL, to moved: URL) {
        guard let onClipboard, onClipboard.url == url,
              onClipboard.change == pasteboard.changeCount else { return }
        putOnClipboard(moved)
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line.
    ///
    /// `step` is what Put back brings it back with. Nil when the line lets
    /// a photo go by itself, which is not undone.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false, step: UUID? = UUID()) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        let index = liveIndex(of: id)
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
            if let trashed { clipboardFollows(item.url, to: trashed as URL) }
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .private)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            if let step, let index {
                remember(TakenDown(url: item.url, index: index, trashed: trashed as URL?), in: step)
            }
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Notchline's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return [Inbox.folder, TextNote.folder].contains { folder in
            item.url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
        }
    }

    /// Explicit discards and bulk removals follow the inbox policy.
    func discard(_ id: UUID, quietly: Bool = false, step: UUID = UUID()) {
        if isInInbox(id) {
            trash(id, quietly: quietly, step: step)
        } else if let item = items.first(where: { $0.id == id && !$0.falling }), let index = liveIndex(of: id) {
            drop(id, quietly: quietly)
            remember(TakenDown(url: item.url, index: index, trashed: nil), in: step)
        }
    }

    func centerX(at index: Int, width: CGFloat) -> CGFloat {
        Layout.x(index: index, count: items.count, width: width,
                 visible: visibleCount, scroll: scroll,
                 itemWidth: PeggedView.cardSize(for: items[index]).width)
    }

    /// Shared by SwiftUI placement, screen-space flights and docking feedback.
    func cardRects(width: CGFloat) -> [CGRect] {
        items.indices.map { index in
            Layout.cardRect(centerX: centerX(at: index, width: width), size: PeggedView.cardSize(for: items[index]),
                            width: width, theme: theme)
        }
    }

    /// Moves along a line that holds more than fit, from a scroll gesture.
    func scroll(by delta: CGFloat) {
        let most = CGFloat(max(0, items.count - visibleCount)) * Layout.spacing
        let next = min(most, max(0, scroll + delta))
        if next != scroll { scroll = next }
    }

    /// After Keep on line is lowered, the oldest photos past it go the way
    /// of a full line.
    func trim() {
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            letGo(oldest.id)
        }
        scroll = 0
    }

    /// The oldest photo falling off a full line. A file from
    /// Notchline's folder goes to the Trash, or nothing would ever take it out
    /// of that folder. If the Trash refuses it, it still leaves the line.
    private func letGo(_ id: UUID) {
        if isInInbox(id), trash(id, quietly: true, step: nil) { return }
        drop(id, quietly: true)
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            clipboardFollows(item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .private)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isText {
            quickLook(id)
        } else if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            Markup.shared.edit(item.url)
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        let live = items.filter { !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        for i in items.indices where !items[i].falling {
            if let thumb = makeThumbnail(items[i].url) { items[i].thumb = thumb }
        }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Putting back

    /// A photo taken down by hand: its file, where it hung among the photos
    /// still on the line, and where the file went if it went to the Trash.
    private struct TakenDown {
        let url: URL
        let index: Int
        let trashed: URL?
    }

    /// What was taken down, the latest last. A step holds everything one
    /// action took down. Only kept while the app runs.
    private var steps: [(id: UUID, photos: [TakenDown])] = []
    private static let maxSteps = 20

    var canPutBack: Bool { !steps.isEmpty }

    private func remember(_ photo: TakenDown, in step: UUID) {
        if let i = steps.lastIndex(where: { $0.id == step }) {
            steps[i].photos.append(photo)
        } else {
            steps.append((step, [photo]))
            if steps.count > Self.maxSteps { steps.removeFirst() }
        }
    }

    /// Put back, or ⌘Z over the line: what was taken down last hangs again
    /// where it was, and a file sent to the Trash comes back out of it.
    func putBack() {
        guard let step = steps.popLast() else { return }
        var back: Set<UUID> = []
        // The last one taken down goes back first, so each finds its place.
        for photo in step.photos.reversed() {
            guard let url = restore(photo), !items.contains(where: { $0.url == url && !$0.falling }),
                  let thumb = makeThumbnail(url) else { continue }
            let item = Pegged(url: url, thumb: thumb)
            let live = items.filter { !$0.falling }
            if let gap = items.firstIndex(where: { $0.falling && $0.url == photo.url }) {
                // Its empty place is still on the line: it hangs back there.
                items[gap] = item
            } else if photo.index < live.count, let i = items.firstIndex(where: { $0.id == live[photo.index].id }) {
                items.insert(item, at: i)
            } else {
                items.append(item)
            }
            back.insert(item.id)
        }
        guard !back.isEmpty else {
            NSSound.beep()
            return
        }
        feedback = nil
        // As when something new hangs, a full line lets its oldest photo go,
        // never one that just came back.
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling && !back.contains($0.id) }) {
            letGo(oldest.id)
        }
        save()
        play("Tink", volume: 0.35)
    }

    /// The photo's file, where it was before. Nil when it is gone: the Trash
    /// was emptied, or the file was moved or deleted since.
    private func restore(_ photo: TakenDown) -> URL? {
        guard let trashed = photo.trashed else {
            return FileManager.default.fileExists(atPath: photo.url.path) ? photo.url : nil
        }
        let url = uniqueURL(in: photo.url.deletingLastPathComponent(), for: photo.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: trashed, to: url)
            clipboardFollows(trashed, to: url)
            log.notice("Put back \(url.lastPathComponent, privacy: .private)")
            return url
        } catch {
            log.error("Could not put back \(trashed.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Where a photo hangs, counting only the photos still on the line.
    private func liveIndex(of id: UUID) -> Int? {
        items.filter { !$0.falling }.firstIndex { $0.id == id }
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.pull.id == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        let paths = items.filter { !$0.falling }.map(\.url.path)
        defaults.set(paths, forKey: storeKey)
    }

    /// Everything comes back as it was. This runs before the line knows its
    /// screen, so the capacity is still the default one: hanging through
    /// `hang` would let photos fall off a wide screen's line at every launch.
    private func restore() {
        let paths = defaults.stringArray(forKey: storeKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            items.append(Pegged(url: url, thumb: thumb))
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    nonisolated private static func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
@MainActor
func makeThumbnail(_ url: URL, maxPixels: Int = Int(320 * Layout.size.scale)) -> NSImage? {
    if TextNote.accepts(url) {
        return TextNote(contentsOf: url)?.thumbnail(scale: CGFloat(maxPixels) / 144)
    }
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

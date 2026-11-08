import AppKit
import CoreGraphics

/// Optional evidence for a subsequent press on the line while the main
/// thread is waiting on an editor. The tap can see only this process's events.
final class LineClickAttribution: @unchecked Sendable {
    static let shared = LineClickAttribution()
    private let lock = NSLock()
    private var port: CFMachPort?
    private var retryAfter: TimeInterval = 0
    private var starting = false
    private var cleanup: Timer?
    private var history = LineClickHistory()

    struct Proof {
        fileprivate let timestamp: UInt64
        fileprivate let number, window: Int64
        fileprivate let epoch: UInt64
    }

    func startIfPermitted() {
        lock.lock()
        let existing = port
        let now = ProcessInfo.processInfo.systemUptime
        guard !(existing.map { CGEvent.tapIsEnabled(tap: $0) } ?? false), !starting, now >= retryAfter else {
            lock.unlock()
            return
        }
        starting = true
        retryAfter = now + 30
        history.reset()
        lock.unlock()

        // Permission checks and tap creation must never make a physical
        // mouseDown wait. An unavailable tap simply provides no evidence.
        Thread.detachNewThread { [self] in
            Thread.current.name = "Notchline clipping clicks"
            let permitted = CGPreflightListenEventAccess()
            if permitted, let existing, CFMachPortIsValid(existing) {
                CGEvent.tapEnable(tap: existing, enable: true)
            } else if permitted {
                let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
                let tap = CGEvent.tapCreateForPid(pid: getpid(), place: .headInsertEventTap, options: .listenOnly,
                    eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                        if let context {
                            Unmanaged<LineClickAttribution>.fromOpaque(context).takeUnretainedValue().receive(type, event)
                        }
                        return Unmanaged.passUnretained(event)
                    }, userInfo: Unmanaged.passUnretained(self).toOpaque())
                if let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                    lock.lock()
                    port = tap
                    starting = false
                    lock.unlock()
                    CFRunLoopRun()
                    return
                }
            }
            lock.lock()
            starting = false
            lock.unlock()
        }
    }

    func proof(forRelease release: NSEvent, lineWindow: Int) -> Proof? {
        guard release.type == .leftMouseUp, lineWindow > 0, release.windowNumber == lineWindow,
              let event = release.cgEvent, event.timestamp > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let port, CGEvent.tapIsEnabled(tap: port) else { return nil }
        // The worker may still be receiving this exact up when AppKit calls
        // this method. Resolve its observed boundary only when evidence is used.
        return Proof(timestamp: event.timestamp, number: event.getIntegerValueField(.mouseEventNumber),
                     window: Int64(lineWindow), epoch: history.epoch)
    }

    func provesOnlyLineClicks(since proof: Proof, combinedCount: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let port, CGEvent.tapIsEnabled(tap: port), proof.epoch == history.epoch,
              let counts = Counts.sample(), counts.combined == combinedCount else { return false }
        history.expire(at: DispatchTime.now().uptimeNanoseconds)
        return history.proves(timestamp: proof.timestamp, number: proof.number, window: proof.window,
                              combined: counts.combined, hid: counts.hid)
    }

    private struct Counts {
        let combined, hid: UInt32
        let lower, upper: UInt64  // bounds on the two tables' most recent down time

        static func sample() -> Self? {
            let type = CGEventType.leftMouseDown
            let combined = CGEventSource.counterForEventType(.combinedSessionState, eventType: type)
            let hid = CGEventSource.counterForEventType(.hidSystemState, eventType: type)
            let before = DispatchTime.now().uptimeNanoseconds
            let sessionAge = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            let hardwareAge = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
            let after = DispatchTime.now().uptimeNanoseconds
            guard sessionAge.isFinite, hardwareAge.isFinite, min(sessionAge, hardwareAge) >= 0,
                  max(sessionAge, hardwareAge) < 10,
                  combined == CGEventSource.counterForEventType(.combinedSessionState, eventType: type),
                  hid == CGEventSource.counterForEventType(.hidSystemState, eventType: type) else { return nil }
            let oldest = UInt64((max(sessionAge, hardwareAge) * 1e9).rounded(.up))
            let newest = UInt64((min(sessionAge, hardwareAge) * 1e9).rounded(.down))
            guard before >= oldest, after >= newest else { return nil }
            return Self(combined: combined, hid: hid, lower: before - oldest, upper: after - newest)
        }
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard type == .leftMouseUp || type == .leftMouseDown else { history.reset(); return }
        if let cleanup {
            cleanup.fireDate = Date(timeIntervalSinceNow: 2)
        } else {
            let timer = Timer(timeInterval: 2, repeats: false) { [self] _ in
                lock.lock()
                history.reset()
                cleanup = nil
                lock.unlock()
            }
            cleanup = timer
            RunLoop.current.add(timer, forMode: .common)
        }
        let down = type == .leftMouseDown
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        // Never use PID-directed synthetic mouse events as an explanation for
        // hardware traffic. They need not increment the same state tables.
        let hardware = event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue)
            && Self.isSystemSource(sourcePID)
        let window = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        let counts = Counts.sample()
        // Pin the accounting to this physical event. An up delivered late
        // cannot absorb an already-counted *later* down into the baseline.
        let accounted = counts.map { down ? $0.lower >= event.timestamp : $0.upper <= event.timestamp } ?? false
        history.record(.init(timestamp: event.timestamp, number: event.getIntegerValueField(.mouseEventNumber),
                             window: window, down: down, hardware: hardware, accounted: accounted,
                             combined: counts?.combined ?? 0, hid: counts?.hid ?? 0))
    }

    private static func isSystemSource(_ pid: Int64) -> Bool {
        if pid == 0 { return true }
        guard let pid = Int32(exactly: pid), pid > 0 else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let executable = String(cString: path)
        return executable.hasPrefix("/System/Library/") && executable.hasSuffix("/WindowServer")
    }
}

/// A short bounded buffer, with no coordinates, key events, or other apps' events.
struct LineClickHistory {
    struct Entry {
        let timestamp: UInt64
        let number, window: Int64
        let down, hardware, accounted: Bool
        let combined, hid: UInt32
    }

    private(set) var epoch: UInt64 = 0
    private var entries: [Entry] = []

    mutating func reset() { entries.removeAll(keepingCapacity: true); epoch &+= 1 }
    mutating func expire(at now: UInt64) {
        entries.removeAll { now > $0.timestamp && now - $0.timestamp > 2_000_000_000 }
    }
    mutating func record(_ event: Entry) {
        if let last = entries.last, last.timestamp >= event.timestamp { reset() }
        entries.append(event)
        if entries.count > 32 { entries.removeFirst() }
    }

    func proves(timestamp: UInt64, number: Int64, window: Int64, combined: UInt32, hid: UInt32) -> Bool {
        guard let index = entries.firstIndex(where: { !$0.down && $0.timestamp == timestamp &&
                    $0.number == number && $0.window == window && $0.hardware && $0.accounted }) else { return false }
        let anchor = entries[index]
        let delta = combined &- anchor.combined
        guard delta > 0, delta <= 31, delta == hid &- anchor.hid else { return false }
        let observed = entries[(index + 1)...]
        let later = observed.filter(\.down)
        guard later.count == Int(delta), Set(later.map(\.number)).count == later.count else { return false }
        return later.enumerated().allSatisfy { index, press in
            let step = UInt32(index + 1)
            guard press.hardware, press.window == window else { return false }
            func recorded(_ event: Entry) -> Bool {
                event.accounted && event.combined == anchor.combined &+ step && event.hid == anchor.hid &+ step
            }
            if recorded(press) { return true }
            // The tap can see a down before the counters account for it. A
            // completed *hardware* up with the same event number establishes
            // that boundary without assuming anything about callback latency.
            return observed.contains { !$0.down && $0.hardware && $0.number == press.number &&
                $0.window == window && $0.timestamp > press.timestamp && recorded($0) }
        }
    }
}

import XCTest
@testable import Notchline

final class LineClickAttributionTests: XCTestCase {
    func testOnlyAccountedHardwarePressesOnTheReleaseWindowExplainAnAdvance() {
        var history = LineClickHistory()
        func record(_ time: UInt64, _ number: Int64, _ down: Bool, _ combined: UInt32, _ hid: UInt32,
                    window: Int64 = 7, hardware: Bool = true, counted: Bool = true) {
            history.record(.init(timestamp: time, number: number, window: window, down: down,
                                 hardware: hardware, accounted: counted, combined: combined, hid: hid))
        }
        func proved(_ combined: UInt32, _ hid: UInt32) -> Bool {
            history.proves(timestamp: 10, number: 1, window: 7, combined: combined, hid: hid)
        }

        record(10, 1, false, 90, 20)
        XCTAssertFalse(proved(90, 20))
        record(11, 2, true, 91, 21)
        XCTAssertTrue(proved(91, 21))
        XCTAssertFalse(proved(92, 21), "A PID-directed synthetic increment is not explained by a hardware press")
        XCTAssertFalse(proved(92, 22), "An unobserved physical press might have reached the editor")
        record(13, 3, true, 91, 21, counted: false)
        XCTAssertFalse(proved(92, 22))
        record(14, 3, false, 92, 22)
        XCTAssertTrue(proved(92, 22), "The matched up accounts for its down")
        record(15, 4, true, 93, 23, window: 8)
        XCTAssertFalse(proved(93, 23), "A click in a different Notchline panel is not a clipping press")
        history.reset()
        XCTAssertFalse(proved(92, 22), "Tap interruption invalidates the boundary")

        record(10, 1, false, 90, 20, counted: false)
        record(11, 2, true, 91, 21)
        XCTAssertFalse(proved(91, 21), "A late release whose sample includes a newer down cannot anchor a proof")
        history.reset()
        record(10, 1, false, 90, 20)
        record(11, 2, true, 91, 21, hardware: false)
        XCTAssertFalse(proved(91, 21), "Untrusted or synthesized source metadata is not positive evidence")
        history.reset()
        record(10, 1, false, 90, 20)
        record(11, 2, true, 91, 21)
        history.expire(at: 3_000_000_000)
        XCTAssertFalse(proved(91, 21))
    }
}

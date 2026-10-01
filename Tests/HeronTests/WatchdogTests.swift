import XCTest
@testable import Heron

@MainActor
final class WatchdogTests: XCTestCase {
    /// Fed often it never fires; left alone it fires once; stopped it doesn't.
    func testFiresOnceWhenStarvedAndNotWhileFed() {
        var fired = 0
        let dog = Watchdog(interval: { 0.2 }, fire: { fired += 1 })
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            dog.feed()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(fired, 0, "fed every 20 ms, a 200 ms watchdog stays quiet")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(fired, 1)
        dog.feed(); dog.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(fired, 1, "stopped")
    }
}

import Foundation

/// Fires once when it hasn't been fed for `interval` (a turn that has gone silent). Feeding it
/// moves the deadline; only one timer is ever pending.
///
/// Re-arming with `DispatchQueue.main.asyncAfter` on every event and cancelling the previous
/// work item was what this replaced: a cancelled item stays in the system's timer queue until its
/// deadline, so a streaming turn left thousands of 180-second timers pending, each holding its
/// work item and what it captured.
@MainActor
final class Watchdog {
    private let interval: () -> TimeInterval
    private let fire: () -> Void
    private var deadline: Date?
    private var scheduled = false

    init(interval: @escaping () -> TimeInterval, fire: @escaping () -> Void) {
        self.interval = interval
        self.fire = fire
    }

    var isArmed: Bool { deadline != nil }

    /// Starts or restarts the countdown.
    func feed() {
        deadline = Date().addingTimeInterval(interval())
        schedule(after: interval())
    }

    func stop() { deadline = nil }

    private func schedule(after delay: TimeInterval) {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        scheduled = false
        guard let deadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0.001 {
            schedule(after: remaining)
        } else {
            self.deadline = nil
            fire()
        }
    }
}

import Foundation

/// A provider's stream events, carried to the main thread at most once a frame
/// (SIDE_RFC_HERON_EFFICIENCY.md, D6).
///
/// A provider calls back once per SSE line, on its own thread, and a token is a few characters:
/// hopping to the main thread per line meant hundreds of hops, and as many transcript
/// notifications, a second. Here events gather under a lock, consecutive deltas of the same
/// kind merge into one, and a single hop hands the batch over, no sooner than a frame after the
/// last. Order is kept: a tool call's start still comes before its input, and the end after.
final class StreamEventCoalescer: @unchecked Sendable {
    /// A frame at 60 Hz.
    static let interval: TimeInterval = 1.0 / 60

    private let lock = NSLock()
    private var pending: [AgentStreamEvent] = []
    private var scheduled = false
    private var lastDelivery = DispatchTime(uptimeNanoseconds: 0)
    private let deliver: @MainActor ([AgentStreamEvent]) -> Void

    /// Hops to the main thread so far, and the main thread's time spent delivering them: what
    /// the streaming budgets measure.
    private(set) var deliveries = 0
    private(set) var deliveryTime: TimeInterval = 0

    init(deliver: @escaping @MainActor ([AgentStreamEvent]) -> Void) {
        self.deliver = deliver
    }

    /// From the provider's thread.
    func add(_ event: AgentStreamEvent) {
        let schedule: TimeInterval? = lock.withLock {
            Self.merge(event, into: &pending)
            guard !scheduled else { return nil }
            scheduled = true
            let next = lastDelivery.uptimeNanoseconds + UInt64(Self.interval * 1e9)
            let now = DispatchTime.now().uptimeNanoseconds
            return next > now ? TimeInterval(next - now) / 1e9 : 0
        }
        guard let schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + schedule) { [self] in
            MainActor.assumeIsolated { flush() }
        }
    }

    /// Delivers whatever is waiting, now. The stream's end calls it before finishing the turn,
    /// so nothing arrives after the turn it belongs to.
    @MainActor
    func flush() {
        let events: [AgentStreamEvent] = lock.withLock {
            scheduled = false
            lastDelivery = .now()
            defer { pending = [] }
            return pending
        }
        guard !events.isEmpty else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        deliver(events)
        let spent = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        lock.withLock {
            deliveries += 1
            deliveryTime += spent
        }
    }

    /// Appended in place: the last event is taken out, so its string has one owner and grows
    /// without a copy.
    static func merge(_ event: AgentStreamEvent, into pending: inout [AgentStreamEvent]) {
        guard let last = pending.last else { return pending.append(event) }
        switch (last, event) {
        case (.textDelta, .textDelta(let more)):
            guard case .textDelta(var text) = pending.removeLast() else { return }
            text += more
            pending.append(.textDelta(text))
        case (.thinkingDelta, .thinkingDelta(let more)):
            guard case .thinkingDelta(var text) = pending.removeLast() else { return }
            text += more
            pending.append(.thinkingDelta(text))
        case (.toolUseInputDelta(let id, _), .toolUseInputDelta(let nextId, let more)) where id == nextId:
            guard case .toolUseInputDelta(_, var json) = pending.removeLast() else { return }
            json += more
            pending.append(.toolUseInputDelta(id: id, partialJSON: json))
        default:
            pending.append(event)
        }
    }
}

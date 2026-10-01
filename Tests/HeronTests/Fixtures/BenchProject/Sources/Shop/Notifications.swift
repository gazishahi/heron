public enum Notice: Equatable {
    case orderPlaced(orderID: String, total: Money)
    case orderShipped(orderID: String, trackingNumber: String)
    case orderCancelled(orderID: String, reason: String)
}

public protocol Notifier {
    func send(_ notice: Notice, to customer: Customer)
}

/// Keeps what would have been emailed.
public final class OutboxNotifier: Notifier {
    public private(set) var sent: [(email: String, notice: Notice)] = []
    public init() {}
    public func send(_ notice: Notice, to customer: Customer) {
        sent.append((customer.email, notice))
    }
}

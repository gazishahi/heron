public protocol PaymentGateway {
    /// Holds the amount on the customer's card; returns an authorization id.
    func authorize(customerID: String, amount: Money) throws -> String
    func capture(authorization: String) throws
    func void(authorization: String)
}

public enum PaymentError: Error, Equatable {
    case declined(String)
    case unknownAuthorization
}

/// A gateway for tests and local runs: declines anything over its limit.
public final class FakeGateway: PaymentGateway {
    public var limit: Money
    public private(set) var authorized: [String: Money] = [:]
    public private(set) var captured: Set<String> = []
    private var next = 1

    public init(limit: Money = Money(dollars: 1_000)) { self.limit = limit }

    public func authorize(customerID: String, amount: Money) throws -> String {
        guard amount <= limit else { throw PaymentError.declined("over the limit") }
        let id = "auth_\(next)"
        next += 1
        authorized[id] = amount
        return id
    }

    public func capture(authorization: String) throws {
        guard authorized[authorization] != nil else { throw PaymentError.unknownAuthorization }
        captured.insert(authorization)
    }

    public func void(authorization: String) {
        authorized[authorization] = nil
    }
}

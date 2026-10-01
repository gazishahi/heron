public enum LoyaltyTier: Int, Comparable {
    case none = 0, silver, gold, platinum

    public static func < (a: LoyaltyTier, b: LoyaltyTier) -> Bool { a.rawValue < b.rawValue }

    /// Orders placed in the last year that move a customer up.
    static func tier(forOrdersThisYear count: Int) -> LoyaltyTier {
        switch count {
        case 20...: return .platinum
        case 10...: return .gold
        case 3...: return .silver
        default: return .none
        }
    }
}

public struct Customer: Equatable {
    public let id: String
    public var name: String
    public var email: String
    public var ordersThisYear: Int

    public init(id: String, name: String, email: String, ordersThisYear: Int = 0) {
        self.id = id
        self.name = name
        self.email = email
        self.ordersThisYear = ordersThisYear
    }

    public var tier: LoyaltyTier { LoyaltyTier.tier(forOrdersThisYear: ordersThisYear) }
}

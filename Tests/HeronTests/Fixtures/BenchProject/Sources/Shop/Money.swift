/// An amount in cents, so arithmetic never rounds.
public struct Money: Equatable, Comparable, Hashable, CustomStringConvertible {
    public var cents: Int

    public init(cents: Int) { self.cents = cents }
    public init(dollars: Int) { self.cents = dollars * 100 }

    public static let zero = Money(cents: 0)

    public static func + (a: Money, b: Money) -> Money { Money(cents: a.cents + b.cents) }
    public static func - (a: Money, b: Money) -> Money { Money(cents: a.cents - b.cents) }
    public static func * (a: Money, quantity: Int) -> Money { Money(cents: a.cents * quantity) }
    public static func < (a: Money, b: Money) -> Bool { a.cents < b.cents }

    /// A percentage of this amount, rounded down to the cent.
    public func percent(_ rate: Int) -> Money { Money(cents: cents * rate / 100) }

    public var description: String {
        let sign = cents < 0 ? "-" : ""
        let value = abs(cents)
        let fraction = value % 100
        return "\(sign)$\(value / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}

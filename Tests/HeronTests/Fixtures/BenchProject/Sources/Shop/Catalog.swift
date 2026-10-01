/// What can be ordered.
public struct Product: Equatable, Hashable {
    public let sku: String
    public let name: String
    public let price: Money
    /// Heavy items ship separately and can't be packed with others.
    public let isOversized: Bool

    public init(sku: String, name: String, price: Money, isOversized: Bool = false) {
        self.sku = sku
        self.name = name
        self.price = price
        self.isOversized = isOversized
    }
}

public final class Catalog {
    private var products: [String: Product] = [:]
    private var stock: [String: Int] = [:]

    public init() {}

    public func add(_ product: Product, quantity: Int) {
        products[product.sku] = product
        stock[product.sku, default: 0] += quantity
    }

    public func product(sku: String) -> Product? { products[sku] }

    public func available(sku: String) -> Int { stock[sku] ?? 0 }

    /// Takes items out of stock; false (and nothing taken) if there aren't enough.
    public func reserve(sku: String, quantity: Int) -> Bool {
        guard available(sku: sku) >= quantity else { return false }
        stock[sku, default: 0] -= quantity
        return true
    }

    /// Puts reserved items back, when an order doesn't go through.
    public func release(sku: String, quantity: Int) {
        stock[sku, default: 0] += quantity
    }
}

public struct LineItem: Equatable {
    public let product: Product
    public var quantity: Int

    public var total: Money { product.price * quantity }
}

public enum OrderStatus: Equatable {
    case draft
    case placed
    case paid
    case picking
    case packed
    case shipped(trackingNumber: String)
    case delivered
    case cancelled(reason: String)
}

public enum OrderError: Error, Equatable {
    case empty
    case outOfStock(sku: String)
    case notAllowed(from: OrderStatus, action: String)
    case paymentDeclined(String)
}

/// One customer's order, from the cart to the doorstep.
public struct Order: Equatable {
    public let id: String
    public let customerID: String
    public private(set) var items: [LineItem] = []
    public private(set) var status: OrderStatus = .draft
    public var couponCode: String?
    /// Filled in when the order is placed: what was charged, after discounts.
    public private(set) var chargedTotal: Money?

    public init(id: String, customerID: String) {
        self.id = id
        self.customerID = customerID
    }

    public var subtotal: Money { items.reduce(.zero) { $0 + $1.total } }

    public mutating func add(_ product: Product, quantity: Int) throws {
        guard status == .draft else { throw OrderError.notAllowed(from: status, action: "add items") }
        if let index = items.firstIndex(where: { $0.product.sku == product.sku }) {
            items[index].quantity += quantity
        } else {
            items.append(LineItem(product: product, quantity: quantity))
        }
    }

    mutating func markPlaced(total: Money) throws {
        guard status == .draft else { throw OrderError.notAllowed(from: status, action: "place") }
        guard !items.isEmpty else { throw OrderError.empty }
        chargedTotal = total
        status = .placed
    }

    mutating func markPaid() throws {
        guard status == .placed else { throw OrderError.notAllowed(from: status, action: "pay") }
        status = .paid
    }

    mutating func advance(to next: OrderStatus) throws {
        switch (status, next) {
        case (.paid, .picking), (.picking, .packed), (.packed, .shipped), (.shipped, .delivered):
            status = next
        default:
            throw OrderError.notAllowed(from: status, action: "advance")
        }
    }

    mutating func markCancelled(reason: String) {
        status = .cancelled(reason: reason)
    }
}

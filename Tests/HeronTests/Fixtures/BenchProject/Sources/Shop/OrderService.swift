/// What the API layer calls: every order operation goes through here, which keeps stock,
/// payments, the warehouse and notifications in step.
public final class OrderService {
    private let catalog: Catalog
    private let pricing: PricingEngine
    private let payments: PaymentGateway
    private let warehouse: Warehouse
    private let notifier: Notifier
    private var customers: [String: Customer] = [:]
    private(set) var orders: [String: Order] = [:]
    /// The authorization held for each placed order, until it's captured or voided.
    private var authorizations: [String: String] = [:]
    private var nextOrder = 1

    public init(catalog: Catalog, pricing: PricingEngine, payments: PaymentGateway, warehouse: Warehouse, notifier: Notifier) {
        self.catalog = catalog
        self.pricing = pricing
        self.payments = payments
        self.warehouse = warehouse
        self.notifier = notifier
    }

    public func register(_ customer: Customer) { customers[customer.id] = customer }

    public func startOrder(customerID: String) -> String {
        let id = "ord_\(nextOrder)"
        nextOrder += 1
        orders[id] = Order(id: id, customerID: customerID)
        return id
    }

    public func addItem(orderID: String, sku: String, quantity: Int) throws {
        guard var order = orders[orderID], let product = catalog.product(sku: sku) else { return }
        try order.add(product, quantity: quantity)
        orders[orderID] = order
    }

    public func applyCoupon(orderID: String, code: String) {
        orders[orderID]?.couponCode = code
    }

    /// Reserves stock, prices the order and authorizes the payment. Anything that fails puts
    /// the stock back.
    public func placeOrder(orderID: String) throws -> PriceBreakdown {
        guard var order = orders[orderID], let customer = customers[order.customerID] else { throw OrderError.empty }
        var reserved: [(String, Int)] = []
        for item in order.items {
            guard catalog.reserve(sku: item.product.sku, quantity: item.quantity) else {
                reserved.forEach { catalog.release(sku: $0.0, quantity: $0.1) }
                throw OrderError.outOfStock(sku: item.product.sku)
            }
            reserved.append((item.product.sku, item.quantity))
        }
        let breakdown = pricing.price(order, for: customer)
        do {
            let authorization = try payments.authorize(customerID: customer.id, amount: breakdown.total)
            try order.markPlaced(total: breakdown.total)
            authorizations[orderID] = authorization
        } catch let error as PaymentError {
            reserved.forEach { catalog.release(sku: $0.0, quantity: $0.1) }
            if case .declined(let reason) = error { throw OrderError.paymentDeclined(reason) }
            throw error
        }
        orders[orderID] = order
        notifier.send(.orderPlaced(orderID: orderID, total: breakdown.total), to: customer)
        return breakdown
    }

    /// Captures the payment once the warehouse starts on the order.
    public func startFulfilment(orderID: String) throws {
        guard var order = orders[orderID], let authorization = authorizations[orderID] else { return }
        try payments.capture(authorization: authorization)
        try order.markPaid()
        try order.advance(to: .picking)
        authorizations[orderID] = nil
        orders[orderID] = order
    }

    public func pack(orderID: String) throws {
        guard var order = orders[orderID] else { return }
        _ = warehouse.pack(order)
        try order.advance(to: .packed)
        orders[orderID] = order
    }

    public func ship(orderID: String) throws -> String {
        guard var order = orders[orderID], let customer = customers[order.customerID] else { return "" }
        let tracking = warehouse.ship(order)
        try order.advance(to: .shipped(trackingNumber: tracking))
        orders[orderID] = order
        customers[customer.id]?.ordersThisYear += 1
        notifier.send(.orderShipped(orderID: orderID, trackingNumber: tracking), to: customer)
        return tracking
    }

    public func status(orderID: String) -> OrderStatus? { orders[orderID]?.status }
}

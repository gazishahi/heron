import XCTest
@testable import Shop

final class OrderServiceTests: XCTestCase {
    private func service() -> (OrderService, Catalog, FakeGateway, OutboxNotifier) {
        let catalog = Catalog()
        catalog.add(Product(sku: "mug", name: "Mug", price: Money(dollars: 12)), quantity: 10)
        catalog.add(Product(sku: "desk", name: "Desk", price: Money(dollars: 240), isOversized: true), quantity: 2)
        let gateway = FakeGateway()
        let notifier = OutboxNotifier()
        let service = OrderService(catalog: catalog, pricing: PricingEngine(coupons: [Coupon(code: "TEN", percentOff: 10)]),
                                   payments: gateway, warehouse: Warehouse(), notifier: notifier)
        service.register(Customer(id: "c1", name: "Ada", email: "ada@example.com", ordersThisYear: 12))
        return (service, catalog, gateway, notifier)
    }

    func testAnOrderGoesFromPlacedToShipped() throws {
        let (service, catalog, _, notifier) = service()
        let id = service.startOrder(customerID: "c1")
        try service.addItem(orderID: id, sku: "mug", quantity: 3)
        let price = try service.placeOrder(orderID: id)
        XCTAssertEqual(price.subtotal, Money(dollars: 36))
        XCTAssertEqual(catalog.available(sku: "mug"), 7)
        try service.startFulfilment(orderID: id)
        try service.pack(orderID: id)
        let tracking = try service.ship(orderID: id)
        XCTAssertEqual(service.status(orderID: id), .shipped(trackingNumber: tracking))
        XCTAssertEqual(notifier.sent.count, 2)
    }

    func testOutOfStockPutsEverythingBack() throws {
        let (service, catalog, _, _) = service()
        let id = service.startOrder(customerID: "c1")
        try service.addItem(orderID: id, sku: "mug", quantity: 2)
        try service.addItem(orderID: id, sku: "desk", quantity: 3)
        XCTAssertThrowsError(try service.placeOrder(orderID: id))
        XCTAssertEqual(catalog.available(sku: "mug"), 10)
    }
}

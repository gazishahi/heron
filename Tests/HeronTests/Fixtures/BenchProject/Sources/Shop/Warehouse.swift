/// Picking, packing and shipping. Oversized items go in their own parcel.
public final class Warehouse {
    public private(set) var parcels: [String: [[LineItem]]] = [:]
    private var nextTracking = 1000

    public init() {}

    /// Splits an order's items into parcels: everything regular together, each oversized unit alone.
    func pack(_ order: Order) -> [[LineItem]] {
        var regular: [LineItem] = []
        var separate: [[LineItem]] = []
        for item in order.items {
            if item.product.isOversized {
                for _ in 0..<item.quantity { separate.append([LineItem(product: item.product, quantity: 1)]) }
            } else {
                regular.append(item)
            }
        }
        let packed = (regular.isEmpty ? [] : [regular]) + separate
        parcels[order.id] = packed
        return packed
    }

    func ship(_ order: Order) -> String {
        nextTracking += 1
        return "TRK\(nextTracking)-\(parcels[order.id]?.count ?? 0)"
    }
}

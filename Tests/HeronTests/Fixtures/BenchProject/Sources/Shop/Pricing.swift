/// Coupons the marketing team hands out: a percentage off, with a minimum spend.
public struct Coupon: Equatable {
    public let code: String
    public let percentOff: Int
    public let minimumSubtotal: Money
    /// Some coupons can't be combined with the loyalty discount.
    public let stacksWithLoyalty: Bool

    public init(code: String, percentOff: Int, minimumSubtotal: Money = .zero, stacksWithLoyalty: Bool = true) {
        self.code = code
        self.percentOff = percentOff
        self.minimumSubtotal = minimumSubtotal
        self.stacksWithLoyalty = stacksWithLoyalty
    }
}

public struct PriceBreakdown: Equatable {
    public var subtotal: Money
    public var couponDiscount: Money
    public var loyaltyDiscount: Money
    public var shipping: Money

    public var total: Money { subtotal - couponDiscount - loyaltyDiscount + shipping }
}

/// Turns an order into what the customer pays.
public struct PricingEngine {
    public var coupons: [String: Coupon]
    public var freeShippingThreshold = Money(dollars: 50)
    public var flatShipping = Money(cents: 799)
    public var oversizedSurcharge = Money(dollars: 15)

    public init(coupons: [Coupon] = []) {
        self.coupons = Dictionary(uniqueKeysWithValues: coupons.map { ($0.code, $0) })
    }

    static func loyaltyRate(for tier: LoyaltyTier) -> Int {
        switch tier {
        case .none: return 0
        case .silver: return 3
        case .gold: return 5
        case .platinum: return 8
        }
    }

    public func price(_ order: Order, for customer: Customer) -> PriceBreakdown {
        let subtotal = order.subtotal
        var couponDiscount = Money.zero
        var coupon: Coupon?
        if let code = order.couponCode, let found = coupons[code], subtotal >= found.minimumSubtotal {
            coupon = found
            couponDiscount = subtotal.percent(found.percentOff)
        }
        // The loyalty discount applies to what's left after the coupon, unless the coupon
        // doesn't stack, in which case the customer gets whichever is larger.
        let loyaltyRate = Self.loyaltyRate(for: customer.tier)
        var loyaltyDiscount = (subtotal - couponDiscount).percent(loyaltyRate)
        if let coupon, !coupon.stacksWithLoyalty {
            let loyaltyAlone = subtotal.percent(loyaltyRate)
            if loyaltyAlone > couponDiscount {
                couponDiscount = .zero
                loyaltyDiscount = loyaltyAlone
            } else {
                loyaltyDiscount = .zero
            }
        }
        return PriceBreakdown(subtotal: subtotal, couponDiscount: couponDiscount, loyaltyDiscount: loyaltyDiscount,
                              shipping: shipping(for: order, discounted: subtotal - couponDiscount - loyaltyDiscount))
    }

    func shipping(for order: Order, discounted: Money) -> Money {
        let oversized = order.items.filter { $0.product.isOversized }.reduce(0) { $0 + $1.quantity }
        let base = discounted >= freeShippingThreshold ? Money.zero : flatShipping
        return base + oversizedSurcharge * oversized
    }
}

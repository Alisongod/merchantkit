public struct PurchaseSet {
    fileprivate let storage: [String : Purchase]
    
    internal init<Purchases : Sequence>(from purchases: Purchases) where Purchases.Iterator.Element == Purchase {
        var storage = [String : Purchase]()
        
        for purchase in purchases {
            storage[purchase.productIdentifier] = purchase
        }
        
        self.storage = storage
    }
    
    public func purchase(for product: Product) -> Purchase? {
        return self.storage[product.identifier]
    }
    
    public func sortedByPrice(ascending: Bool) -> [Purchase] {
        return self.storage.values.sorted(by: { a, b in
            let aPrice = a.price.value.0
            let bPrice = b.price.value.0
            
            return ascending && aPrice.compare(bPrice) == .orderedAscending || !ascending && aPrice.compare(bPrice) == .orderedDescending
        })
    }
}

extension PurchaseSet : Sequence {
    public var underestimatedCount: Int {
        return self.storage.count
    }
    
    public func makeIterator() -> AnyIterator<Purchase> {
        return AnyIterator(self.storage.values.makeIterator())
    }
}

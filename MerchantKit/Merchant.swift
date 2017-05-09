import Foundation
import StoreKit

public final class Merchant {
    public let delegate: MerchantDelegate
    
    fileprivate let storage: PurchaseStorage
    fileprivate let transactionObserver = StoreKitTransactionObserver()
    
    fileprivate var _registeredProducts = [String : Product]() // TODO: Consider alternative data structure
    fileprivate var activeTasks = [MerchantTask]()
    
    fileprivate var purchaseObservers = Buckets<String, MerchantPurchaseObserver>()
    
    fileprivate var receiptFetchers: [StoreKitReceiptDataFetcher.FetchPolicy : StoreKitReceiptDataFetcher] = [:]
    fileprivate var identifiersForPendingObservedPurchases = Set<String>()
    
    public fileprivate(set) var isLoading: Bool = false
    
    /// Create a `Merchant`, at application launch. Assign a consistent `storage` and a `delegate` to receive callbacks.
    public init(storage: PurchaseStorage, delegate: MerchantDelegate) {
        self.delegate = delegate
        self.storage = storage
    }
    
    /// Products must be registered before their states are consistently valid. Products should be registered as early as possible.
    /// See `LocalConfiguration` for a basic way to register products using a locally stored file.
    public func register<Products : Sequence>(_ products: Products) where Products.Iterator.Element == Product {
        for product in products {
            self._registeredProducts[product.identifier] = product
        }
    }
    
    /// Call this method at application launch. It performs necessary initialization routines.
    public func setup() {
        self.beginObservingTransactions()
        
        self.checkReceipt(updateProducts: .all, fetchPolicy: .onlyFetch, completion: { _ in
        
        })
    }
    
    /// Returns a registered product for a given `productIdentifier`, or `nil` if not found.
    public func product(withIdentifier productIdentifier: String) -> Product? {
        return self._registeredProducts[productIdentifier]
    }
    
    /// Returns the state for a `product`.
    public func state(for product: Product) -> PurchasedState {
        guard let record = self.storage.record(forProductIdentifier: product.identifier) else {
            return .notPurchased
        }
        
        switch product.kind {
            case .consumable:
                fatalError("consumable support not yet implemented")
            case .nonConsumable:
                return .isSold
            case .subscription(_):
                let now = Date()
                
                if let expiryDate = record.expiryDate, expiryDate < now {
                    return .notPurchased
                } else {
                    return .isSubscribed(expiryDate: record.expiryDate)
                }
        }
    }
    
    /// Restore the user's purchases. Calling this method may present modal UI.
    public func restorePurchasesTask() -> RestorePurchasesTask {
        return self.makeTask(initializing: {
            let task = RestorePurchasesTask(with: self)
            
            return task
        })
    }
    
    /// Find possible purchases for the given products. If `products` is empty, then the merchant looks up all purchases for all registered products.
    public func availablePurchasesTask(for products: Set<Product> = []) -> AvailablePurchasesTask {
        return self.makeTask(initializing: {
            let products = products.isEmpty ? Set(self._registeredProducts.values) : products
            
            let task = AvailablePurchasesTask(for: products, with: self)
    
            return task
        })
    }
    
    /// Begin buying a product, supplying a `purchase` fetched from the `AvailablePurchasesTask`.
    public func commitPurchaseTask(for purchase: Purchase) -> CommitPurchaseTask {
        return self.makeTask(initializing: {
            let task = CommitPurchaseTask(for: purchase, with: self)
            
            return task 
        })
    }
}

extension Merchant {
    internal func addPurchaseObserver(_ observer: MerchantPurchaseObserver, forProductIdentifier productIdentifier: String) {
        var observers = self.purchaseObservers[productIdentifier]
        
        if !observers.contains(where: { $0 === observer }) {
            observers.append(observer)
        }
        
        self.purchaseObservers[productIdentifier] = observers
    }
    
    internal func removePurchaseObserver(_ observer: MerchantPurchaseObserver, forProductIdentifier productIdentifier: String) {
        var observers = self.purchaseObservers[productIdentifier]
        
        if let index = observers.index(where: { $0 === observer }) {
            observers.remove(at: index)
            
            self.purchaseObservers[productIdentifier] = observers
        }
    }
    
    // Right now, Merchant relies on refreshing receipts to restore purchases. The implementation may be changed in future.
    internal func restorePurchases(completion: @escaping CheckReceiptCompletion) {
        self.checkReceipt(updateProducts: .all, fetchPolicy: .alwaysRefresh, completion: completion)
    }
}

extension Merchant {
    fileprivate func makeTask<Task : MerchantTask>(initializing creator: () -> Task) -> Task {
        let task = creator()
        
        self.addActiveTask(task)
        
        return task
    }
    
    private func addActiveTask(_ task: MerchantTask) {
        self.activeTasks.append(task)
        self.updateLoadingStateIfNecessary()
    }
    
    // Call on main thread only.
    internal func updateActiveTask(_ task: MerchantTask) {
        self.updateLoadingStateIfNecessary()
    }
    
    // Call on main thread only.
    internal func resignActiveTask(_ task: MerchantTask) {
        guard let index = self.activeTasks.index(where: { $0 === task }) else { return }
        
        self.activeTasks.remove(at: index)
        self.updateLoadingStateIfNecessary()
    }
}

extension Merchant {
    private var _isLoading: Bool {
        return !self.activeTasks.filter { $0.isStarted }.isEmpty || !self.receiptFetchers.isEmpty
    }
    
    /// Call on main thread only.
    fileprivate func updateLoadingStateIfNecessary() {
        let isLoading = self.isLoading
        let updatedIsLoading = self._isLoading
        
        if updatedIsLoading != isLoading {
            self.isLoading = updatedIsLoading
            
            self.delegate.merchantDidChangeLoadingState(self)
        }
    }
}

extension Merchant {
    fileprivate func beginObservingTransactions() {
        self.transactionObserver.delegate = self
        
        SKPaymentQueue.default().add(self.transactionObserver)
    }
    
    typealias CheckReceiptCompletion = (_ updatedProducts: Set<Product>, Error?) -> Void
    
    fileprivate func checkReceipt(updateProducts updateType: ReceiptUpdateType, fetchPolicy: StoreKitReceiptDataFetcher.FetchPolicy, completion: @escaping CheckReceiptCompletion) {
        let fetcher: StoreKitReceiptDataFetcher
        let isStarted: Bool
        
        if let activeFetcher = self.receiptFetchers[fetchPolicy] {
            fetcher = activeFetcher
            isStarted = true
        } else {
            fetcher = StoreKitReceiptDataFetcher(policy: fetchPolicy)
            isStarted = false
            
            self.receiptFetchers[fetchPolicy] = fetcher
        }
        
        fetcher.addCompletion { [weak self] dataResult in
            guard let strongSelf = self else { return }
            
            switch dataResult {
                case .succeeded(let receiptData):
                    strongSelf.validateReceipt(with: receiptData, completion: { validateResult in
                        switch validateResult {
                            case .succeeded(let receipt):
                                let updatedProducts = strongSelf.updateStorageWithValidatedReceipt(receipt, updateProducts: updateType)
                            
                                if !updatedProducts.isEmpty {
                                    DispatchQueue.main.async {
                                        strongSelf.didChangeState(for: updatedProducts)
                                    }
                                }
                                
                                completion(updatedProducts, nil)
                            case .failed(let error):
                                completion([], error)
                        }
                    })
                case .failed(let error):
                    completion([], error)
            }
            
            strongSelf.receiptFetchers.removeValue(forKey: fetchPolicy)
            
            if strongSelf.receiptFetchers.isEmpty && strongSelf.isLoading {
                DispatchQueue.main.async {
                    strongSelf.updateLoadingStateIfNecessary()
                }
            }
        }
        
        if !isStarted {
            fetcher.start()
            
            if !self.receiptFetchers.isEmpty && !self.isLoading {
                self.updateLoadingStateIfNecessary()
            }
        }
    }
    
    fileprivate func validateReceipt(with data: Data, completion: @escaping (Result<Receipt>) -> Void) {
        DispatchQueue.main.async {
            self.delegate.merchant(self, validate: data, completion: completion)
        }
    }
    
    fileprivate func updateStorageWithValidatedReceipt(_ receipt: Receipt, updateProducts updateType: ReceiptUpdateType) -> Set<Product> {
        var updatedProducts = Set<Product>()
        let productIdentifiers: Set<String>
        
        switch updateType {
            case .all:
                productIdentifiers = receipt.productIdentifiers
            case .specific(let identifiers):
                productIdentifiers = identifiers
        }
        
        for identifier in productIdentifiers {
            let entries = receipt.entries(forProductIdentifier: identifier)
            
            let isPurchased = !entries.isEmpty
            
            let result: StorageUpdateResult
            
            if isPurchased {
                let expiryDate = entries.flatMap { $0.expiryDate }.max()
                
                let record = PurchaseRecord(productIdentifier: identifier, expiryDate: expiryDate)
                
                result = self.storage.save(record)
            } else {
                result = self.storage.removeRecord(forProductIdentifier: identifier)
            }
            
            if result == .didChangeRecords, let product = self.product(withIdentifier: identifier) {
                updatedProducts.insert(product)
            }
        }
        
        if case .all = updateType {
            for (identifier, product) in self._registeredProducts {
                if !receipt.productIdentifiers.contains(identifier) {
                    if self.storage.removeRecord(forProductIdentifier: identifier) == .didChangeRecords {
                        updatedProducts.insert(product)
                    }
                }
            }
        }
        
        return updatedProducts
    }
    
    fileprivate enum ReceiptUpdateType {
        case all
        case specific(productIdentifiers: Set<String>)
    }
}

extension Merchant {
    /// Call on main thread only.
    fileprivate func didChangeState(for products: Set<Product>) {
        self.delegate.merchant(self, didChangeStateFor: products)
    }
}

extension Merchant : StoreKitTransactionObserverDelegate {
    func storeKitTransactionObserverWillUpdatePurchases(_ observer: StoreKitTransactionObserver) {
        
    }
    
    internal func storeKitTransactionObserver(_ observer: StoreKitTransactionObserver, didPurchaseProductWith identifier: String) {
        let record = PurchaseRecord(productIdentifier: identifier, expiryDate: nil)
        let result = self.storage.save(record)
        
        if let product = self.product(withIdentifier: identifier) {
            if result == .didChangeRecords {
                self.didChangeState(for: [product])
            }
            
            if case .subscription(_) = product.kind {
                self.identifiersForPendingObservedPurchases.insert(product.identifier) // we need to get the receipt to find the expiry date
            }
        }
        
        for observer in self.purchaseObservers[identifier] {
            observer.merchant(self, didCompletePurchaseForProductWith: identifier)
        }
    }
    
    func storeKitTransactionObserver(_ observer: StoreKitTransactionObserver, didFailToPurchaseWith error: Error, forProductWith identifier: String) {
        for observer in self.purchaseObservers[identifier] {
            observer.merchant(self, didFailPurchaseWith: error, forProductWith: identifier)
        }
    }
    
    func storeKitTransactionObserverDidUpdatePurchases(_ observer: StoreKitTransactionObserver) {
        self.checkReceipt(updateProducts: .specific(productIdentifiers: self.identifiersForPendingObservedPurchases), fetchPolicy: .onlyFetch, completion: { _ in })
        
        self.identifiersForPendingObservedPurchases.removeAll()
    }
}

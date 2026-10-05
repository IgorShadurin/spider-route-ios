import Foundation
import StoreKit
import UIKit

enum OfferCodePresenterKind: Equatable {
    case legacyPaymentQueue
    case modernAppStore
}

enum OfferCodePresenterSelector {
    static func kind(forMajorVersion majorVersion: Int) -> OfferCodePresenterKind {
        majorVersion >= 16 ? .modernAppStore : .legacyPaymentQueue
    }
}

enum PurchasePolicy {
    static func canStart(entitled: Bool, activity: SubscriptionStore.Activity) -> Bool {
        guard !entitled else { return false }
        return activity == .idle || activity == .loadingProduct
    }

    static func blocksConflictingActions(_ activity: SubscriptionStore.Activity) -> Bool {
        activity == .purchasing || activity == .pending || activity == .restoring || activity == .redeemingOfferCode
    }
}

enum OfferCodeRedemptionOutcome: Equatable {
    case entitled
    case unchanged
    case failed
}

enum SubscriptionFailure: Equatable {
    case productLoad
    case purchase
    case verification
    case pending
    case restore

    var key: String {
        switch self {
        case .productLoad: "paywall_error_product"
        case .purchase: "paywall_error_purchase"
        case .verification: "paywall_error_verification"
        case .pending: "paywall_error_pending"
        case .restore: "paywall_error_restore"
        }
    }
}

enum AccessPlan: String, CaseIterable {
    case yearly, lifetime

    var productID: String {
        switch self {
        case .yearly: SubscriptionStore.yearlyProductID
        case .lifetime: SubscriptionStore.lifetimeProductID
        }
    }
    var productType: Product.ProductType { self == .yearly ? .autoRenewable : .nonConsumable }
    var fallbackPrice: String { self == .yearly ? "$9.99" : "$19.99" }
    var actionKey: String { self == .yearly ? "paywall_subscribe" : "paywall_buy_lifetime" }
}

@MainActor
final class SubscriptionStore: ObservableObject {
    nonisolated static let lifetimeProductID = "com.wowcoded.speedometergps.lifetime"
    nonisolated static let yearlyProductID = "com.wowcoded.speedometergps.plus.yearly"
#if DEBUG
    static let debugPaidModeKey = "speedometer_debug_paid_mode"
#endif

    enum Activity: Equatable {
        case idle
        case loadingProduct
        case purchasing
        case pending
        case restoring
        case redeemingOfferCode
        case success
    }

    @Published private(set) var products: [String: Product] = [:]
    var product: Product? { products[Self.yearlyProductID] }
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var isEntitled = false
    @Published private(set) var failure: SubscriptionFailure?

    private var productLoadTask: Task<[Product], Error>?
    private var updatesTask: Task<Void, Never>?
#if DEBUG
    private let debugDefaults: UserDefaults
#endif

    init(observeTransactions: Bool = true, debugDefaults: UserDefaults = .standard) {
#if DEBUG
        self.debugDefaults = debugDefaults
        if let paidMode = debugDefaults.object(forKey: Self.debugPaidModeKey) as? Bool {
            isEntitled = paidMode
        }
#endif
        if observeTransactions { observeUpdates() }
    }

    deinit { updatesTask?.cancel() }

    var canStartPurchase: Bool {
        PurchasePolicy.canStart(entitled: isEntitled, activity: activity)
    }

    var blocksConflictingActions: Bool {
        PurchasePolicy.blocksConflictingActions(activity)
    }

    // App Store Connect does not permit editing the legacy localized name of an
    // ACTIVE subscription. Use StoreKit's name when it matches the approved
    // concise identity, otherwise protect the card with the local presentation
    // alias. StoreKit remains authoritative for price, period, and entitlement.
    var displayTitle: String {
        let approvedTitle = L10n.tr("paywall_product_title")
        guard let storeTitle = product?.displayName, storeTitle == approvedTitle else {
            return approvedTitle
        }
        return storeTitle
    }
    var displayPrice: String { displayPrice(for: .yearly) }
    func displayPrice(for plan: AccessPlan) -> String {
        products[plan.productID]?.displayPrice ?? plan.fallbackPrice
    }
    var displayPeriod: String { L10n.tr("paywall_period_year") }

    func prepare() async {
        guard activity == .idle else { return }
        activity = .loadingProduct
        failure = nil
        await refreshEntitlement()
        guard products.count < AccessPlan.allCases.count, !isEntitled else {
            if activity == .loadingProduct { activity = .idle }
            return
        }
        do {
            _ = try await loadExactProduct(for: .yearly)
        } catch {
            failure = .productLoad
        }
        if activity == .loadingProduct { activity = .idle }
    }

    @discardableResult
    func purchase(plan: AccessPlan = .yearly) async -> Bool {
        guard canStartPurchase else { return false }
        activity = .purchasing
        failure = nil

        await refreshEntitlement()
        if isEntitled { activity = .success; return true }

        do {
            let purchaseProduct = try await loadExactProduct(for: plan)
            guard purchaseProduct.id == plan.productID, purchaseProduct.type == plan.productType else {
                failure = .verification
                activity = .idle
                return false
            }
            let result = try await purchaseProduct.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification, transaction.productID == plan.productID else {
                    failure = .verification
                    activity = .idle
                    return false
                }
                await transaction.finish()
                applyEntitlement(true)
                activity = .success
                return true
            case .pending:
                activity = .pending
                failure = .pending
                return false
            case .userCancelled:
                activity = .idle
                return false
            @unknown default:
                failure = .purchase
                activity = .idle
                return false
            }
        } catch {
            failure = .purchase
            activity = .idle
            return false
        }
    }

    @discardableResult
    func restore() async -> Bool {
        guard !blocksConflictingActions else { return false }
        activity = .restoring
        failure = nil
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !isEntitled { failure = .restore }
            activity = .idle
            return isEntitled
        } catch {
            failure = .restore
            activity = .idle
            return false
        }
    }

    func redeemOfferCode(in scene: UIWindowScene) async -> OfferCodeRedemptionOutcome {
        await redeemOfferCode {
            if #available(iOS 16.0, *) {
                try await AppStore.presentOfferCodeRedeemSheet(in: scene)
            } else {
                SKPaymentQueue.default().presentCodeRedemptionSheet()
            }
        }
    }

    func redeemOfferCode(
        using presentation: @MainActor () async throws -> Void
    ) async -> OfferCodeRedemptionOutcome {
        guard !blocksConflictingActions else { return .unchanged }
        activity = .redeemingOfferCode
        failure = nil

        do {
            try await presentation()
            await refreshEntitlement()
            activity = isEntitled ? .success : .idle
            return isEntitled ? .entitled : .unchanged
        } catch {
            activity = .idle
            return .failed
        }
    }

    func refreshEntitlement() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  AccessPlan.allCases.contains(where: { $0.productID == transaction.productID }),
                  transaction.revocationDate == nil,
                  transaction.expirationDate.map({ $0 > Date() }) ?? true else { continue }
            active = true
            break
        }
        applyEntitlement(active)
    }

#if DEBUG
    var debugPaidModeEnabled: Bool { isEntitled }

    func toggleDebugAccessMode() {
        setDebugPaidMode(!isEntitled)
    }

    func resetDebugFreeMode() {
        setDebugPaidMode(false)
    }

    private func setDebugPaidMode(_ isPaid: Bool) {
        debugDefaults.set(isPaid, forKey: Self.debugPaidModeKey)
        isEntitled = isPaid
        activity = .idle
        failure = nil
    }
#endif

    private func applyEntitlement(_ verifiedEntitlement: Bool) {
#if DEBUG
        if let paidMode = debugDefaults.object(forKey: Self.debugPaidModeKey) as? Bool {
            isEntitled = paidMode
        } else {
            isEntitled = verifiedEntitlement
        }
#else
        isEntitled = verifiedEntitlement
#endif
    }

    private func loadExactProduct(for plan: AccessPlan) async throws -> Product {
        if let cached = products[plan.productID] { return cached }
        let task: Task<[Product], Error>
        if let existing = productLoadTask {
            task = existing
        } else {
            task = Task {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-storekit-slow") {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                }
#endif
                return try await Product.products(for: AccessPlan.allCases.map(\.productID))
            }
            productLoadTask = task
        }
        defer { productLoadTask = nil }
        let loaded = try await task.value
        for item in loaded { products[item.id] = item }
        guard let exact = products[plan.productID], exact.type == plan.productType else {
            throw StoreKitError.notAvailableInStorefront
        }
        return exact
    }

    private func observeUpdates() {
        updatesTask = Task { [weak self] in
            await self?.processUnfinishedTransactions()
            await self?.refreshEntitlement()

            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result, AccessPlan.allCases.contains(where: { $0.productID == transaction.productID }) {
                    await transaction.finish()
                    await self.refreshEntitlement()
                }
            }
        }
    }

    private func processUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result,
                  AccessPlan.allCases.contains(where: { $0.productID == transaction.productID }) else { continue }
            await transaction.finish()
        }
    }
}

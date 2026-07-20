#if os(iOS)
import Foundation
import Observation
import StoreKit

@MainActor
@Observable
public final class MobileStore {
    public static let monthlyProductID = "app.vaultty.remote.monthly"
    public static let annualProductID = "app.vaultty.remote.annual"

    public private(set) var products: [Product] = []
    public private(set) var hasEntitlement = false
    public private(set) var isLoading = false
    public var errorMessage: String?

    @ObservationIgnored nonisolated(unsafe) private var updatesTask: Task<Void, Never>?

    public init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await refreshEntitlement()
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: [
                Self.monthlyProductID,
                Self.annualProductID,
            ]).sorted { $0.price < $1.price }
            await refreshEntitlement()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func purchase(_ product: Product) async {
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refreshEntitlement()
            case .success(.unverified), .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshEntitlement() async {
        let productIDs = Set([Self.monthlyProductID, Self.annualProductID])
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  transaction.expirationDate.map({ $0 > Date() }) ?? true else { continue }
            entitled = true
            break
        }
        if !entitled {
            for product in products {
                guard let subscription = product.subscription,
                      let statuses = try? await subscription.status else { continue }
                if statuses.contains(where: {
                    switch $0.state {
                    case .subscribed, .inGracePeriod, .inBillingRetryPeriod:
                        true
                    case .expired, .revoked:
                        false
                    default:
                        false
                    }
                }) {
                    entitled = true
                    break
                }
            }
        }
        hasEntitlement = entitled
    }
}
#endif

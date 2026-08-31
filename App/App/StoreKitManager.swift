import Foundation
import StoreKit

/// CoFamio StoreKit2 purchase engine (Phase 2 — native iOS In-App Purchase).
///
/// This is the NATIVE counterpart to the existing web Stripe flow. The iOS app
/// remains web-only for the user-visible plan UI (no redesign); this module only
/// supplies a *native* purchase sheet that the web layer invokes on iOS so that
/// Apple's auto-renewable subscription can be bought with StoreKit instead of
/// Stripe. On web/desktop the existing Stripe checkout is completely untouched —
/// nothing here is reachable there.
///
/// Key behaviours (all StoreKit2 / iOS 15+):
///   - Loads the single auto-renewable subscription product whose id mirrors the
///     web plan (see `App Store Connect` product + `APPLE_IAP_PRODUCT` notes in
///     README-UPLOAD.md). Only the product *id* lives here — never secrets.
///   - Purchase sets `appAccountToken == the CoFamio userId` so the backend can
///     tie the transaction to the account via `/api/billing/apple/sync` and App
///     Store Server Notifications.
///   - On success returns the StoreKit2 JWS (`signedTransactionInfo`) + environment
///     to the JS layer (which POSTs `/api/billing/apple/sync`), and ALSO triggers a
///     native POST as a belt-and-braces fallback.
///   - Listens to `Transaction.updates` for renewals/refunds, restores purchases
///     via `AppStore.sync()`, and tracks the current entitlement so the web layer
///     can refresh via `GET /api/billing/status`.
///
/// This module is dormant-safe: it exposes no data until a purchase/restore/status
/// call is made, and it never reads or writes any credential. There is nothing to
/// enable here — the whole Apple path is additionally gated server-side by the
/// `APPLE_IAP_ENABLED` env switch (see APPLE-IAP-DESIGN.md).
final class StoreKitManager: NSObject {

    static let shared = StoreKitManager()

    // Product id for the single CoFamio plan. This is the App Store Connect
    // product id and mirrors the server default for APPLE_IAP_PRODUCT.
    // Keep in sync with App Store Connect (Phase 3 owner checklist).
    let productId = "com.cofamio.app.monthly"

    /// Native -> backend sync callback (installed by ViewController, which owns the
    /// web view's cookie store so it can POST /api/billing/apple/sync with the
    /// user's session).
    var onSyncTransaction: ((_ signedTransactionInfo: String, _ environment: String) -> Void)?

    /// Native -> JS status callback (installed by ViewController to deliver
    /// entitlement updates into the page via `window.CoFamioNative.__setIapStatus`).
    var onStatusChange: ((EntitlementStatus) -> Void)?

    // MARK: - Entitlement model (mirrors the server's `apple_subscriptions` shape,
    // used only for local caching and the JS status push).

    struct EntitlementStatus {
        var entitled: Bool
        var plan: String?
        var productId: String?
        var environment: String?
        var expiryMs: Double?
        var source: String

        func toJSONObject() -> [String: Any] {
            var d: [String: Any] = [
                "entitled": entitled,
                "source": source,
            ]
            if let p = plan { d["plan"] = p }
            if let pid = productId { d["productId"] = pid }
            if let e = environment { d["environment"] = e }
            if let ms = expiryMs { d["expiryMs"] = ms }
            return d
        }

        static let none = EntitlementStatus(entitled: false, plan: nil, productId: nil,
                                            environment: nil, expiryMs: nil, source: "none")
    }

    private var productsCache: [String: Product] = [:]
    private var lastStatus = EntitlementStatus.none
    /// Keep a strong Task handle for the transaction-updates stream so it never
    /// deallocs while the app is alive.
    private var updatesTask: Task<Void, Never>?

    private(set) var isListening = false

    // MARK: - Lifetime

    /// Call once at app launch (AppDelegate/ViewController) to observe renewals,
    /// refunds and entitlement resets, and to seed a locally-cached status.
    func startListening() {
        guard !isListening else { return }
        isListening = true
        updatesTask = Task { [weak self] in
            await self?.listenForUpdates()
        }
        Task { [weak self] in
            guard let self else { return }
            let status = await self.currentEntitlement()
            self.publish(status)
        }
    }

    // MARK: - Products

    /// Load the StoreKit product (the single CoFamio plan) from the App Store.
    /// Returns the already-cached value when loaded. Empty when StoreKit has no
    /// product yet (e.g. not configured in App Store Connect / not signed in to a
    /// sandbox account) — the purchase call then reports a clean error.
    func loadProducts() async -> [Product] {
        if !productsCache.isEmpty { return Array(productsCache.values) }
        do {
            let products = try await Product.products(for: [productId])
            var byId: [String: Product] = [:]
            for p in products { byId[p.id] = p }
            productsCache = byId
            return Array(byId.values)
        } catch {
            NSLog("[CoFamioIAP] loadProducts failed: \(error.localizedDescription)")
            return []
        }
    }

    func productId(forPlan planId: String) -> String {
        productId // single-plan pricing — every purchase uses the one CoFamio product
    }

    // MARK: - Purchase (StoreKit2)

    /// Present the system StoreKit purchase sheet for the CoFamio plan.
    ///
    /// - Parameters:
    ///   - planId: the web plan id ("cofamio" — matches BillingCard). Single-plan
    ///     pricing always buys the one CoFamio product.
    ///   - appAccountToken: the logged-in CoFamio **userId** (a UUID). Used as the
    ///     StoreKit `appAccountToken` so the backend can attribute the purchase.
    func purchase(planId: String, appAccountToken token: UUID) async -> [String: Any] {
        let productId = productId(forPlan: planId)
        let products = await loadProducts()
        guard let product = products.first(where: { $0.id == productId }) else {
            return ["ok": false, "status": "failed",
                    "error": "Product '\(productId)' is not available. Check the App Store Connect subscription products and that you are signed in to a StoreKit sandbox account."]
        }
        do {
            let result = try await product.purchase(options: [.appAccountToken(token)])
            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                await transaction.finish()
                let signed = verification.jwsRepresentation   // the JWS the backend verifies
                let env = Self.environmentLabel(transaction.environment)
                let status = entitlement(forPlan: Self.plan(forProductId: transaction.productID),
                                         productId: transaction.productID,
                                         environment: env,
                                         expiryMs: transaction.expirationDate?.timeIntervalSince1970)
                publish(status)
                // Forward to the backend (native belt-and-braces) AND hand the JWS
                // to JS so it can POST /api/billing/apple/sync and refresh status.
                onSyncTransaction?(signed, env)
                return [
                    "ok": true,
                    "status": "success",
                    "signedTransactionInfo": signed,   // JWS the backend verifies
                    "environment": env,
                    "entitlement": status.toJSONObject(),
                ]
            case .pending:
                return ["ok": true, "status": "pending"]
            case .userCancelled:
                return ["ok": true, "status": "cancelled"]
            @unknown default:
                return ["ok": false, "status": "failed", "error": "Unknown purchase result"]
            }
        } catch {
            NSLog("[CoFamioIAP] purchase failed: \(error.localizedDescription)")
            return ["ok": false, "status": "failed", "error": error.localizedDescription]
        }
    }

    // MARK: - Restore

    /// Ask StoreKit to sync the user's previous purchases and re-publish the
    /// current entitlement. Returns a JS-friendly result.
    func restorePurchases() async -> [String: Any] {
        do {
            try await AppStore.sync()
            let status = await currentEntitlement()
            publish(status)
            return ["ok": true, "entitlement": status.toJSONObject()]
        } catch {
            NSLog("[CoFamioIAP] restore failed: \(error.localizedDescription)")
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    // MARK: - Entitlement

    /// The user's current StoreKit entitlement (from `Transaction.currentEntitlements`),
    /// favouring an active, not-revoked subscription.
    func currentEntitlement() async -> EntitlementStatus {
        var active: Transaction?
        for await result in Transaction.currentEntitlements {
            guard let tx = try? Self.checkVerified(result) else { continue }
            guard tx.revocationDate == nil else { continue }
            if tx.expirationDate == nil || tx.expirationDate! > Date() {
                active = tx
                break
            }
        }
        guard let tx = active else {
            lastStatus = .none
            return .none
        }
        let status = entitlement(forPlan: Self.plan(forProductId: tx.productID),
                                 productId: tx.productID,
                                 environment: Self.environmentLabel(tx.environment),
                                 expiryMs: tx.expirationDate?.timeIntervalSince1970)
        lastStatus = status
        return status
    }

    var status: EntitlementStatus { lastStatus }

    private func entitlement(forPlan plan: String, productId: String, environment: String, expiryMs: Double?) -> EntitlementStatus {
        EntitlementStatus(entitled: true, plan: plan, productId: productId,
                          environment: environment, expiryMs: expiryMs, source: "apple")
    }

    // MARK: - Transaction updates (renewals / refunds / resets)

    private func listenForUpdates() async {
        for await update in Transaction.updates {
            do {
                let transaction = try Self.checkVerified(update)
                // Renewal / refund / reset — push to the backend and refresh status.
                onSyncTransaction?(update.jwsRepresentation, Self.environmentLabel(transaction.environment))
                let status = entitlement(forPlan: Self.plan(forProductId: transaction.productID),
                                         productId: transaction.productID,
                                         environment: Self.environmentLabel(transaction.environment),
                                         expiryMs: transaction.expirationDate?.timeIntervalSince1970)
                publish(status)
                await transaction.finish()
            } catch {
                NSLog("[CoFamioIAP] transaction update verification failed")
            }
        }
    }

    func publish(_ status: EntitlementStatus) {
        lastStatus = status
        onStatusChange?(status)
    }

    // MARK: - Helpers

    /// Whether the device lets the user make StoreKit purchases at all
    /// (parental controls / restrictions). Uses StoreKit 1's check, which applies
    /// to StoreKit 2 too.
    static var canMakePayments: Bool {
        SKPaymentQueue.canMakePayments()
    }

    static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw IAPError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    static func plan(forProductId productId: String) -> String {
        "cofamio" // single-plan pricing — every Apple product maps to "cofamio"
    }

    static func environmentLabel(_ env: Transaction.Environment) -> String {
        switch env {
        case .sandbox: return "Sandbox"
        case .xcode:   return "Xcode"
        case .production: return "Production"
        @unknown default: return "Production"
        }
    }

    enum IAPError: Error { case verificationFailed }
}

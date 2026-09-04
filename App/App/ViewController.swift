import UIKit
import WebKit
import Security

/// Hosts the CoFamio web app in a single, edge-to-edge WKWebView.
///
/// The released app loads the SPA from INSIDE the bundle via the
/// `cofamioapp://` custom scheme (`App/App/www` — see BundledSchemeHandler.swift),
/// NOT as a remote page from the live origin. Remote HTTPS is used only for
/// API/billing/push traffic (`appOrigin` + "/api/…"), never for the page itself.
///
/// Bridges (Capacitor-plugin pattern, but plain Apple frameworks):
///  - `window.CoFamioNative.secureGet/secureSet/secureRemove` — Keychain-backed
///    storage exposed as Promises to JS via WKScriptMessageHandlerWithReply
///    (iOS 15+; our deployment target).
///  - `window.CoFamioNative.pushToken / onPushToken` — APNs device token
///    delivered into the page; the web app POSTs it to /api/push/register.
///  - Deep links `cofamio://…` and universal links route into the web app.
final class ViewController: UIViewController, WKScriptMessageHandlerWithReply, WKNavigationDelegate {

    /// The live backend origin — used ONLY to build API/billing/push URLs
    /// (e.g. "…/api/billing/apple/sync"). The PAGE itself is bundled.
    static let appOrigin = "https://cofamio.ctonew.app"
    /// The custom scheme that serves the bundled SPA (see BundledSchemeHandler).
    static let appScheme = BundledSchemeHandler.scheme
    static let bundleID = "com.cofamio.app"

    private var webView: WKWebView!
    /// Latest APNs token. Re-delivered to the page on every load so the web
    /// shim can register it once an authenticated session exists.
    private var pushToken: String?
    /// Deep-link path queued before the web view finished first load.
    private var pendingDeepLinkPath: String?
    /// Native StoreKit2 purchase engine (Phase 2 — iOS In-App Purchase).
    private let iap = StoreKitManager.shared

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // Serve the bundled SPA via the cofamioapp:// custom scheme (release
        // builds load local assets; no remote page). API calls cross to the
        // live origin over HTTPS via the web layer's absolute fetch shim.
        if let www = Bundle.main.url(forResource: "www", withExtension: nil, subdirectory: "www") {
            config.setURLSchemeHandler(
                BundledSchemeHandler(bundleURL: www),
                forURLScheme: Self.appScheme
            )
        } else {
            NSLog("[CoFamioNative] WARNING: bundled www/ not found — app will not load")
        }

        // Inject the JS bridge at document start — before the web app's own
        // scripts run — so `window.CoFamioNative` exists on every page. In a
        // normal browser this object simply doesn't exist, which is exactly
        // what the web-side shim (src/lib/native.ts) feature-detects.
        contentController.addUserScript(bridgeUserScript())
        // Reply-style handler: JS `postMessage(...)` returns a Promise whose
        // resolution value is the native reply.
        contentController.addScriptMessageHandler(self, contentWorld: .page, name: "cofamioNative")
        config.userContentController = contentController

        // WKWebsiteDataStore.default() persists cookies (incl. the httpOnly
        // ff_session cookie) across app launches. Combined with the Keychain
        // bridge as a belt-and-braces store for app-level tokens, login
        // survives restarts even if WebKit ever clears its data.
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        // Zoom lockdown (2026-09, ROUND 2): the web app pins zoom in its viewport
        // meta, but WKWebView's underlying UIScrollView can still be pinch-zoomed
        // or rubber-band panned past the screen. Clamp the native zoom scales to
        // 1 (pinch-zoom off) and disable bounce so the page cannot be panned
        // "into the void". Vertical scrolling stays fully enabled — the app's
        // pages (calendar, records, documents) scroll normally inside this
        // scroll view; only zoom and overscroll bounce are removed.
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.isScrollEnabled = true
        webView.underPageBackgroundColor = UIColor.systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Launch straight into the app area (/app), NOT the marketing site —
        // that is the owner's intended app behavior. The bundled SPA shell
        // (index.html) hydrates the /app route, which then routes to the
        // dashboard (persisted session), onboarding, or the login screen as
        // appropriate. Session persistence via WKWebsiteDataStore() +
        // Keychain keeps a returning user logged in.
        loadBundledApp()

        // --- StoreKit 2 (Phase 2) ---
        // Native status changes are delivered into the page via __setIapStatus;
        // renewals/refunds/purchase-success are forwarded to the backend by a
        // direct POST /api/billing/apple/sync (cookie copied from the web store).
        iap.onStatusChange = { [weak self] status in
            self?.pushIapStatus(status)
        }
        iap.onSyncTransaction = { [weak self] signedTransactionInfo, environment in
            self?.postAppleSync(signedTransactionInfo, environment: environment)
        }
        // Start observing Transaction.updates (renewals/refunds) and seed status.
        iap.startListening()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Nothing to do — the web app already handles safe areas (PWA-grade CSS
        // uses env(safe-area-inset-*)). The web view is intentionally edge-to-edge.
    }

    // MARK: - Bundled app loading

    /// Load the app's own SPA shell from the bundle (cofamioapp://app). The
    /// bundled index.html hydrates the /app route client-side. Never a remote
    /// origin page load.
    private func loadBundledApp() {
        guard let url = Self.bundledURL(path: "/app") else { return }
        webView.load(URLRequest(url: url))
    }

    /// Build a bundled URL for an app path like "/app/calendar" or "app/calendar".
    /// Scheme is `cofamioapp://`; host is always "app" and the REAL route is the
    /// path ("/app", "/app/calendar"), so `window.location.pathname` seen by the
    /// SPA router is correct. The scheme handler joins host+path when resolving
    /// bundle files (assets live on host "assets").
    static func bundledURL(path: String, query: String? = nil) -> URL? {
        var p = path
        if !p.hasPrefix("/") { p = "/" + p }
        var comps = URLComponents()
        comps.scheme = appScheme
        comps.host = "app"
        comps.path = p
        comps.query = query
        return comps.url
    }

    // MARK: - Injected JS bridge

    private func bridgeUserScript() -> WKUserScript {
        // Keep this script self-contained and ES5-ish: it runs before the app's
        // own JS and must not trip over strict mode differences.
        let source = """
        (function () {
          if (window.__cofamioBridgeInstalled) { return; }
          window.__cofamioBridgeInstalled = true;
          var pendingDeepLink = null;
          var pushListeners = [];
          var pushTokenValue = null;
          var iapStatusListeners = [];
          var iapStatusValue = null;
          function call(action, payload) {
            // postMessage on a WKScriptMessageHandlerWithReply channel returns a
            // Promise that resolves with the native reply value.
            return window.webkit.messageHandlers.cofamioNative.postMessage(
              Object.assign({ action: action }, payload || {})
            );
          }
          window.CoFamioNative = {
          isNative: true,
          platform: 'ios',
          appVersion: '1.0.0',
          get pendingDeepLink() { return pendingDeepLink; },
          get pushToken() { return pushTokenValue; },
          // --- secure storage (Keychain-backed) ---
          secureGet: function (key) { return call('secureGet', { key: key }); },
          secureSet: function (key, value) { return call('secureSet', { key: key, value: value }); },
          secureRemove: function (key) { return call('secureRemove', { key: key }); },
          getPushToken: function () { return call('getPushToken', {}); },
          // --- navigation ---
          navigate: function (path) { return call('navigate', { path: path }); },
          // --- StoreKit 2 In-App Purchase (Phase 2) ---
          // Each method calls into the native StoreKitManager and returns a
          // Promise. On a plan purchase the resolved object carries the StoreKit2
          // JWS `signedTransactionInfo` + `environment` for the web layer to send
          // to POST /api/billing/apple/sync (the native side also posts directly).
          iap: {
            available: true,
            getProducts: function () { return call('iapGetProducts', {}); },
            purchase: function (planId, appAccountToken) {
              return call('iapPurchase', { planId: planId, appAccountToken: appAccountToken });
            },
            restore: function () { return call('iapRestore', {}); },
            getCurrentEntitlement: function () { return call('iapGetCurrentEntitlement', {}); },
            canMakePayments: function () { return call('iapCanMakePayments', {}); }
          },
          // --- native -> JS (never call these from the web app) ---
          onIapStatus: function (fn) {
            if (typeof fn !== 'function') { return; }
            iapStatusListeners.push(fn);
            if (iapStatusValue) { try { fn(iapStatusValue); } catch (e) {} }
          },
          offIapStatus: function (fn) {
            iapStatusListeners = iapStatusListeners.filter(function (f) { return f !== fn; });
          },
          __setIapStatus: function (status) {
            iapStatusValue = status || null;
            var listeners = iapStatusListeners.slice();
            for (var i = 0; i < listeners.length; i++) {
              try { listeners[i](iapStatusValue); } catch (e) {}
            }
          },
            // --- push token listeners ---
            onPushToken: function (fn) {
              if (typeof fn !== 'function') { return; }
              pushListeners.push(fn);
              if (pushTokenValue) { try { fn(pushTokenValue); } catch (e) {} }
            },
            offPushToken: function (fn) {
              pushListeners = pushListeners.filter(function (f) { return f !== fn; });
            },
            // --- native -> JS (never call these from the web app) ---
            __setPushToken: function (token) {
              pushTokenValue = token || null;
              var listeners = pushListeners.slice();
              for (var i = 0; i < listeners.length; i++) {
                try { listeners[i](pushTokenValue); } catch (e) {}
              }
            },
            __setPendingDeepLink: function (path) {
              pendingDeepLink = path || null;
            }
          };
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // MARK: - WKScriptMessageHandlerWithReply (native <-> JS bridge)

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            replyHandler(nil, "cofamioNative: invalid message payload")
            return
        }
        switch action {
        case "secureGet":
            guard let key = body["key"] as? String, !key.isEmpty else {
                replyHandler(nil, "cofamioNative: key required"); return
            }
            do {
                let value = try KeychainStore.read(service: KeychainStore.service, account: key)
                replyHandler(value ?? NSNull(), nil)
            } catch {
                replyHandler(nil, "cofamioNative: keychain read failed")
            }
        case "secureSet":
            guard let key = body["key"] as? String, !key.isEmpty else {
                replyHandler(nil, "cofamioNative: key required"); return
            }
            let value = body["value"] as? String ?? ""
            do {
                try KeychainStore.write(service: KeychainStore.service, account: key, value: value)
                replyHandler(true, nil)
            } catch {
                replyHandler(nil, "cofamioNative: keychain write failed")
            }
        case "secureRemove":
            guard let key = body["key"] as? String, !key.isEmpty else {
                replyHandler(nil, "cofamioNative: key required"); return
            }
            do {
                try KeychainStore.remove(service: KeychainStore.service, account: key)
                replyHandler(true, nil)
            } catch {
                replyHandler(nil, "cofamioNative: keychain remove failed")
            }
        case "getPushToken":
            replyHandler(pushToken ?? NSNull(), nil)
        case "navigate":
            guard let path = body["path"] as? String, !path.isEmpty, let url = Self.webURL(path: path) else {
                replyHandler(nil, "cofamioNative: bad path"); return
            }
            DispatchQueue.main.async { [weak self] in self?.webView.load(URLRequest(url: url)) }
            replyHandler(true, nil)
        case "iapGetProducts":
            Task { @MainActor in
                let products = await StoreKitManager.shared.loadProducts()
                let items = products.map { p -> [String: Any] in
                    var d: [String: Any] = [
                        "id": p.id,
                        "plan": StoreKitManager.plan(forProductId: p.id),
                        "displayName": p.displayName,
                        "displayPrice": p.displayPrice,
                    ]
                    d["price"] = p.price as NSNumber
                    return d
                }
                replyHandler(items, nil)
            }
        case "iapPurchase":
            guard let planId = body["planId"] as? String else {
                replyHandler(nil, "cofamioNative: planId required"); return
            }
            let tokenStr = body["appAccountToken"] as? String ?? ""
            guard let appAccountToken = UUID(uuidString: tokenStr) else {
                replyHandler(["ok": false, "status": "failed",
                              "error": "Invalid appAccountToken (expected a UUID CoFamio userId)."],
                             nil)
                return
            }
            Task { @MainActor in
                let result = await StoreKitManager.shared.purchase(planId: planId, appAccountToken: appAccountToken)
                replyHandler(result, nil)
            }
        case "iapRestore":
            Task { @MainActor in
                let result = await StoreKitManager.shared.restorePurchases()
                replyHandler(result, nil)
            }
        case "iapGetCurrentEntitlement":
            Task { @MainActor in
                let status = await StoreKitManager.shared.currentEntitlement()
                replyHandler(status.toJSONObject(), nil)
            }
        case "iapCanMakePayments":
            replyHandler(StoreKitManager.canMakePayments, nil)
        default:
            replyHandler(nil, "cofamioNative: unknown action '\(action)'")
        }
    }

    // MARK: - Deep links

    /// Route a cofamio:// scheme URL (or a universal-link https URL on our
    /// origin) into the web app. Queued until the web view can load it.
    func handleIncomingURL(_ url: URL) {
        guard let webURL = Self.webURL(from: url) else {
            NSLog("[CoFamioNative] ignoring non-app URL \(url.absoluteString)")
            return
        }
        let request = URLRequest(url: webURL)
        // Prime the page-level pendingDeepLink so the web app could consume it
        // (currently used for cofamio://reset?token=... which works purely by
        // loading the /reset-password route).
        let path = webURL.path + (webURL.query.map { "?" + $0 } ?? "")
        pendingDeepLinkPath = path
        guard webView != nil else { return } // didFinish will load the request below once ready
        let js = "window.CoFamioNative && window.CoFamioNative.__setPendingDeepLink(" + Self.jsonString(path) + ");"
        webView.evaluateJavaScript(js, completionHandler: nil)
        webView.load(request)
    }

    /// Map a native URL (scheme or universal) to a web URL. App-routing paths
    /// become BUNDLED cofamioapp:// URLs; https-on-our-origin deep links load
    /// the bundled path too (never the remote origin page).
    static func webURL(from url: URL) -> URL? {
        if url.scheme?.lowercased() == "cofamio" {
            var path = url.path // "/calendar", "/reset", "" for bare cofamio://
            // A bare cofamio:// (or cofamio:///) opens the app area, mirroring
            // cold-start behavior — never the marketing site.
            if path.isEmpty || path == "/" { path = "/app" }
            return bundledURL(path: path, query: url.query)
        }
        if let scheme = url.scheme?.lowercased(), scheme == "https",
           let host = url.host?.lowercased(), host == "cofamio.ctonew.app" || host.hasSuffix(".cofamio.ctonew.app") {
            // Universal link on our origin → route into the bundled SPA.
            let path = url.path.isEmpty ? "/app" : url.path
            return bundledURL(path: path, query: url.query)
        }
        return nil
    }

    /// Build a web URL from a path like "/app/calendar" or "app/calendar".
    /// The page is bundled, so this produces a cofamioapp:// URL.
    static func webURL(path: String) -> URL? {
        var p = path
        if !p.hasPrefix("/") { p = "/" + p }
        return bundledURL(path: p)
    }

    static func jsonString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: s),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\""
    }

    // MARK: - StoreKit 2 (Phase 2) — status push + backend sync

    /// Deliver a StoreKit entitlement status into the page so the web app can
    /// refresh its own entitlement state (e.g. after a renewal or refund).
    func pushIapStatus(_ status: StoreKitManager.EntitlementStatus) {
        guard webView != nil else { return }
        let json = (try? JSONSerialization.data(withJSONObject: status.toJSONObject()))
            .map { String(data: $0, encoding: .utf8) ?? "{}" } ?? "{}"
        let js = "window.CoFamioNative && window.CoFamioNative.__setIapStatus(" + json + ");"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Forward a verified StoreKit transaction (JWS + environment) to the backend
    /// as POST /api/billing/apple/sync, using the session cookie copied from the
    /// web view's cookie store (or the Keychain session token in bundled mode).
    /// The web layer performs the authoritative sync too; this covers
    /// renewals/refunds that arrive while JS isn't foregrounded.
    func postAppleSync(_ signedTransactionInfo: String, environment: String) {
        guard let url = URL(string: Self.appOrigin + "/api/billing/apple/sync") else { return }
        nativeAuthenticatedPost(to: url, body: [
            "signedTransactionInfo": signedTransactionInfo,
            "environment": environment,
        ], logTag: "[CoFamioIAP] apple sync")
    }

    // MARK: - Push token delivery

    /// Called by AppDelegate when the APNs token arrives. Delivers into the page
    /// (the web shim POSTs /api/push/register) and, as a fallback, POSTs
    /// directly with the session cookie copied from the web view's cookie store.
    func savePushToken(_ token: String) {
        pushToken = token
        guard webView != nil else { return } // applied once the webview loads (didFinish)
        let js = "window.CoFamioNative && window.CoFamioNative.__setPushToken(" + Self.jsonString(token) + ");"
        webView.evaluateJavaScript(js, completionHandler: nil)
        postPushTokenNative(token)
    }

    private func postPushTokenNative(_ token: String) {
        guard let url = URL(string: Self.appOrigin + "/api/push/register") else { return }
        nativeAuthenticatedPost(to: url, body: ["token": token, "platform": "ios"], logTag: "[CoFamioNative] push register")
    }

    /// POST JSON to an API endpoint with auth: the session cookie copied from the
    /// web view's cookie store when present (remote-shell and legacy behavior),
    /// otherwise the Keychain session token as `Authorization: Bearer …` (bundled
    /// mode — the custom-scheme page origin has no httpOnly cookie, but the server
    /// accepts the bearer fallback).
    private func nativeAuthenticatedPost(to url: URL, body: [String: Any], logTag: String) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            if !cookieHeader.isEmpty {
                self.sendNativePost(to: url, body: body, authHeader: ("Cookie", cookieHeader), logTag: logTag)
                return
            }
            self.fetchKeychainSession { token in
                guard let token, !token.isEmpty else {
                    NSLog("\(logTag) -> no session (no cookie, no keychain token)")
                    return
                }
                self.sendNativePost(to: url, body: body, authHeader: ("Authorization", "Bearer \(token)"), logTag: logTag)
            }
        }
    }

    /// Read the Keychain session token (stored at login as "ff_session=<token>").
    private func fetchKeychainSession(_ completion: @escaping (String?) -> Void) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.cofamio.app.secure",
            kSecAttrAccount as String: "cofamio.session",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let raw = String(data: data, encoding: .utf8) else {
            completion(nil)
            return
        }
        let token = raw.hasPrefix("ff_session=") ? raw : "ff_session=" + raw
        completion(token)
    }

    private func sendNativePost(to url: URL, body: [String: Any], authHeader: (String, String), logTag: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader.1, forHTTPHeaderField: authHeader.0)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            NSLog("\(logTag) -> \(status) error=\(error?.localizedDescription ?? "nil")")
        }.resume()
    }

    // MARK: - WKNavigationDelegate

    /// Navigation policy:
    ///   - cofamioapp:// (bundled SPA) — allow (the scheme handler serves assets).
    ///   - http/https — keep in-app (Stripe Checkout / 3DS stay in the same cookie
    ///     context; universal links to our origin route into the bundle).
    ///   - cofamio:// — handle as a deep link (mapped to a bundled route).
    ///   - mailto/tel — open in the system handler.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        switch scheme {
        case Self.appScheme:
            decisionHandler(.allow)
        case "http", "https":
            decisionHandler(.allow)
        case "cofamio":
            handleIncomingURL(url)
            decisionHandler(.cancel)
        case "mailto", "tel":
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Re-deliver state to the freshly loaded page (cold start, deep link
        // arrives before first load, or the user hard-navigated).
        if let token = pushToken {
            let js = "window.CoFamioNative && window.CoFamioNative.__setPushToken(" + Self.jsonString(token) + ");"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        if let path = pendingDeepLinkPath {
            let js = "window.CoFamioNative && window.CoFamioNative.__setPendingDeepLink(" + Self.jsonString(path) + ");"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - Keychain store

/// Minimal generic-password Keychain access for the secure-storage bridge.
/// Items are kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly (survive app
/// restarts; do NOT migrate to other devices, which is the right trade for
/// session-recovery secrets).
enum KeychainStore {
    static let service = "com.cofamio.app.secure"
    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    enum KeychainError: Error {
        case unexpected(OSStatus)
    }

    static func write(service: String, account: String, value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: accessible,
        ]
        // Upsert: delete any existing row for this account, then add.
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpected(status) }
    }

    static func read(service: String, account: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpected(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func remove(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpected(status)
        }
    }
}
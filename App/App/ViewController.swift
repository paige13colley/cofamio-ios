import UIKit
import WebKit
import Security

/// Hosts the live CoFamio web app in a single, edge-to-edge WKWebView.
///
/// Bridges (Capacitor-plugin pattern, but plain Apple frameworks):
///  - `window.CoFamioNative.secureGet/secureSet/secureRemove` — Keychain-backed
///    storage exposed as Promises to JS via WKScriptMessageHandlerWithReply
///    (iOS 15+; our deployment target).
///  - `window.CoFamioNative.pushToken / onPushToken` — APNs device token
///    delivered into the page; the web app POSTs it to /api/push/register.
///  - Deep links `cofamio://…` and universal links route into the web app.
final class ViewController: UIViewController, WKScriptMessageHandlerWithReply, WKNavigationDelegate {

    /// The live web app origin — the single source of truth for every URL the
    /// shell builds. The injected bridge, deep-link routing and navigation
    /// policy all derive from this.
    static let appOrigin = "https://cofamio.ctonew.app"
    static let bundleID = "com.cofamio.app"

    private var webView: WKWebView!
    /// Latest APNs token. Re-delivered to the page on every load so the web
    /// shim can register it once an authenticated session exists.
    private var pushToken: String?
    /// Deep-link path queued before the web view finished first load.
    private var pendingDeepLinkPath: String?

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // Inject the JS bridge at document start — before the web app's own
        // scripts run — so `window.CoFamioNative` exists on every page. In a
        // normal browser this object simply doesn't exist, which is exactly
        // what the web-side shim (src/lib/native.ts) feature-detects.
        contentController.addUserScript(bridgeUserScript())
        // Reply-style handler: JS `postMessage(...)` returns a Promise whose
        // resolution value is the native reply.
        contentController.add(self, name: "cofamioNative")
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
        webView.underPageBackgroundColor = UIColor.systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        if let url = URL(string: Self.appOrigin) {
            webView.load(URLRequest(url: url))
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Nothing to do — the web app already handles safe areas (PWA-grade CSS
        // uses env(safe-area-inset-*)). The web view is intentionally edge-to-edge.
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

    /// Map a native URL (scheme or universal) to a web URL.
    static func webURL(from url: URL) -> URL? {
        if url.scheme?.lowercased() == "cofamio" {
            var path = url.path // "/calendar", "/reset", "" for bare cofamio://
            if path.isEmpty || path == "/" { path = "" }
            let query = url.query.map { "?" + $0 } ?? ""
            return URL(string: appOrigin + path + query)
        }
        if let scheme = url.scheme?.lowercased(), scheme == "https",
           let host = url.host?.lowercased(), host == "cofamio.ctonew.app" || host.hasSuffix(".cofamio.ctonew.app") {
            return url // universal link already on our origin
        }
        return nil
    }

    /// Build a web URL from a path like "/app/calendar" or "app/calendar".
    static func webURL(path: String) -> URL? {
        var p = path
        if !p.hasPrefix("/") { p = "/" + p }
        return URL(string: appOrigin + p)
    }

    static func jsonString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: s),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\""
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
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            if !cookieHeader.isEmpty {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let body: [String: Any] = ["token": token, "platform": "ios"]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: request) { _, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                // 401 = no session in the web view yet; the JS shim retries once
                // the user logs in (native re-delivers the token on each load).
                NSLog("[CoFamioNative] push register -> \(status) error=\(error?.localizedDescription ?? "nil")")
            }.resume()
        }
    }

    // MARK: - WKNavigationDelegate

    /// Navigation policy: keep EVERYTHING http(s) inside the web view.
    /// Stripe Checkout (checkout.stripe.com and 3DS hosts) MUST stay in-app so
    /// the shared HTTPCookieStore keeps the user's session and the post-pay
    /// redirect lands back on cofamio.ctonew.app in the SAME context. Opening
    /// Stripe in the system browser would break the web-only subscription flow.
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
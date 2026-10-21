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
///  - `window.CoFamioNative.print/printHTML` — UIPrintInteractionController.
///  - `window.CoFamioNative.download(fileName, mimeType, base64)` — writes the
///    document bytes to a temp file and presents the system share sheet.
///  - Deep links `cofamio://…` and universal links route into the web app.
final class ViewController: UIViewController, WKScriptMessageHandlerWithReply, WKNavigationDelegate {

    /// The live backend origin — used ONLY to build API/billing/push URLs
    /// (e.g. "…/api/billing/apple/sync"). The PAGE itself is bundled.
    ///
    /// TEMPORARY FALLBACK (2026-10): the friendly hostname `cofamio.ctonew.app`
    /// is currently down (its binding was removed at the platform edge), so the
    /// shell talks to the hash-based production host instead. `appOrigin` is the
    /// single source of truth for BOTH the native API/billing/push URLs and the
    /// web-layer override in `bridgeUserScript()` — to go back to the friendly
    /// hostname, change the one assignment below (`apiOriginFallback` →
    /// `apiOriginPrimary`); nothing else needs editing.
    static let apiOriginPrimary = "https://cofamio.ctonew.app"
    /// Fallback origin used while `apiOriginPrimary` is down. Same production
    /// deployment, hash hostname.
    static let apiOriginFallback = "https://7923a795c396982e654b32182e912be1.ctonew.app"
    static let appOrigin = apiOriginFallback
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
        //
        // Resolve the bundled www/ directory under ANY layout the Xcode build
        // can produce (see bundledWWWURL()): a www/www group copy, a www
        // folder-reference copy at <bundle>/www (the Build 2 layout — the old
        // single subdirectory lookup looked for <bundle>/www/www, missed, and
        // the handler was never registered, leaving a white screen), or the
        // parent of the SPA's www/index.html.
        if let www = Self.bundledWWWURL() {
            config.setURLSchemeHandler(
                BundledSchemeHandler(bundleURL: www),
                forURLScheme: Self.appScheme
            )
        } else {
            NSLog("[CoFamioNative] WARNING: bundled www/ not found (checked www/www, www folder root, and www/index.html) — falling back to live site")
            // webView is created later in viewDidLoad, so defer the live load
            // until the next runloop turn (it is guaranteed non-nil by then).
            DispatchQueue.main.async { [weak self] in
                self?.loadLiveFallback()
            }
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
        // Zoom lockdown (2026-09, ROUND 3): the web app pins zoom in its viewport
        // meta, but WKWebView's underlying UIScrollView can still be pinch-zoomed
        // or rubber-band panned past the screen. Clamp the native zoom scale to a
        // maximum of 1 (pinch-zoom off) and disable bounce so the page cannot be
        // panned "into the void". Vertical scrolling stays fully enabled — the
        // app's pages (calendar, records, documents) scroll normally inside this
        // scroll view; only zoom and overscroll bounce are removed.
        //
        // ROUND 3 (Build 4 zoom fix): minimumZoomScale was 1.0, which made
        // WKWebView treat content wider than the viewport as already zoomed-in
        // ("everything looks enlarged" on a physical iPhone). Lowering the
        // minimum to 0.1 lets the page fit the device width at scale 1 — this
        // prevents the "content wider than viewport appears magnified" artifact
        // while maximumZoomScale = 1.0 still disables pinch-zoom. The app UI now
        // fills the device width with no horizontal scroll and no enlargement.
        webView.scrollView.minimumZoomScale = 0.1
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

    /// Resolve the bundled SPA's `www` directory, trying each layout the Xcode
    /// build can actually produce, in order:
    ///   1. `Bundle.main.url(forResource:"www", … subdirectory:"www")` — a
    ///      blue-folder group copy lands at <bundle>/www/www.
    ///   2. `Bundle.main.url(forResource:"www", …)` — a folder-reference copy
    ///      lands at <bundle>/www (Build 2 layout; the old single lookup
    ///      checked only #1 and missed this, so the scheme handler was never
    ///      registered and the web view stayed white).
    ///   3. `www/index.html` — with its parent directory as the bundle root
    ///      (covers a layout where only the HTML file is identifiable).
    /// Returns the first non-nil, or nil if no variant is present.
    private static func bundledWWWURL() -> URL? {
        if let www = Bundle.main.url(forResource: "www", withExtension: nil, subdirectory: "www") {
            return www
        }
        if let www = Bundle.main.url(forResource: "www", withExtension: nil) {
            // Folder-reference copies land at <bundle>/www; guard against the
            // lookup returning a file (or a path without the www name).
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: www.path, isDirectory: &isDirectory),
               isDirectory.boolValue, www.lastPathComponent == "www" {
                return www
            }
        }
        if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") {
            return index.deletingLastPathComponent()
        }
        return nil
    }

    /// Fallback used when the bundled www/ is missing: load the live site's
    /// /app so the app never sits on a white screen. Kept minimal — the custom
    /// scheme handler (bundled mode) remains the primary path.
    private func loadLiveFallback() {
        guard let url = URL(string: "https://cofamio.ctonew.app/app") else { return }
        webView.load(URLRequest(url: url))
    }

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
          // API-origin override for the web layer. The bundled SPA installs a
          // fetch shim at module scope that reads this value (native.ts /
          // `nativeApiBase()`), rewriting cofamioapp://…/api/… requests to this
          // origin — so it must be set here, at document start, before the app
          // bundle runs. Interpolated from ViewController.appOrigin (the SINGLE
          // constant above) so the native URLs and the web-layer URLs can never
          // drift; that constant currently points at the hash-host fallback
          // because the friendly hostname cofamio.ctonew.app is down.
          window.__COFAMIO_API_ORIGIN__ = '\(Self.appOrigin)';
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
          // --- native print (iOS) ---
          // Renders print-friendly HTML via UIPrintInteractionController (the
          // standard iOS print sheet with printer picker + Save-to-PDF).
          // window.print() is a silent no-op in WKWebView, so the web app's
          // Print buttons call this when CoFamioNative.isNative. Resolves
          // { ok: true } when the sheet is presented (user may still cancel
          // in the sheet itself), { ok: false, error } otherwise.
          print: function (html) { return call('print', { html: html || '' }); },
          printHTML: function (html) { return call('print', { html: html || '' }); },
          // --- native file save/share (iOS) ---
          // The web layer already fetched the document bytes through /api; it
          // hands them here as base64. Native writes a temp file and presents
          // the system share sheet (Save to Files, Mail, AirDrop…). This is the
          // ONLY way to hand a file to the OS from WKWebView: `<a download>` with
          // a data:/blob: URL is a NAVIGATION, and our navigation policy cancels
          // schemes it does not know (see decidePolicyFor), which is exactly why
          // the old Download button did nothing on device.
          // Resolves { ok:true } once the file is written and the sheet is
          // presented, { ok:true, cancelled:true } if the user dismisses it,
          // { ok:false, error } on failure.
          download: function (fileName, mimeType, base64) {
            return call('download', { fileName: fileName || '', mimeType: mimeType || '', base64: base64 || '' });
          },
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
        case "print":
            // Native print: render the web layer's print-friendly HTML through
            // UIPrintInteractionController. Must run on the main thread and
            // present from this view controller. The HTML string is loaded into
            // an offscreen UIPrintFormatter via UIMarkupTextPrintFormatter.
            let html = body["html"] as? String ?? ""
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                replyHandler(nil, "cofamioNative: html required for print"); return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    replyHandler(["ok": false, "error": "Print view unavailable."] as [String: Any], nil)
                    return
                }
                let printInfo = UIPrintInfo(dictionary: nil)
                printInfo.outputType = .general
                printInfo.jobName = "CoFamio \u{2014} Calendar"
                let controller = UIPrintInteractionController.shared
                controller.printInfo = printInfo
                controller.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
                controller.present(animated: true) { (_, completed, error) in
                    if let error = error {
                        replyHandler(["ok": false, "error": error.localizedDescription] as [String: Any], nil)
                    } else if completed {
                        replyHandler(["ok": true] as [String: Any], nil)
                    } else {
                        // User dismissed the sheet without printing — not an error.
                        replyHandler(["ok": true, "cancelled": true] as [String: Any], nil)
                    }
                }
            }
        case "download":
            // Native file save / share for the web layer's document Download
            // button. The web layer has already fetched the bytes through
            // /api/documents/<id>/content, so this is pure I/O: base64 -> temp
            // file -> system share sheet ("Save to Files", Mail, AirDrop…).
            // Replaces the `<a download href="data:…">` approach, which is a
            // navigation this app's policy cancels (the button did nothing).
            let fileName = body["fileName"] as? String ?? ""
            let base64 = body["base64"] as? String ?? ""
            let mimeType = body["mimeType"] as? String ?? "application/octet-stream"
            guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !base64.isEmpty else {
                replyHandler(nil, "cofamioNative: fileName and base64 required for download"); return
            }
            guard let data = Data(base64Encoded: base64), !data.isEmpty else {
                replyHandler(["ok": false, "error": "The file could not be decoded."] as [String: Any], nil)
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    replyHandler(["ok": false, "error": "Save view unavailable."] as [String: Any], nil)
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(Self.safeFileName(fileName, mimeType: mimeType))
                do {
                    // Overwrite: a second save of the same document must not fail.
                    try? FileManager.default.removeItem(at: url)
                    try data.write(to: url, options: .atomic)
                } catch {
                    replyHandler(["ok": false, "error": "Could not prepare the file."] as [String: Any], nil)
                    return
                }
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                // iPad / popover: the share sheet needs an anchor or it traps.
                if let pop = sheet.popoverPresentationController {
                    pop.sourceView = self.view
                    pop.sourceRect = CGRect(
                        x: self.view.bounds.midX,
                        y: self.view.bounds.maxY - 60,
                        width: 0,
                        height: 0
                    )
                    pop.permittedArrowDirections = []
                }
                sheet.completionWithItemsHandler = { _, completed, _, error in
                    if let error = error {
                        replyHandler(["ok": false, "error": error.localizedDescription] as [String: Any], nil)
                    } else if completed {
                        replyHandler(["ok": true] as [String: Any], nil)
                    } else {
                        // Dismissed without choosing a destination — not an error.
                        replyHandler(["ok": true, "cancelled": true] as [String: Any], nil)
                    }
                    // The sheet has copied the file where the user asked; the
                    // temp copy is no longer needed.
                    try? FileManager.default.removeItem(at: url)
                }
                self.present(sheet, animated: true, completion: nil)
            }
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
        // JSONEncoder supports top-level fragments (a bare String);
        // NSJSONSerialization data(withJSONObject:) rejects them
        // ("Invalid top-level type in JSON write") and crashed the app.
        // Result is a quoted, escaped JSON string literal safe to embed in JavaScript.
        guard let data = try? JSONEncoder().encode(s),
              let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        return str
    }

    /// Sanitize a web-supplied file name before it is written to the file
    /// system: no path separators or traversal, no control characters, a
    /// sensible extension (from the mime type when the name has none) and a
    /// bounded length. The web layer already sanitizes; this is defense in
    /// depth for a name that arrives over the JS bridge.
    static func safeFileName(_ name: String, mimeType: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the last path component only, then strip anything that could
        // change the destination directory.
        if let slash = base.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            base = String(base[base.index(after: slash)...])
        }
        base = base.replacingOccurrences(of: "..", with: "-")
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- ()[]&'+")
        base = String(base.filter { allowed.contains($0) })
        if base.isEmpty || base == "." { base = "cofamio-document" }
        if base.count > 120 { base = String(base.prefix(120)) }
        if !base.contains(".") {
            let ext: String
            switch mimeType {
            case "application/pdf": ext = "pdf"
            case "image/jpeg": ext = "jpg"
            case "image/png": ext = "png"
            case "image/heic": ext = "heic"
            default:
                if mimeType.hasPrefix("image/") { ext = "img" }
                else if mimeType.hasPrefix("text/") { ext = "txt" }
                else { ext = "bin" }
            }
            base += "." + ext
        }
        return base
    }

    // MARK: - StoreKit 2 (Phase 2) — status push + backend sync

    /// Deliver a StoreKit entitlement status into the page so the web app can
    /// refresh its own entitlement state (e.g. after a renewal or refund).
    func pushIapStatus(_ status: StoreKitManager.EntitlementStatus) {
        let json = (try? JSONSerialization.data(withJSONObject: status.toJSONObject()))
            .map { String(data: $0, encoding: .utf8) ?? "{}" } ?? "{}"
        // StoreKit callbacks arrive from a background Task context; WebKit calls need main.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.webView != nil else { return }
            let js = "window.CoFamioNative && window.CoFamioNative.__setIapStatus(" + json + ");"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
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
        // didRegisterForRemoteNotificationsWithDeviceToken runs off the main
        // thread; WebKit calls (evaluateJavaScript + the cookie-store read in
        // nativeAuthenticatedPost) must hop to main. pushToken is set above so
        // didFinish re-delivery still works when the web view isn't ready yet.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.webView != nil else { return } // applied once the webview loads (didFinish)
            let js = "window.CoFamioNative && window.CoFamioNative.__setPushToken(" + Self.jsonString(token) + ");"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
            self.postPushTokenNative(token)
        }
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
        // The WKHTTPCookieStore read is a WebKit API and must run on the main
        // thread: postAppleSync arrives from StoreKitManager's background Task
        // context, so hop here even though savePushToken already hops for its
        // own caller.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
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
    ///   - blob: — allow. The bundled SPA is served from the cofamioapp:// scheme
    ///     handler, so any URL the page creates with URL.createObjectURL resolves
    ///     to `blob:cofamioapp://…`. The document viewer renders PDFs in an
    ///     <iframe src={blobUrl}> (documents.tsx): before this, the iframe
    ///     navigation fell through to `default:` and was cancelled, so the viewer
    ///     showed an EMPTY frame on device (owner report 2026-09-20). blob: URLs
    ///     are same-origin, in-memory objects the page itself created — there is
    ///     nothing to fetch and no external content can be injected through them.
    ///     `data:` is deliberately NOT allowed: a data: URL is a full inline
    ///     document and the download path no longer needs it (the Document
    ///     Download button uses the native `download` bridge action instead).
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
        case "blob":
            // In-page objects (the document viewer's PDF/iframe blob) — safe, and
            // the only reason the PDF viewer works inside the shell. See above.
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
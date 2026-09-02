import Foundation
import WebKit

/// Serves the CoFamio SPA from inside the app bundle via the `cofamioapp://`
/// custom scheme. This retires the "remote web shell" review risk: the released
/// app loads its own HTML/CSS/JS (`App/App/www`) instead of loading
/// `https://cofamio.ctonew.app` as a remote page.
///
/// Mapping (the handler joins host + path, e.g. `cofamioapp://assets/x.js`
/// has host `assets` + path `/x.js` → serves `www/assets/x.js`):
///   cofamioapp://app, cofamioapp:///app, cofamioapp://<app-route>  → index.html
///   cofamioapp://assets/<file>   → www/assets/<file>   (hashed JS/CSS chunks)
///   cofamioapp://icons/<file>    → www/icons/<file>
///   cofamioapp://manifest.webmanifest | sw.js | offline.html → bundled copy
///
/// API calls are NOT proxied here (WKURLSchemeTask cannot carry POST bodies).
/// Instead the web layer (native.ts fetch shim) sends relative `fetch("/api/…")`
/// calls as absolute HTTPS + `Authorization: Bearer <Keychain session token>`
/// (Authorization is CORS-allowed by the origin), and the server accepts that
/// header as a cookie fallback. Native POSTers (IAP sync, push register) keep
/// hitting the HTTPS origin with their cookie copy, with a Keychain fallback.
public final class BundledSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "cofamioapp"

    private let bundleRoot: URL

    public init(bundleURL: URL) {
        bundleRoot = bundleURL
        super.init()
    }

    // MARK: - WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // cofamioapp://assets/x.js → host "assets", path "/x.js". Join them so
        // the lookup below sees the full "/assets/x.js".
        let host = url.host ?? ""
        let path = host + (url.path.isEmpty ? "/" : url.path)

        let relativePath: String
        if path == "/" || path == "/app" || path == "/app/" || path == "/index.html" || path == "/app.html" {
            relativePath = "index.html"
        } else if path.hasPrefix("/assets/") || path.hasPrefix("/icons/") {
            relativePath = String(path.dropFirst(1)) // "assets/…" or "icons/…"
        } else if path == "/manifest.webmanifest" || path == "/sw.js" || path == "/offline.html" {
            relativePath = String(path.dropFirst(1))
        } else {
            // Any other app route (deep link path) → SPA shell; the client
            // router hydrates and routes to the requested path.
            relativePath = "index.html"
        }

        let fileURL = bundleRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = Self.mimeType(forPath: relativePath)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Cache-Control": "no-cache"]
        ) ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // All static responses are served synchronously from the bundle; nothing
        // to cancel.
    }

    private static func mimeType(forPath path: String) -> String {
        if path.hasSuffix(".js") { return "text/javascript" }
        if path.hasSuffix(".css") { return "text/css" }
        if path.hasSuffix(".json") { return "application/json" }
        if path.hasSuffix(".png") { return "image/png" }
        if path.hasSuffix(".svg") { return "image/svg+xml" }
        if path.hasSuffix(".webmanifest") { return "application/manifest+json" }
        if path.hasSuffix(".html") { return "text/html" }
        return "application/octet-stream"
    }
}
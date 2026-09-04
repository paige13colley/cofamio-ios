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
/// The built SPA references its own files with ABSOLUTE `cofamioapp://…` URLs
/// whose "directory" is the HOST (`cofamioapp://assets/x.js`, `cofamioapp://icons/
/// icon.png`, `cofamioapp://manifest.webmanifest`) and whose real path is the
/// URL path. Those directory hosts are normalized back into an absolute path
/// (`/assets/x.js`, `/manifest.webmanifest`, …) before the lookup below.
/// Absolute references that keep the "app" host (`cofamioapp://app/assets/x.js`,
/// `cofamioapp://app/icons/…`, `cofamioapp://app/manifest.webmanifest` etc.) are
/// normalized the same way.
///
/// Every response is served with `Access-Control-Allow-Origin: *`: the SPA's ES
/// module scripts are fetched from `cofamioapp://assets/…` — a DIFFERENT origin
/// than the `cofamioapp://app` page — so WebKit CORS-checks those module fetches
/// even though the scheme is private. `cofamioapp://` is a local-only scheme
/// serving only bundled static files (API calls never flow through this handler),
/// so a wildcard ACAO is safe and is the standard fix for WKURLSchemeHandler +
/// module scripts. Without it the hydration JS is blocked, the module graph
/// never runs, and the app hangs forever on the splash.
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
        // cofamioapp://assets/x.js → host "assets", path "/x.js"; join them so
        // the lookup below sees the full "/assets/x.js".
        let host = url.host ?? ""
        let rawPath = url.path

        // Belt-and-braces normalization so every URL shape the SPA can emit
        // resolves to the same canonical absolute path:
        //  • directory hosts (the way the built index.html actually references
        //    files): cofamioapp://assets/x.js → "/assets/x.js",
        //    cofamioapp://manifest.webmanifest → "/manifest.webmanifest"
        //  • app-hosted absolute refs: cofamioapp://app/assets/x.js → "/assets/x.js"
        //  • everything else keeps the historical host+path join (page routes,
        //    deep links, cofamioapp:///app) — unchanged.
        var path: String
        if host == "assets" || host == "icons" || host == "manifest.webmanifest"
            || host == "sw.js" || host == "offline.html" || host == "index.html" {
            path = "/" + host + rawPath
        } else if host == "app"
            && (rawPath.hasPrefix("/assets/") || rawPath.hasPrefix("/icons/")
                || rawPath == "/manifest.webmanifest" || rawPath == "/sw.js"
                || rawPath == "/offline.html" || rawPath == "/index.html") {
            path = rawPath
        } else {
            path = host + (rawPath.isEmpty ? "/" : rawPath)
        }

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
            // Log misses so a future breakage shows up in Console.app / the
            // Xcode device console instead of a silent splash hang.
            NSLog("[CoFamioNative] BundledSchemeHandler: no bundled file for request %@ (resolved relativePath %@)", url.absoluteString, relativePath)
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = Self.mimeType(forPath: relativePath)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Cache-Control": "no-cache",
                // See type doc: module scripts cross origins between the "app"
                // page and "assets" resource URLs; wildcard ACAO is required
                // (and safe) for this private, local-only scheme.
                "Access-Control-Allow-Origin": "*",
            ]
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
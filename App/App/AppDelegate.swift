import UIKit
import UserNotifications

/// CoFamio iOS app entry point.
///
/// This is a Capacitor-STYLE shell: a single WKWebView hosting the live web app
/// (https://cofamio.ctonew.app), with the file layout a real `npx cap add ios`
/// project would produce (AppDelegate / ViewController / Info.plist /
/// entitlements / Assets.xcassets / capacitor.config.json). It deliberately has
/// ZERO third-party dependencies — it builds with Xcode alone, no CocoaPods, no
/// node toolchain — so the owner can compile it immediately. Adopting the real
/// @capacitor/ios framework later is a documented, mechanical swap (see
/// ios/README-UPLOAD.md) and is NOT required for this build.
@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var window: UIWindow?
    private var controller: ViewController?

    // IF_IAP_LATER -----------------------------------------------------------
    // Web-only subscriptions for launch: billing is the existing web Stripe
    // Checkout flow, which runs inside the WKWebView (see
    // ViewController.decidePolicyFor — Stripe domains stay in-app so the shared
    // cookie store keeps the user logged in and the post-checkout redirect
    // returns authenticated). To add StoreKit 2 later, WITHOUT rewriting the
    // shell:
    //   1. Start `Transaction.updates` here:  Task { for await v in Transaction.updates { ... } }
    //   2. Resolve/upgrade entitlements via Product.products(for:).
    //   3. Deliver the result to the web app with a new bridge action, e.g.:
    //        webView.evaluateJavaScript(
    //          "window.CoFamioNative && window.CoFamioNative.__setIapStatus && " +
    //          "window.CoFamioNative.__setIapStatus('active')")
    //   4. The web app stores it on the same plan fields (see src/lib/db/types.ts
    //      "Native iOS/Android will attach their own IAP subscription state").
    // No StoreKit code exists in this build on purpose.
    // ------------------------------------------------------------------------

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let vc = ViewController()
        controller = vc

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = vc
        window?.makeKeyAndVisible()

        requestPushPermissionAndRegister()
        return true
    }

    // MARK: - Push notifications (APNs)

    /// Ask the user (once, lazily) and register for remote notifications. The
    /// APNs device token arrives in didRegisterForRemoteNotifications... and is
    /// handed to the web view, which POSTs it to /api/push/register (the same
    /// origin fetch carries the session cookie). The native side ALSO posts
    /// directly with the cookie copied from the web view's cookie store, so
    /// registration works end-to-end even before the web shim has run.
    private func requestPushPermissionAndRegister() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                NSLog("[CoFamioNative] push permission granted=\(granted) error=\(error?.localizedDescription ?? "nil")")
            }
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NSLog("[CoFamioNative] APNs device token acquired (hex length \(token.count))")
        controller?.savePushToken(token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected in the iOS Simulator (no APNs). Real devices get a token.
        NSLog("[CoFamioNative] APNs registration failed: \(error.localizedDescription)")
    }

    /// Show system banners even while the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    // MARK: - Deep links

    /// cofamio:// scheme URLs (e.g. cofamio://calendar, cofamio://reset?token=...)
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        controller?.handleIncomingURL(url)
        return true
    }

    /// Universal links (https://cofamio.ctonew.app/...) — requires the
    /// associated-domains entitlement + the published AASA file (both are
    /// documented follow-ups in ios/README-UPLOAD.md; the handler below is
    /// already wired so it starts working the moment those two land).
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {
            controller?.handleIncomingURL(url)
            return true
        }
        return false
    }
}
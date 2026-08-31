# CoFamio iOS App — Build & Upload Guide (owner-facing)

This folder is the **CoFamio native iOS app**: a small native shell (Xcode
project) that loads the existing web app (`https://cofamio.ctonew.app`) inside a
full-screen web view. Same backend, same database, same login, same
subscriptions — nothing on the server changes for the app to work.

> **What this guide covers:** from "open the project on your Mac" to "upload to
> the App Store". It is written for you (the owner). We could not compile or
> TestFlight this from our Linux machines — **everything below happens on your
> Mac** — but every file is in place so the steps are mechanical.

---

## 0. What you already have (per our plan)

- ✅ Apple Developer account (paid, in good standing)
- ✅ App ID `com.cofamio.app` (explicit, **Push Notifications** capability on)
- ✅ App Store Connect record **"CoFamio"**
- ✅ A Mac with Xcode (see step 1 if not installed)
- ✅ This project (the `ios/` folder inside the site repo)

## 1. Install & open Xcode (only once)

1. Open the **App Store** on your Mac.
2. Search **Xcode** → **Get/Install** (it is large; 10+ GB, takes a while).
3. Open Xcode once, let it finish first-launch setup, agree to the license.
4. If Xcode asks to install extra tools / simulator runtimes — accept the **iOS
   runtime** if you plan to test in the Simulator (push notifications do NOT
   work in the Simulator, so a real iPhone is preferred for the push test).

## 2. Open the project

1. In Finder, go to the site repo folder → `ios` → `App`.
2. Open **`App.xcodeproj`** (double-click). Xcode launches with the project.

## 3. Set your signing team (10 seconds, required)

1. In Xcode, click the project name **CoFamio** in the left panel.
2. Click the target **CoFamio** → tab **Signing & Capabilities**.
3. Check **"Automatically manage signing"** is ticked.
4. In **Team**, pick your company/personal team (your Apple Developer account).
5. Confirm **Bundle Identifier = `com.cofamio.app`** — it must match your App ID
   exactly (it already does). If Xcode auto-suggests something different, type
   `com.cofamio.app` back in.
6. The **Push Notifications** capability should already be listed (the
   entitlement file brings it in). Confirm it shows a green dot — if you see
   "Add the Push Notifications capability to the App ID" instead, your App ID in
   the developer portal is missing the capability; re-check step 0 (it was
   enabled when the App ID was created).
7. Xcode may print "Provisioning profile … doesn't include …" for a moment while
   it creates the development profile — this resolves itself once automatic
   signing finishes (a few seconds).

## 4. Run it on your iPhone (sanity check before uploading)

1. Plug an iPhone in via USB (or use wireless debugging; Xcode will offer).
2. At the very top left of Xcode, change the run destination from "Any iOS
   Device …" to your iPhone.
3. Press **Run** (the ▶ button). The app builds, installs, and opens CoFamio.
4. Expect: the app loads the live CoFamio site, your web login works, and the
   **"CoFamio Would Like to Send You Notifications"** permission prompt appears
   (a real device only — the Simulator cannot receive push).
5. Test **subscribing normally through the app** (Settings → plan → Stripe
   Checkout opens *inside* the app; paying returns you to the app signed in).
6. Test a **deep link**: in Safari on that iPhone, type
   `cofamio://calendar` and press Go — the app should open and land on the
   Calendar.

## 5. Create the APNs key (for push — 5 minutes, in the browser)

Push **registration** already works with no extra setup (the app captures the
device token and stores it per-account via `/api/push/register`). The missing
piece is the **server sending** notifications, which needs an APNs key that only
you can create (it is a private credential):

1. Go to **developer.apple.com** → **Certificates, Identifiers & Profiles** →
   **Keys** (left menu).
2. Click **+** (create a key).
3. Name it e.g. **CoFamio APNs**; tick **Apple Push Notifications service
   (APNs)**; click **Continue** → **Register** → **Download**.
4. **Keep the downloaded `.p8` file safe** (you can only download it once) and
   write down the **Key ID** (shown on the key's detail page).
5. Your **Team ID** is on developer.apple.com → Membership page (top right).
6. When the engineering team wires the send side, these four values are all
   that's needed:
   - `APN_KEY_ID` — the Key ID from step 4
   - `APN_TEAM_ID` — your Team ID
   - `APN_AUTH_KEY_P8` — path to (or contents of) the downloaded `.p8`
   - `APN_BUNDLE_ID` — `com.cofamio.app`
   The app itself needs nothing else; the token it registers is what the sender
   targets.

## 6. Real app icon (before uploading)

The shipped icon is a **placeholder** (brand-mark square, generated for every
required size). Replace it before you upload if you want the App Store to show
your real branding:

1. Have a designer drop a **1024×1024 PNG** (no alpha, no rounded corners) into
   `ios/App/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png`, replacing the
   placeholder, and re-run `bun ios/scripts/gen-icons.mjs` from the site repo
   root to regenerate the smaller sizes — or add the 1024 file in Xcode's asset
   catalog UI and let Xcode generate sizes.
2. Rebuild before archiving.

## 7. Archive & upload to App Store Connect

1. In Xcode, top bar: change destination to **"Any iOS Device (arm64)"** (or
   your iPhone model).
2. Menu **Product → Archive**. Xcode builds and opens the **Organizer**
   window when done (a few minutes).
3. In the Organizer, select the newest archive → **Distribute App** →
   - **App Store Connect** (the "upload to the App Store" path) → **Upload**.
   - Accept all defaults (App Thins, bitcode off is fine — defaults are fine).
4. Xcode prompts for your Apple ID — sign in with the account that owns the
   App Store Connect record. (If you prefer, export the .ipa and upload via
   **Transporter** instead; both work.)
5. **Wait for processing** — App Store Connect shows "Processing" for a few
   minutes. Open **appstoreconnect.apple.com → Apps → CoFamio** and refresh.

> **First-upload gotcha:** Xcode needs a **distribution certificate + App Store
> provisioning profile** with push enabled. With automatic signing on, Xcode
> creates both for you at archive time. Apple's profile system can be slow the
> *first* time; if the upload errors with "no profiles", wait a couple of
> minutes, hit **Distribute App** again.

## 8. TestFlight (recommended before release)

1. In App Store Connect → **CoFamio → TestFlight**.
2. If your account is a **new Apple Developer account**, you need at least one
   **External Testing** group approved by Apple (usually within 24 h). For a
   private build, **Internal Testing** works instantly with up to 100 testers.
3. Add your own Apple ID as an internal tester, install the **TestFlight** app
   on your iPhone, and install the build.
4. Test: login persists across restarts, push prompt → token, deep links, and
   a real Stripe checkout inside the app.

## 9. Release (when you're ready)

App Store Connect → **CoFamio → App Store** tab. Fill in the required fields:

| Field | What to enter |
|---|---|
| **App preview & screenshots** | Upload **6.5" iPhone screenshots** (1290×2794, 4–8 shots of the app: dashboard, calendar, co-parenting, messaging, expenses, settings). Counts as the hardest part — capture from the app on your iPhone. |
| **Description** | Pitch from the web landing page: family organization + co-parenting — calendars, custody schedules, shared expenses, messaging, documents. No legal claims (it's an organizational tool, not legal advice). |
| **What's New** | "First release." |
| **Support URL** | https://cofamio.ctonew.app/contact |
| **Marketing URL** (optional) | https://cofamio.ctonew.app |
| **Version / Build** | 1.0 / the uploaded build. |
| **App icon** | Already in the upload. |
| **Copyright** | `© 2026 CoFamio` (or your legal name / company). |
| **Rating** | Complete the questionnaire — this app has no user-generated content; 4+ recommended. |
| **Privacy policy URL** | https://cofamio.ctonew.app/privacy |
| **Review information — Sign-in** | Provide a test account (email + password) so App Review can log in; add a note that the app wraps the live site and all billing is via the web checkout. |
| **In-App Purchases** | One auto-renewable subscription product (CoFamio — see §10). Before release, confirm it's approved and live in App Store Connect and note the current status in Review Notes. |

Then **Add for Review** → wait (days, usually). You can also choose
**Manually release** to control when it goes live.

---

## 10. In-App Purchases (StoreKit2 — Phase 2)
The app now carries a **native StoreKit2 purchase engine** (`StoreKitManager.swift`)
so that subscriptions bought inside the iOS app use Apple's auto-renewable
subscriptions, in addition to the existing web Stripe flow. The web-only Stripe
path and the user-visible web UI are **unchanged** — on iOS the exact same "Start
7-Day Free Trial" / Restore buttons call the native StoreKit sheet instead of
Stripe; on web/desktop they still open Stripe Checkout.

How it works (for the record):
- `window.CoFamioNative.iap.*` (injected by `ViewController.swift`) exposes
  `getProducts`, `purchase(planId, appAccountToken)`, `restore`,
  `getCurrentEntitlement`, `canMakePayments` to the web layer
  (`src/lib/appleIap.ts` in the web repo).
- `purchase` sets StoreKit's `appAccountToken` to the **CoFamio userId**, presents
  the system purchase sheet, and on success hands the StoreKit2 **JWS
  (`signedTransactionInfo`) + environment** back to the web layer, which POSTs
  `POST /api/billing/apple/sync`. The native shell also POSTs that sync directly
  as a fallback, and listens to `Transaction.updates` for renewals/refunds.
- The single product id is **`com.cofamio.app.monthly`** (CoFamio @ $9.99/mo) —
  the same value the web server maps via `APPLE_IAP_PRODUCT`.
- The whole Apple path is **dormant** until the operator sets `APPLE_IAP_ENABLED=true`
  with the App Store Connect credentials (see `APPLE-IAP-DESIGN.md`). No purchase is
  made and no entitlement is created just by building/running this branch.

### Setting up products in App Store Connect (owner, once)
Follow the checklist in `APPLE-IAP-DESIGN.md` §6: create a Subscription Group,
two monthly auto-renewable subscription products with the two product ids above,
an In-App Purchase key (→ `APPLE_IAP_KEY*`), the Shared Secret, and a Server
Notifications V2 URL. **Enable In-App Purchase on the App ID** (App Store Connect →
Your App → Capabilities → In-App Purchase) — the entitlement file does NOT carry
an IAP key; the capability is the App ID toggle plus the linked StoreKit.framework.

### Testing in StoreKit Sandbox
1. **Add a sandbox tester** (App Store Connect → Users and Access → Sandbox →
   add an Apple ID). Do NOT use your real Apple ID — sandbox purchases never
   charge the tester.
2. On the iPhone (or Simulator), go to **Settings → your Apple ID → Media &
   Purchases → Sandbox Account** and sign in as that tester.
3. Build & run the app from Xcode (this branch). Log in to CoFamio (the web
   account you want the entitlement on).
4. Open **Settings → Subscription & billing**, pick a plan, tap **Start 7-Day
   Free Trial**. The system StoreKit purchase sheet appears — approve with the
   sandbox account. The backend receives the signed transaction via
   `/api/billing/apple/sync` (and the entitlement appears in `GET /api/billing/status`).
5. To test **renewal**: App Store Connect → your subscription product → localizations
   → set a short **review/renewal interval** (e.g. a few minutes) so the sandbox
   renews quickly, then wait and watch `Transaction.updates` push a renewal.
6. To test **restore**: delete/reinstall the app or sign out, then tap **Restore
   purchases** (visible only in the iOS app) — `AppStore.sync()` restores the
   entitlement.
7. To test **reflect a refund/cancel**: cancel the subscription in the
   sandbox account's Settings → Subscriptions; the `Transaction.updates` stream →
   `/api/billing/apple/sync` reflects the inactive state.
> Optional local dev: for fast iteration without App Store Connect, add the
> `App/App/StoreKitConfiguration.storekit` file's scheme (Product → Scheme → Run →
> Options → StoreKit Configuration) to simulate products locally. This is only for
> local Xcode testing; it is not required for sandbox or production.

---
## Architecture notes (for your engineering team, read once)

- **Shell:** `AppDelegate.swift` + `ViewController.swift`, zero third-party
  dependencies — builds with Xcode alone. Layout mirrors what `npx cap add ios`
  would generate, so adopting the real @capacitor/ios framework later is a
  mechanical file swap, **not** required for this build.
- **Bridges (Capacitor-plugin pattern via `WKScriptMessageHandlerWithReply`,
  iOS 15+):**
  - `window.CoFamioNative.secureGet/secureSet/secureRemove` — Keychain storage
    (web shim: `src/lib/native.ts`, type-safe, inert in browsers).
  - `window.CoFamioNative.pushToken/onPushToken` — APNs token delivered to the
    page; the web app (and, as a fallback, the native side itself) POSTs it to
    **`POST /api/push/register`** (new: auth-required, stores into the new
    `push_tokens` collection, `platform:"ios"`).
  - Deep links: `cofamio://calendar`, `cofamio://reset?token=…` etc. → web
    routes. Universal links handler is wired but needs (a) the
    `associated-domains` entitlement and (b) the AASA file published — follow-up.
- **Web-only subscriptions:** the navigation policy keeps ALL http(s) traffic in
  the web view *including Stripe Checkout* — that's deliberate, so the user's
  cookie-store session survives checkout and the return redirect lands back in
  the app authenticated. IAP (`IF_IAP_LATER` notes in `AppDelegate.swift`) is a
  documented future seam, not in this build.
- **Session persistence:** `WKWebsiteDataStore.default()` persists the httpOnly
  session cookie across launches; the Keychain bridge is the belt-and-braces
  store for app-level tokens.

## What was NOT verified from engineering's Linux side (must happen on your Mac)

1. **Compilation** — Xcode build. The project is structurally complete
   (hand-authored, no CocoaPods), but only Xcode can confirm it compiles.
2. **APNs end-to-end send** — needs your `.p8` key + a server-side sender
   (documented next step; the token *registration* path is complete).
3. **Simulator** can't test push; use a physical iPhone.

## Follow-ups queued for engineering

- Server-side APNs sender (uses the 4 env vars above) + web push (VAPID) for
  the PWA.
- Universal links: add `associated-domains` entitlement + publish the AASA file
  (already drafted at `public/.well-known/apple-app-site-association`; it needs
  your Team ID substituted and a deployment of the web app).
- Real app icon from a designer; store screenshots.
- Android shell via the same wrapper (Google Play account, $25).
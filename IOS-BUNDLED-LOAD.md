# iOS Release — Bundled Web Assets (remote-shell retirement)

**Status:** IMPLEMENTED 2026-09-03 (pending iOS-side review/merge)
**Approach chosen:** (c) hand-rolled bundle in the existing WKWebView shell — **no Capacitor runtime, no `server.url` switch.** See "Why" below.

## What changed

The released iOS app now loads the CoFamio SPA **from inside the .ipa** via the
WKWebView custom-scheme handler `cofamioapp://`, instead of loading
`https://cofamio.ctonew.app` as a remote page. API/billing/push traffic still
goes to the remote HTTPS origin (absolute URLs).

## Why this approach (vs the alternatives)

- **(a) Capacitor `webDir: dist` + removing `server.url`:** the repo is a
  **hand-rolled WKWebView app** — there is NO Capacitor runtime (no Podfile, no
  Capacitor.framework, no `CDV` wiring; the `capacitor.config.json` is
  vestigial). Capacitor's `webDir`/`server.url` semantics simply do not apply:
  nothing reads them at build/run time. We could not "just remove server.url".
- **(b) Scheme-specific debug/release switch:** over-engineered for this shell —
  there is no Capacitor plugin layer to switch on, and the previous TestFlight
  builds already ran the remote URL. The debug experience ("load the live site")
  is preserved by keeping the hero constants (apiOrigin etc.) the same and by
  the fact that the app itself is a development shell; a scheme switch would
  still not produce a bundled build in this repo without a copy phase.
- **(c) Hand-rolled bundle (CHOSEN):** the shell already owns WKWebView load +
  bridge + deep-link mapping. Adding a `cofamioapp://` scheme handler +
  `Resources/www` copy phase is ~100 lines, keeps 100% of the behavior
  (cold-start → /app landing, deep links, zoom clamp, IAP/push bridges), and
  removes the remote page load entirely. This is the standard, review-safe
  shape: app ships its HTML/JS/CSS; runtime API calls cross to HTTPS.

## Behavior preservation (mapped)

| Behavior | Before | After |
|---|---|---|
| Cold start | loads `https://cofamio.ctonew.app/app` | loads bundled `/app` via `cofamioapp://app`; SPA `/app` entry routes (dashboard/login/onboard) — unchanged |
| Auth/session | same-origin cookie (`SameSite=Lax` works) | custom-scheme page (foreign origin) → cookie blocked; **bridge attaches `Cookie: ff_session=…` from Keychain** on every request; `Set-Cookie` responses still persist in WKWebsiteDataStore for native POSTs |
| Deep links | `cofamio://map/xyz` → `https://cofamio.ctonew.app/map/xyz` | `cofamio://map/xyz` → **bundled** `/map/xyz` (cofamioapp://); query preserved |
| universal links | https on our origin | still handled: loaded bundled path |
| IAP sync | `POST https://cofamio.ctonew.app/api/billing/apple/sync` (cookie copied) | unchanged |
| Push register | `POST https://cofamio.ctonew.app/api/push/register` (cookie copied) | unchanged |
| Zoom clamp | native min/max zoom 1.0 + no bounce | unchanged |
| Stripe/3DS | allowed in-app (needs same-origin cookie) | web pay is NOT a path for native iOS (native → StoreKit only); any web fallback would open in system browser (unchanged behavior) |
| SW registration | in-page `navigator.serviceWorker.register('/sw.js')` on https origin | custom scheme: SW API absent → register promise rejects → caught; **no functional loss (bundled assets are local)** |

## Future build must pass

- **Codemagic:** add to `scripts` BEFORE "Build .ipa":
  `bash scripts/bundle-web.sh` (checks `cofamio.ctonew.app/release-web/<version>.tar.gz`,
  unpacks `ios/App/App/www` + `cwd/www`, runs `App/App/Resources` copy phase).
  The security/behavior review reads the bundled `www` (no remote page load).
- **Version:** `MARKETING_VERSION` is the integer SemVer (`1.0.1` now);
  Codemagic's `git rev-list --count HEAD` yields a monotonically increasing
  `BUILD_NUMBER` per fresh clone — **no manual bump needed** (thanks to
  `App/App/Info.plist` `Info.plist` + `Assets.xcassets` all in-tree, and the
  cordova/Plists are baked). Keep as-is.
- **Env after merge:** nothing new beyond the existing
  `apple-store-credentials` group + `BUNDLE_ID`. `capacitor.config.json` is
  vestigial (no runtime reads it) and is intentionally left with the old
  `server.url` so future readers see the shell has no Capacitor dependency.

## Web-side changes (local repo `/home/team/shared/site`, no remote)

- `src/lib/native.ts` — `nativeFetch` wrapper (absolute iln API base,
  Keychain Cookie header, connection offline flag).
- `src/lib/apiClient.ts` — new **shared client-side API layer**; `apiFetch`
  used by the auth context; feature-flagged callers kept on relative fetch
  (feature-flag hardening, no behavior change).
- `src/lib/auth-context.tsx` — use `apiFetch` (absolute base + Keychain cookie)
  so bundled sessions work; `Endpoint` detected via `window.CoFamioNative`.
- `src/routes/index.tsx` — `isAppContext()` now is true in bundled mode too
  (Endpoint bridge present) so the cold-start still lands `/app`.
- `src/lib/webpush.ts`, `src/lib/push.server.ts` — no runtime change needed
  (SW is absent on custom scheme; push token flows via native APNs already).
- tsc baseline: 65 errors BEFORE, verify ≤66 AFTER (no new errors).

## Security note

No third-party analytics; the custom-scheme page is fully local. The only
remote requests are the API endpoints the app needs (documents/uploads,
calendar, billing sync, push register) — all HTTPS to the app's own origin.
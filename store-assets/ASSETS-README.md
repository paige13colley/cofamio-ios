# CoFamio — iOS App Store Assets

These are the App Store assets for the **CoFamio** native iOS app
(the Capacitor wrapper of the live web app). Everything here is generated from
real UI / real brand assets — no mockups.

## Where each file goes in App Store Connect

### App icon
| File | App Store Connect location |
|------|---------------------------|
| `AppIcon.appiconset/icon-1024.png` | **General App Information → App Icon** (1024×1024, full-bleed, no alpha, no rounded corners — Apple applies the mask). |

The full set of sizes (20/29/40/60/76/83.5 pt, all @1x/@2x/@3x) lives inside the
Xcode project at `ios/App/App/Assets.xcassets/AppIcon.appiconset/`. They are
regenerated from the single 1024 master by:
```bash
cd /home/team/shared/site && bun ios/scripts/gen-icons.mjs
```
The icon is a **white family house with a warm amber heart** on coFamio's
indigo gradient — the brand mark (family / co-parenting motif), matching the
live site's indigo (`#4f46e5`) + amber brand colors.

### Screenshots
| File | Size | App Store Connect location |
|------|------|-----------------------------|
| `ss-01-landing-iphone.png` | 1290×2796 (6.5"/6.7" iPhone) | **App Store → App previews & screenshots → 6.7" iPhone** |
| `ss-02-co-parenting-iphone.png` | 1290×2796 | same |
| `ss-03-pricing-iphone.png` | 1290×2796 | same |
| `ss-04-signin-iphone.png` | 1290×2796 | same |
| `ss-05-landing-ipad.png` | 2048×2732 (12.9" iPad, portrait) | **App Store → App previews & screenshots → 12.9" iPad** |

All PNGs are captured from the **live coFamio web app** at the exact target
resolutions.

## ⚠️ IMPORTANT — screenshots currently show marketing/sign-in UI, NOT authenticated in-app screens

The live app's **authenticated** routes (`/app/dashboard`, `/app/calendar`,
`/app/messaging`, `/app/expenses`, `/app/co-parenting`) are currently broken in
the deployed build: every `_auth` page throws a client-side runtime error
**`useEffect is not defined`** (reproduces in a fresh browser with and without
login; persists after a clean rebuild; no source file is missing the import).
The sign-in page and all public/marketing pages render normally.

That is a real product bug (not a capture problem), so the in-app dashboard /
color-coded custody calendar / co-parenting messaging / expenses screenshots
**cannot be captured honestly right now** and were **not** fabricated.

Until the bug is fixed, the screenshots above are the honest, currently-renderable
UI: the landing page (which includes a color-coded custody-calendar preview),
the Co-Parenting Hub marketing page, Pricing, and Sign in.

### Do this before release (re-take with authenticated in-app UI)
1. Fix the deployed build so `_auth` routes render (the `useEffect is not defined`
   runtime error on all authenticated pages).
2. Log in with a demo account that has rich data. A ready test account exists in
   the site DB: **Parent A** (`parenta@test.com`) — it has a 2-2-3 custody
   schedule shared with Parent B, shared-child messages, holiday assignments,
   and expenses. (Create a shared-session cookie / use the real credentials.)
3. Capture at these exact viewports, replacing the placeholder names:
   - iPhone 6.5"/6.7" (view 430×932 CSS @3x → **1290×2796**):
     `ss-01-dashboard-iphone.png` (`/app/dashboard`),
     `ss-02-calendar-iphone.png` (`/app/calendar` — color-coded Dad/Mom custody),
     `ss-03-messaging-iphone.png` (`/app/messaging` or `/app/co-parenting`),
     `ss-04-expenses-iphone.png` (`/app/expenses`).
   - iPad 12.9" (view 1024×1366 CSS @2x → **2048×2732**):
     `ss-05-dashboard-ipad.png` (`/app/dashboard`).
4. Update this README's file list accordingly.

## Regenerate
- **Icon** — `bun ios/scripts/gen-icons.mjs` (writes all `AppIcon.appiconset` PNGs
  + `Contents.json`; validates the 1024 master has no alpha / no corners).
- **Screenshots** — re-capture from the live web app after the bug fix (above).

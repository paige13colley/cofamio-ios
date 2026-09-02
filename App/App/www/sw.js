// CoFamio service worker — installable PWA + offline app-shell support (Phase 5).
// Lightweight by design:
//   * Nav requests: network-first, fall back to the cached app shell, then to the
//     branded offline page.
//   * Static assets (JS/CSS) under /assets: stale-while-revalidate (fast + fresh).
//   * /api/* : NEVER cached — private household data must not land in a shared
//     cache. Requests just pass through; a failed fetch returns a JSON offline
//     error the client already knows how to handle.
//   * Everything else same-origin GET: cache-first with background refresh.
//
// Bump VERSION whenever you change app-shell behavior so activating the new SW
// also clears stale cached assets.
const VERSION = "cofamio-shell-v4";
const PRECACHE = [
  "/offline.html",
  "/manifest.webmanifest",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/icons/maskable-512.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(VERSION).then((cache) => cache.addAll(PRECACHE)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  // Same-origin only — never touch cross-origin (fonts etc.).
  if (url.origin !== self.location.origin) return;

  // Never cache the private API.
  if (url.pathname.startsWith("/api/")) {
    event.respondWith(fetch(req).catch(() => jsonOffline()));
    return;
  }

  // Static build assets: stale-while-revalidate.
  if (url.pathname.startsWith("/assets/")) {
    event.respondWith(swr(req));
    return;
  }

  // Page navigations: network-first with app-shell / offline fallback.
  if (req.mode === "navigate") {
    event.respondWith(navFirst(req));
    return;
  }

  // Other same-origin GETs (manifest, icons, …): cache-first, refresh in bg.
  event.respondWith(
    caches.match(req).then((hit) => {
      const network = fetch(req).then((res) => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(VERSION).then((c) => c.put(req, copy));
        }
        return res;
      });
      return hit || network;
    })
  );
});

async function navFirst(req) {
  try {
    const res = await fetch(req);
    // A reachable server response — even a redirect — means we are NOT offline.
    // Only fall back to offline.html on a genuine network failure (the catch
    // below). Returning redirects/errors to the browser lets it follow or show
    // the real result instead of falsely claiming the user is offline.
    if (res) {
      if (res.ok) {
        const copy = res.clone();
        const cache = await caches.open(VERSION);
        cache.put(req, copy);
      }
      return res;
    }
    throw new Error("no response");
  } catch (err) {
    const cached = await caches.match(req);
    if (cached) return cached;
    const offline = await caches.match("/offline.html");
    if (offline) return offline;
    // Last-resort inline fallback (offline page not cached yet).
    return new Response("<h1>Offline</h1><p>CoFamio is unreachable.</p>", {
      headers: { "Content-Type": "text/html" },
    });
  }
}

async function swr(req) {
  const cache = await caches.open(VERSION);
  const hit = await cache.match(req);
  const network = fetch(req)
    .then((res) => {
      if (res && res.ok) cache.put(req, res.clone());
      return res;
    })
    .catch(() => hit);
  return hit || network;
}

function jsonOffline() {
  return new Response(
    JSON.stringify({ ok: false, error: "You appear to be offline. Please reconnect and try again." }),
    { status: 503, headers: { "Content-Type": "application/json" } }
  );
}

// --- Web Push (VAPID) -----------------------------------------------
// Handles push messages delivered by the server's VAPID sender and shows them
// as OS notifications, then opens the relevant in-app route on click.
function pushRoute(type) {
  switch (type) {
    case "message": return "/app/messaging";
    case "expense": case "payment": return "/app/expenses";
    case "document": return "/app/documents";
    case "custody": case "schedule": return "/app/calendar";
    case "invite": return "/app/co-parenting";
    default: return "/app/dashboard";
  }
}

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    if (event.data) payload = event.data.json();
  } catch (_) { /* not JSON — fall back to defaults */ }
  const title = payload.title || "CoFamio";
  const options = {
    body: payload.body || "You have an update in CoFamio.",
    icon: "/icons/icon-192.png",
    badge: "/icons/icon-192.png",
    data: { url: payload.data && payload.data.url ? payload.data.url : pushRoute(payload.data && payload.data.type) },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "/app/dashboard";
  event.waitUntil(
    (async () => {
      const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      for (const client of all) {
        if ("focus" in client) await client.focus();
        if ("navigate" in client) {
          await client.navigate(target);
          return;
        }
      }
      await self.clients.openWindow(target);
    })()
  );
});

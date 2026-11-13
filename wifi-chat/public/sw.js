/* LAN Chat service worker: offline app shell. Bump VERSION to refresh caches. */
const VERSION = 'lanchat-v1';
const SHELL = [
  './', 'index.html', 'styles.css', 'app.js', 'protocol.js', 'transport-ws.js', 'transport-rtc.js',
  'vendor/qrcode-generator.mjs', 'manifest.webmanifest', 'icon.svg', 'apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(VERSION)
      .then((c) => Promise.all(SHELL.map((u) => c.add(new Request(u, { cache: 'reload' })).catch(() => {}))))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

function networkFirst(req, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    const fallback = () => caches.match(req, { ignoreSearch: true }).then((hit) => hit || undefined);
    const timer = timeoutMs ? setTimeout(() => {
      fallback().then((hit) => { if (hit && !settled) { settled = true; resolve(hit); } });
    }, timeoutMs) : null;
    fetch(req).then((res) => {
      clearTimeout(timer);
      if (res.ok && !settled) {
        const copy = res.clone();
        caches.open(VERSION).then((c) => c.put(req, copy)).catch(() => {});
      }
      if (!settled) { settled = true; resolve(res); }
    }).catch(() => {
      clearTimeout(timer);
      if (settled) return;
      fallback().then((hit) => { settled = true; resolve(hit || Response.error()); });
    });
  });
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.endsWith('/ws') || req.headers.get('upgrade') === 'websocket') return; // never touch the socket
  if (url.pathname.includes('/api/')) { event.respondWith(networkFirst(req, 0)); return; }
  event.respondWith(networkFirst(req, 3000));
});

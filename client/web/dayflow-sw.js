// Cache application assets only. Authentication and task API responses never
// enter this cache. Bump this revision whenever publishing changed static assets.
const CACHE = 'dayflow-shell-1.2.0-r2';
const SCOPE = new URL(self.registration.scope);
const CORE = [
  './', './index.html', './flutter_bootstrap.js', './main.dart.js',
  './manifest.json', './assets/AssetManifest.bin',
  './assets/AssetManifest.bin.json', './assets/FontManifest.json',
  './assets/shaders/ink_sparkle.frag', './assets/shaders/stretch_effect.frag'
];
const absolute = (path) => new URL(path, SCOPE).href;

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await cache.addAll(CORE.map((path) => new Request(absolute(path), {cache: 'reload'})));
    // Fonts can be lazily requested. Precache the actual build's font manifest,
    // including both icon fonts, so opening a new view offline also works.
    const manifest = await cache.match(absolute('./assets/FontManifest.json'));
    const families = await manifest.json();
    const fonts = [...new Set(families.flatMap((family) =>
      (family.fonts || []).map((font) => absolute(`./assets/${font.asset}`))
    ))];
    await cache.addAll(fonts.map((url) => new Request(url, {cache: 'reload'})));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(
    keys.filter((key) => key.startsWith('dayflow-shell-') && key !== CACHE)
      .map((key) => caches.delete(key))
  )).then(() => self.clients.claim()));
});

self.addEventListener('message', (event) => {
  if (event.data?.type === 'DAYFLOW_CLAIM') {
    event.waitUntil(self.clients.claim());
  }
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin
      || !url.pathname.startsWith(SCOPE.pathname)
      || url.pathname.includes('/api/')
      || event.request.headers.has('authorization')) return;

  const path = url.pathname.slice(SCOPE.pathname.length);
  const bundledAsset = path.startsWith('assets/') || path.startsWith('canvaskit/')
    || path.startsWith('icons/') || path === 'favicon.png';
  const shell = ['', 'index.html', 'flutter_bootstrap.js', 'main.dart.js', 'manifest.json'].includes(path);
  if (!bundledAsset && !shell && event.request.mode !== 'navigate') return;

  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    // Versioned build assets can be served directly. In particular, this avoids
    // downloading the bundled Chinese font again immediately after install.
    if (bundledAsset) {
      const cached = await cache.match(event.request);
      if (cached) return cached;
    }
    try {
      const response = await fetch(event.request);
      if (response.ok) {
        try {
          // Await the write before returning: first-frame completion must not
          // race a still-pending CanvasKit/font cache write.
          await cache.put(event.request, response.clone());
        } catch (error) {
          console.warn('Dayflow could not cache a build asset.', error);
        }
      }
      return response;
    } catch (error) {
      const cached = await cache.match(event.request);
      if (cached) return cached;
      if (event.request.mode === 'navigate') {
        const page = await cache.match(absolute('./index.html'));
        if (page) return page;
      }
      throw error;
    }
  })());
});

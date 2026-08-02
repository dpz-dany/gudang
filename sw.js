/* Service worker: rangka aplikasi disimpan supaya halaman tetap terbuka
   waktu internet mati. Data TIDAK disimpan di sini — data lewat localStorage
   dan antrean di core.js. */
const CACHE = 'gudang-v19';
const RANGKA = [
  './', './admin', './gudang', './kepala', './foto-shopee',
  './config.js', './assets/app.css', './assets/core.js', './assets/parser.js',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.111.0/dist/umd/supabase.min.js',
  'https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.min.js',
  'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js',
  'https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE)
    .then(c => Promise.allSettled(RANGKA.map(u => c.add(u))))
    .then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(k => Promise.all(k.filter(x => x !== CACHE).map(x => caches.delete(x))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET') return;                 // jangan sentuh tulis-menulis
  if (url.pathname.includes('/rest/v1/') ||
      url.pathname.includes('/auth/v1/')) return;         // Supabase selalu langsung

  // rangka & aset: pakai cache dulu, perbarui diam-diam di belakang
  e.respondWith(
    caches.match(e.request).then(hit => {
      const online = fetch(e.request).then(res => {
        if (res && res.status === 200)
          caches.open(CACHE).then(c => c.put(e.request, res.clone()));
        return res;
      }).catch(() => hit);
      return hit || online;
    })
  );
});

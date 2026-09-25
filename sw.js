/* Service worker — ทำให้เปิดแอปได้แม้ออฟไลน์
 * เปลี่ยน VERSION ทุกครั้งที่ปล่อย index.html เวอร์ชันใหม่ → เครื่องผู้ใช้จะเห็นแถบ "มีเวอร์ชันใหม่ — อัปเดต" (ไม่รีโหลดกลางการขายเอง) */
const VERSION = 'smartpos-v3.3.0';
const SHELL = ['./', 'index.html', 'manifest.webmanifest', 'icons/icon-192.png', 'icons/icon-512.png', 'icons/apple-touch-icon.png'];
const CDN = [
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
  'https://unpkg.com/html5-qrcode',
  'https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js',
  'https://fonts.googleapis.com/css2?family=Sarabun:wght@300;400;500;600;700;800&display=swap'
];
const CACHEABLE_HOSTS = /(^|\.)(fonts\.googleapis\.com|fonts\.gstatic\.com|cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com)$/;

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const c = await caches.open(VERSION);
    await c.addAll(SHELL);                                                                  // ไฟล์แอปต้องครบ ไม่งั้นติดตั้งไม่ผ่าน
    await Promise.allSettled(CDN.map(u => c.add(new Request(u, { mode: 'no-cors' }))));    // ไลบรารีภายนอก: พยายามเก็บ ไม่สำเร็จก็ไม่เป็นไร
  })());
});
self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== VERSION) await caches.delete(k);
    await self.clients.claim();
  })());
});
self.addEventListener('message', (e) => { if (e.data && e.data.type === 'SKIP_WAITING') self.skipWaiting(); });

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (/\.supabase\.(co|in)$/.test(url.hostname)) return;                                   // API / Storage ของ Supabase: ไม่แคช ให้ผ่านตรง
  if (req.mode === 'navigate') {                                                           // เปิดหน้าแอป: เอาจากแคชก่อน (เร็ว + ออฟไลน์ได้)
    e.respondWith(caches.match('index.html', { ignoreSearch: true }).then(r => r || fetch(req)));
    return;
  }
  const sameOrigin = url.origin === self.location.origin;
  if (!sameOrigin && !CACHEABLE_HOSTS.test(url.hostname)) return;
  e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(res => {
    if (res && (res.ok || res.type === 'opaque')) { const copy = res.clone(); caches.open(VERSION).then(c => c.put(req, copy)); }
    return res;
  }).catch(() => hit)));
});

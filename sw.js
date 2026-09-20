// ============================================================================
// Service Worker แบบเบาๆ สำหรับ Smart POS Pro V2
// ----------------------------------------------------------------------------
// วางไฟล์นี้ไว้ "ข้างๆ" index.html บนโฮสต์เดียวกัน (โฟลเดอร์เดียวกับ index.html) — index.html จะ
// ลงทะเบียนไฟล์นี้ให้อัตโนมัติถ้าเจอ ไม่ต้องแก้อะไรเพิ่ม
//
// ทำหน้าที่แค่ cache "เปลือกแอป" (ตัวไฟล์ index.html เอง + ไลบรารีจาก CDN ที่แอปใช้) ไว้ในเครื่อง
// เพื่อให้เปิดแอปได้เร็วขึ้นและยังเปิดได้แม้เน็ตหลุด/ช้ามาก — ข้อมูลจริง (สินค้า/บิล/ลูกค้า ฯลฯ)
// ไม่ได้เก็บที่นี่ ยังเก็บอยู่ใน localStorage ของตัวแอปเหมือนเดิมทุกประการ ไฟล์นี้ไม่ได้ทำให้แอป
// "ทำงานออฟไลน์แบบขายของได้เต็มรูปแบบ" เอง — การขายออฟไลน์ที่หักสต็อกในเครื่องแล้วซิงค์ทีหลัง
// เป็นเรื่องที่ index.html จัดการเองอยู่แล้วผ่าน localStorage ไม่เกี่ยวกับไฟล์นี้
// ============================================================================
const CACHE_NAME = 'pos-app-shell-v1';
const APP_SHELL = [
  './',
  './index.html',
  'https://fonts.googleapis.com/css2?family=Sarabun:wght@300;400;500;600;700;800&display=swap',
  'https://cdn.tailwindcss.com',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
  'https://unpkg.com/html5-qrcode',
  'https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      .catch(() => {}) // บาง CDN อาจบล็อก opaque cache ในบางเบราว์เซอร์ — ไม่ให้การติดตั้งล้มทั้งหมด
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) => Promise.all(
      names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))
    ))
  );
  self.clients.claim();
});

// กลยุทธ์: ลองโหลดจากเน็ตก่อนเสมอ (เพื่อให้ได้แอปเวอร์ชันล่าสุดทุกครั้งที่มีเน็ต) ถ้าเน็ตหลุด/ช้า
// เกินไปค่อย fallback ไปใช้ก็อปปี้ที่ cache ไว้ล่าสุดแทน — ป้องกันปัญหาแอป "ค้าง" อยู่กับเวอร์ชันเก่า
// ทั้งที่จริงมีเวอร์ชันใหม่กว่าบนเซิร์ฟเวอร์แล้ว ซึ่งจะสร้างความสับสนมากกว่าจะช่วยอะไร
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  event.respondWith(
    fetch(event.request)
      .then((res) => {
        const resClone = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, resClone)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(event.request).then((cached) => cached || caches.match('./index.html')))
  );
});

self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function (e) {
  var u = new URL(e.request.url);
  var m = u.pathname.match(/\/_blob\/([0-9a-f]+)$/);
  if (!m) return;
  e.respondWith(new Promise(function (res) {
    var r = indexedDB.open('mrp_blobs', 1);
    r.onupgradeneeded = function () { r.result.createObjectStore('b'); };
    r.onerror = function () { res(new Response('', { status: 404 })); };
    r.onsuccess = function () {
      var g = r.result.transaction('b').objectStore('b').get(m[1]);
      g.onsuccess = function () { res(g.result ? new Response(g.result.blob, { headers: { 'Content-Type': g.result.type || 'application/octet-stream' } }) : new Response('', { status: 404 })); };
      g.onerror = function () { res(new Response('', { status: 404 })); };
    };
  }));
});

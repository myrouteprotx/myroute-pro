self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
function openDb() {
  return new Promise(function (res, rej) {
    var r = indexedDB.open('mrp_blobs', 2);
    r.onupgradeneeded = function () { var d = r.result; if (!d.objectStoreNames.contains('b')) d.createObjectStore('b'); if (!d.objectStoreNames.contains('kv')) d.createObjectStore('kv'); };
    r.onsuccess = function () { res(r.result); };
    r.onerror = function () { rej(r.error); };
  });
}
function get(d, s, k) { return new Promise(function (res) { var q = d.transaction(s).objectStore(s).get(k); q.onsuccess = function () { res(q.result); }; q.onerror = function () { res(null); }; }); }
function put(d, s, k, v) { return new Promise(function (res) { var t = d.transaction(s, 'readwrite'); t.objectStore(s).put(v, k); t.oncomplete = res; t.onerror = res; }); }
async function lookup(id) {
  var d = await openDb();
  var hit = await get(d, 'b', id);
  if (hit) return new Response(hit.blob, { headers: { 'Content-Type': hit.type || 'application/octet-stream' } });
  var a = await get(d, 'kv', 'auth');
  if (!a || !a.token) return new Response('', { status: 404 });
  try {
    var r = await fetch(a.url + '/rest/v1/blobs?id=eq.' + encodeURIComponent(id) + '&select=type,data&limit=1', { headers: { apikey: a.key, Authorization: 'Bearer ' + a.token } });
    if (!r.ok) return new Response('', { status: 404 });
    var rows = await r.json();
    if (!rows.length) return new Response('', { status: 404 });
    var blob = await (await fetch(rows[0].data)).blob();
    await put(d, 'b', id, { blob: blob, type: rows[0].type || blob.type });
    return new Response(blob, { headers: { 'Content-Type': rows[0].type || blob.type } });
  } catch (e) { return new Response('', { status: 404 }); }
}
self.addEventListener('fetch', function (e) {
  var m = new URL(e.request.url).pathname.match(/\/_blob\/([0-9a-f]+)$/);
  if (m) e.respondWith(lookup(m[1]));
});

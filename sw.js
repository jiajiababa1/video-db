/* VideoDB Service Worker — 应用壳缓存，离线可开
   v3: 只缓存 GET 的成功响应，避免把 404/500 或非 GET 请求写进缓存，导致离线时拿到坏页面 */
var CACHE = 'vdb-shell-v4';
var SHELL = ['./', './index.html', './watch.html', './manifest.json', './manifest-2048.json', './icon-180.png', './icon-192.png', './icon-512.png'];
self.addEventListener('install', function(e) {
  e.waitUntil(caches.open(CACHE).then(function(c) { return c.addAll(SHELL); })
    .then(function() { return self.skipWaiting(); }));
});
self.addEventListener('activate', function(e) {
  e.waitUntil(caches.keys().then(function(ks) {
    return Promise.all(ks.filter(function(k) { return k !== CACHE; })
      .map(function(k) { return caches.delete(k); }));
  }).then(function() { return self.clients.claim(); }));
});
self.addEventListener('fetch', function(e) {
  if (e.request.method !== 'GET') return;
  var u = new URL(e.request.url);
  // 只缓存本站静态壳；API/视频流一律走网络
  if (u.origin === location.origin &&
      (u.pathname.endsWith('.html') || u.pathname.endsWith('.json') || u.pathname.endsWith('.png'))) {
    e.respondWith(
      fetch(e.request).then(function(r) {
        if (r && r.ok) {
          var cp = r.clone();
          e.waitUntil(caches.open(CACHE).then(function(c) { return c.put(e.request, cp); }));
        }
        return r;
      }).catch(function() {
        return caches.match(e.request, { ignoreSearch: true });
      })
    );
  }
});

// video-db 国内中转 (Cloudflare Worker, 免费版即可)
// 用法: https://<worker>/<host>/<原路径>?<原参数>
// 放行白名单域名, 其余一律 403 (防被陌生人当免费代理刷流量)。
// 透传 Range 头 — 视频拖动进度条靠它; 响应流式转发, 不落地缓存大文件。
// v2 (2026-11-17): 新增 hsex 的 CDN (hdcdn.store) — 首页大半是 hsex 视频,
// 其封面/切片不过中转的话关梯子照样看不到。m3u8 播放列表做文本改写:
// 列表里的绝对地址换成中转地址, 相对地址天然会回到 Worker 取切片。

const ALLOWED_HOSTS = new Set([
  "video.twimg.com",   // 视频文件
  "pbs.twimg.com",     // 封面图
  "i.hdcdn.store",     // hsex 封面图
  "cdn.hdcdn.store",   // hsex 视频 (m3u8 + 切片)
]);

export default {
  async fetch(request) {
    const url = new URL(request.url);
    // 路径第一段就是目标域名: /video.twimg.com/ext_tw_video/...
    const parts = url.pathname.split("/").filter(Boolean);
    const host = parts.shift();
    if (!host || !ALLOWED_HOSTS.has(host)) {
      return new Response("host not allowed", { status: 403 });
    }
    const target = "https://" + host + "/" + parts.join("/") + url.search;

    const headers = new Headers();
    const range = request.headers.get("Range");
    if (range) headers.set("Range", range);
    headers.set("User-Agent", request.headers.get("User-Agent") || "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15");

    let upstream;
    try {
      upstream = await fetch(target, { method: "GET", headers, redirect: "follow" });
    } catch (e) {
      return new Response("upstream error", { status: 502 });
    }

    const respHeaders = new Headers();
    for (const k of ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Cache-Control", "ETag", "Last-Modified"]) {
      const v = upstream.headers.get(k);
      if (v) respHeaders.set(k, v);
    }
    respHeaders.set("Access-Control-Allow-Origin", "*");
    // 封面图在边缘多缓存一会儿, 省请求数
    if ((host === "pbs.twimg.com" || host === "i.hdcdn.store") && upstream.ok) {
      respHeaders.set("Cache-Control", "public, max-age=86400");
    }

    // m3u8 播放列表: 缓冲后改写里面的绝对地址, 让切片也走中转
    const ct = upstream.headers.get("Content-Type") || "";
    const isPlaylist = target.includes(".m3u8") || ct.includes("mpegurl");
    if (isPlaylist && upstream.ok) {
      let text = await upstream.text();
      const self = url.origin;
      text = text.split("https://cdn.hdcdn.store").join(self + "/cdn.hdcdn.store");
      text = text.split("https://i.hdcdn.store").join(self + "/i.hdcdn.store");
      respHeaders.delete("Content-Length");
      respHeaders.set("Content-Type", "application/vnd.apple.mpegurl");
      return new Response(text, { status: 200, headers: respHeaders });
    }

    return new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers: respHeaders,
    });
  },
};

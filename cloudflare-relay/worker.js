// video-db 国内中转 (Cloudflare Worker, 免费版即可)
// 用法: https://<你的worker地址>/video.twimg.com/<原路径>?<原参数>
//      https://<你的worker地址>/pbs.twimg.com/<原路径>?<原参数>
// 只放行下面白名单域名 (防被陌生人当免费代理刷流量), 其余一律 403。
// 透传 Range 头 — 视频拖动进度条靠它; 响应流式转发, 不落地缓存大文件。

const ALLOWED_HOSTS = new Set([
  "video.twimg.com",   // 视频文件
  "pbs.twimg.com",     // 封面图
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
    if (host === "pbs.twimg.com" && upstream.ok) {
      respHeaders.set("Cache-Control", "public, max-age=86400");
    }

    return new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers: respHeaders,
    });
  },
};

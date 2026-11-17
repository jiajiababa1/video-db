// ==UserScript==
// @name         CF 中转代码一键替换
// @namespace    vdb-relay
// @version      1.0
// @description  在 Cloudflare Worker 编辑器页一键把默认代码替换成 video-db 中转代码（手机上全选删除太难，用这个）
// @match        *://dash.cloudflare.com/*
// @grant        none
// @run-at       document-idle
// ==/UserScript==

(function () {
  'use strict';

  var CODE = [
    'const ALLOWED_HOSTS = new Set(["video.twimg.com", "pbs.twimg.com"]);',
    'export default {',
    '  async fetch(request) {',
    '    const url = new URL(request.url);',
    '    const parts = url.pathname.split("/").filter(Boolean);',
    '    const host = parts.shift();',
    '    if (!host || !ALLOWED_HOSTS.has(host)) {',
    '      return new Response("host not allowed", { status: 403 });',
    '    }',
    '    const target = "https://" + host + "/" + parts.join("/") + url.search;',
    '    const headers = new Headers();',
    '    const range = request.headers.get("Range");',
    '    if (range) headers.set("Range", range);',
    '    headers.set("User-Agent", request.headers.get("User-Agent") || "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15");',
    '    let upstream;',
    '    try {',
    '      upstream = await fetch(target, { method: "GET", headers, redirect: "follow" });',
    '    } catch (e) {',
    '      return new Response("upstream error", { status: 502 });',
    '    }',
    '    const respHeaders = new Headers();',
    '    for (const k of ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Cache-Control", "ETag", "Last-Modified"]) {',
    '      const v = upstream.headers.get(k);',
    '      if (v) respHeaders.set(k, v);',
    '    }',
    '    respHeaders.set("Access-Control-Allow-Origin", "*");',
    '    if (host === "pbs.twimg.com" && upstream.ok) {',
    '      respHeaders.set("Cache-Control", "public, max-age=86400");',
    '    }',
    '    return new Response(upstream.body, {',
    '      status: upstream.status,',
    '      statusText: upstream.statusText,',
    '      headers: respHeaders,',
    '    });',
    '  },',
    '};'
  ].join('\n');

  function replaceViaMonaco() {
    try {
      if (window.monaco && window.monaco.editor && window.monaco.editor.getModels) {
        var models = window.monaco.editor.getModels();
        if (models && models.length) {
          models[0].setValue(CODE);
          return true;
        }
      }
    } catch (e) {}
    return false;
  }

  function replaceViaExec() {
    var ta = document.querySelector('.monaco-editor textarea, .cm-content, [contenteditable="true"]');
    if (!ta) return false;
    ta.focus();
    document.execCommand('selectAll', false, null);
    return document.execCommand('insertText', false, CODE);
  }

  function addBtn() {
    if (document.getElementById('vdb-fill-btn')) return;
    if (!document.querySelector('.monaco-editor, .cm-editor')) return;
    var b = document.createElement('button');
    b.id = 'vdb-fill-btn';
    b.textContent = '🔁 换成中转代码';
    b.style.cssText = 'position:fixed;right:14px;bottom:96px;z-index:999999;background:#f6821f;color:#fff;font-size:16px;font-weight:700;border:none;border-radius:99px;padding:12px 18px;box-shadow:0 4px 14px rgba(0,0,0,.35);';
    b.addEventListener('click', function () {
      if (replaceViaMonaco() || replaceViaExec()) {
        b.textContent = '✅ 已替换，点部署';
        alert('代码已替换好，点页面右上角的「部署」就行');
      } else {
        alert('没找到编辑器区域，截图发我看看');
      }
    });
    document.body.appendChild(b);
  }

  setInterval(addBtn, 1500);
})();

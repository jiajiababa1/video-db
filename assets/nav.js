/* ============================================================
 * nav.js — 统一顶栏导航
 * app-v2 一站式应用共享
 * 用法: 在 <body> 顶部放 <div id="vdbNav"></div>，引入本文件后自动渲染
 * 依赖: assets/common.js, assets/auth.js
 * ============================================================ */
(function() {
'use strict';

var PAGES = [
    { href: 'index.html',   label: '🏠 首页',   match: /^index\.html/ },
    { href: 'videos.html',  label: '🎬 视频',   match: /^videos\.html/ },
    { href: 'search.html',  label: '🔍 搜索',   match: /^search\.html/ },
    { href: 'library.html', label: '📚 我的库', match: /^library\.html/ },
    { href: 'social.html',  label: '💬 社交',   match: /^social\.html/ },
    { href: 'game.html',    label: '🎮 游戏',   match: /^game\.html/ }
];

function render() {
    var mount = document.getElementById('vdbNav');
    if (!mount) return;
    var path = (location.pathname.split('/').pop() || 'index.html').split('?')[0].split('#')[0];
    var user = '';
    try { user = window.VdbAuth ? window.VdbAuth.currentUser() : ''; } catch (e) {}

    var h = '<nav style="display:flex;align-items:center;gap:4px;padding:10px 16px;'
        + 'border-bottom:1px solid var(--vborder);background:var(--vheader);'
        + 'backdrop-filter:var(--glass-blur);position:sticky;top:0;z-index:100;flex-wrap:wrap;">';
    h += '<a href="index.html" style="font-weight:800;font-size:16px;color:var(--vprimary);'
        + 'text-decoration:none;margin-right:12px;">Video<span style="color:var(--vtext);">DB</span></a>';
    PAGES.forEach(function(p) {
        var on = p.match.test(path);
        h += '<a href="' + p.href + '" style="padding:8px 12px;border-radius:8px;font-size:13px;'
            + 'text-decoration:none;white-space:nowrap;'
            + (on ? 'color:var(--vprimary);background:rgba(200,164,92,0.12);font-weight:700;'
                  : 'color:var(--vmuted);')
            + '">' + p.label + '</a>';
    });
    h += '<span style="flex:1;"></span>';
    if (user) {
        h += '<span style="font-size:12px;color:var(--vmuted);">@' + escHtml(user) + '</span>';
    } else {
        h += '<a href="index.html#login" style="font-size:12px;color:var(--vprimary);text-decoration:none;">登录</a>';
    }
    h += '</nav>';
    mount.innerHTML = h;
}

function escHtml(s) {
    return String(s == null ? '' : s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', render);
} else {
    render();
}

window.VdbNav = { render: render };
})();

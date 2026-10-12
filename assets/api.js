/* ============================================================
 * api.js — 数据层：Supabase REST 封装
 * app-v2 一站式应用共享
 * 依赖: assets/common.js (window.VdbCommon)
 * ============================================================ */
(function() {
'use strict';

var C = window.VdbCommon;
var SB = C.SUPABASE_URL, KEY = C.SUPABASE_ANON_KEY;

function headers(extra) {
    var h = {
        'apikey': KEY,
        'Authorization': 'Bearer ' + KEY,
        'Content-Type': 'application/json'
    };
    try {
        var t = localStorage.getItem('login_token') || sessionStorage.getItem('login_token') || '';
        if (t) h['x-login-token'] = t;
    } catch (e) {}
    if (extra) for (var k in extra) h[k] = extra[k];
    return h;
}

async function get(path) {
    var r = await fetch(SB + path, { headers: headers() });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return r.json();
}

async function getCount(path) {
    var r = await fetch(SB + path, { headers: headers({ 'Prefer': 'count=exact' }) });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    var cr = r.headers.get('content-range') || '';
    var total = parseInt((cr.split('/')[1] || '0'), 10) || 0;
    var data = await r.json();
    return { data: data, total: total };
}

var VIDEO_COLS = 'video_id,title,author,thumbnail_url,duration,source_page,source_section,views,created_at,has_mp4,needs_rescrape,video_url,monsnode_video_id';

var Api = {
    // 按 ID 取视频
    videoById: function(vid) {
        return get('/rest/v1/videos?video_id=eq.' + encodeURIComponent(vid) + '&select=*&limit=1')
            .then(function(rows) { return rows[0] || null; });
    },
    // 视频列表
    videos: function(opts) {
        opts = opts || {};
        var p = '/rest/v1/videos?select=' + encodeURIComponent(VIDEO_COLS) +
            '&removed=not.is.true&order=' + encodeURIComponent(opts.order || 'created_at.desc') +
            '&limit=' + (opts.limit || 60);
        if (opts.offset) p += '&offset=' + opts.offset;
        if (opts.section) p += '&source_section=ilike.*' + encodeURIComponent(opts.section) + '*';
        else p += '&or=(source_section.is.null,source_section.not.ilike.*av4*)';
        if (opts.author) p += '&author=eq.' + encodeURIComponent(opts.author).replace(/'/g, '%27');
        if (opts.excludeId) p += '&video_id=neq.' + encodeURIComponent(opts.excludeId);
        if (opts.hasMp4) p += '&has_mp4=is.true';
        return getCount(p);
    },
    // 同作者视频
    relatedByAuthor: function(author, excludeId, limit) {
        return this.videos({ author: author, excludeId: excludeId, hasMp4: true, limit: limit || 12, order: 'views.desc' });
    },
    // 搜索
    search: function(q, opts) {
        opts = opts || {};
        var terms = String(q || '').trim().split(/\s+/).filter(Boolean);
        if (!terms.length) return Promise.resolve({ data: [], total: 0 });
        var ors = [];
        terms.forEach(function(t) {
            var e = encodeURIComponent('%' + t + '%');
            ors.push('title.ilike.' + e, 'author.ilike.' + e);
        });
        var p = '/rest/v1/videos?select=' + encodeURIComponent(VIDEO_COLS) +
            '&or=(' + ors.join(',') + ')' +
            '&removed=not.is.true&or=(source_section.is.null,source_section.not.ilike.*av4*)' +
            '&order=created_at.desc&limit=' + (opts.limit || 60);
        if (opts.offset) p += '&offset=' + opts.offset;
        return getCount(p);
    },
    // 查管理员
    isAdmin: function(username) {
        return get('/rest/v1/user_accounts?username=eq.' + encodeURIComponent(username) + '&select=is_admin&limit=1')
            .then(function(rows) { return !!(rows[0] && rows[0].is_admin); });
    },
    // 历史/收藏 (localStorage)
    store: {
        get: function(k, def) {
            try { var v = JSON.parse(localStorage.getItem(k) || 'null'); return v === null ? def : v; }
            catch (e) { return def; }
        },
        set: function(k, v) {
            try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {}
        }
    }
};

window.VdbApi = Api;
})();

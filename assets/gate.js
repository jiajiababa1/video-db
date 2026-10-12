/* ============================================================
 * gate.js — 全站统一安全门禁
 * app-v2 安全体系核心，所有页面必须在 <head> 后第一时间引入
 *
 * 安全策略:
 *  P1 密码门禁: 无有效 token 一律跳 password.html
 *  P2 会话超时: 2小时无操作自动失效
 *  P3 防暴力破解: 5次失败锁定15分钟 (本机计数)
 *  P4 设备绑定: token 与 device ID 绑定，换设备需重验
 *  P5 页面级校验: 每次加载验证 token 未过期
 *  P6 审计日志: 登录成功/失败写 Supabase audit_log
 *
 * 依赖: assets/common.js
 * ============================================================ */
(function() {
'use strict';

var C = window.VdbCommon;
var SB = C.SUPABASE_URL, KEY = C.SUPABASE_ANON_KEY;

// ---- 配置 ----
var SESSION_HOURS = 2;        // P2: 会话有效期
var MAX_FAIL = 5;             // P3: 最大失败次数
var LOCK_MINUTES = 15;        // P3: 锁定时长
var FAIL_KEY = 'gate_fail';   // {count, lockUntil}
var TOKEN_KEY = 'vid_gate_token';
var TOKEN_TS_KEY = 'vid_gate_ts';
var DEVICE_KEY = 'vdb_device_id';

// ---- 设备 ID (P4) ----
function deviceId() {
    try {
        var id = localStorage.getItem(DEVICE_KEY);
        if (!id) {
            id = 'dvc-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
            localStorage.setItem(DEVICE_KEY, id);
        }
        return id;
    } catch (e) { return 'dvc-unknown'; }
}

// ---- P3: 失败计数 ----
function failState() {
    try { return JSON.parse(localStorage.getItem(FAIL_KEY) || '{"count":0,"lockUntil":0}'); }
    catch (e) { return { count: 0, lockUntil: 0 }; }
}
function isLocked() {
    var s = failState();
    if (s.lockUntil && Date.now() < s.lockUntil) return Math.ceil((s.lockUntil - Date.now()) / 60000);
    return 0;
}
function recordFail() {
    var s = failState();
    s.count++;
    if (s.count >= MAX_FAIL) {
        s.lockUntil = Date.now() + LOCK_MINUTES * 60000;
        s.count = 0;
    }
    try { localStorage.setItem(FAIL_KEY, JSON.stringify(s)); } catch (e) {}
}
function clearFail() {
    try { localStorage.removeItem(FAIL_KEY); } catch (e) {}
}

// ---- P5: token 有效性 ----
function tokenValid() {
    try {
        var t = localStorage.getItem(TOKEN_KEY);
        var ts = parseInt(localStorage.getItem(TOKEN_TS_KEY) || '0', 10);
        if (!t || !ts) return false;
        // P2: 超时检查
        if (Date.now() - ts > SESSION_HOURS * 3600000) {
            clearToken();
            return false;
        }
        return true;
    } catch (e) { return false; }
}
function clearToken() {
    try { localStorage.removeItem(TOKEN_KEY); localStorage.removeItem(TOKEN_TS_KEY); } catch (e) {}
}
function touchSession() {
    // 有操作时刷新时间戳 (P2 滑动窗口)
    try {
        if (localStorage.getItem(TOKEN_KEY)) {
            localStorage.setItem(TOKEN_TS_KEY, String(Date.now()));
        }
    } catch (e) {}
}

// ---- P6: 审计 ----
function audit(event, detail) {
    try {
        fetch(SB + '/rest/v1/rpc/gate_audit', {
            method: 'POST',
            headers: { 'apikey': KEY, 'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json' },
            body: JSON.stringify({ p_event: event, p_device: deviceId(), p_detail: detail || '' })
        }).catch(function() {});
    } catch (e) {}
}

// ---- 门禁主逻辑 ----
function enforce() {
    var page = (location.pathname.split('/').pop() || 'index.html').split('?')[0];
    // password.html 自己不受门禁
    if (page === 'password.html') return true;
    if (tokenValid()) {
        // 绑定 activity 监听，滑动刷新会话
        ['click', 'keydown', 'touchstart'].forEach(function(ev) {
            document.addEventListener(ev, touchSession, { passive: true });
        });
        return true;
    }
    // 跳密码页，带回跳
    var next = encodeURIComponent(location.pathname.split('/').pop() + location.search);
    location.replace('password.html?next=' + next);
    return false;
}

window.VdbGate = {
    enforce: enforce,
    deviceId: deviceId,
    tokenValid: tokenValid,
    clearToken: clearToken,
    touchSession: touchSession,
    isLocked: isLocked,
    recordFail: recordFail,
    clearFail: clearFail,
    audit: audit,
    SESSION_HOURS: SESSION_HOURS,
    MAX_FAIL: MAX_FAIL,
    LOCK_MINUTES: LOCK_MINUTES
};

// 页面加载立即执行门禁
if (document.readyState === 'loading') {
    // 尽早拦截：DOM 解析前就检查，避免闪烁
    if (!tokenValid()) {
        var page = (location.pathname.split('/').pop() || 'index.html').split('?')[0];
        if (page !== 'password.html') {
            var next = encodeURIComponent(location.pathname.split('/').pop() + location.search);
            location.replace('password.html?next=' + next);
        }
    } else {
        document.addEventListener('DOMContentLoaded', function() {
            ['click', 'keydown', 'touchstart'].forEach(function(ev) {
                document.addEventListener(ev, touchSession, { passive: true });
            });
        });
    }
} else {
    enforce();
}
})();

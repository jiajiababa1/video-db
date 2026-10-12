/* ============================================================
 * auth.js — 统一身份守卫
 * app-v2 一站式应用共享
 * 职责: 登录态读取、管理员校验、页面级权限拦截
 * 依赖: assets/common.js, assets/api.js
 * ============================================================ */
(function() {
'use strict';

var C = window.VdbCommon;

function currentUser() {
    try {
        return localStorage.getItem('vdb_user') || sessionStorage.getItem('vdb_user') || '';
    } catch (e) { return ''; }
}

// 页面守卫: requireAdmin=true 时非管理员跳回首页
// 返回 Promise<boolean> 是否放行
async function guard(opts) {
    opts = opts || {};
    var u = currentUser();
    if (opts.requireLogin && !u) {
        location.href = 'index.html#login';
        return false;
    }
    if (opts.requireAdmin) {
        if (!u) { location.href = 'index.html#login'; return false; }
        try {
            var ok = await window.VdbApi.isAdmin(u);
            if (!ok) {
                C.toast('需要管理员权限');
                location.href = 'index.html';
                return false;
            }
        } catch (e) {
            C.toast('权限校验失败');
            location.href = 'index.html';
            return false;
        }
    }
    return true;
}

function logout() {
    try {
        localStorage.removeItem('vdb_user');
        sessionStorage.removeItem('vdb_user');
        localStorage.removeItem('login_token');
        sessionStorage.removeItem('login_token');
    } catch (e) {}
    location.href = 'index.html';
}

window.VdbAuth = {
    currentUser: currentUser,
    guard: guard,
    logout: logout
};
})();

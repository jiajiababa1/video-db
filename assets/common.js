/* ============================================================
 * common.js — 全站公共 JavaScript
 * 从 index.html 提取 (multipage 分支步骤1)
 * 包含: Supabase 连接、esc、toast
 * 各页面通过 <script src="assets/common.js"></script> 引入
 * ============================================================ */
(function() {
'use strict';

    var _vdbSk=[86,105,100,68,98,75,101,121];
    function _vdbDec(b64){var s=atob(b64),o='';for(var i=0;i<s.length;i++)o+=String.fromCharCode(s.charCodeAt(i)^_vdbSk[i%_vdbSk.length]);return o;}
    var SUPABASE_URL=_vdbDec('Ph0QNBFxSlYwDA43Ej0HGj0ODyYPLRwWLgARJkw4EAk3CwU3B2UGFg==');
    var SUPABASE_ANON_KEY=_vdbDec('MxAuLAAMBhAZAC4NNzEsSBgALTcrJTdMNSotcisgFSEAKi59TC4cMyYKVwkLBAwzLA08BgoSCD8sMzcNEQILMzozDQ1UAggjOggKChUvCDM8CFYgEBIISDsMM31WKj0vPyANMwsoCEAlMzcNVAIIPyMLVnALByYzJjA8FQsEDzxlJiAFUgQhGiwnHicRAggvYgonDVQGDzhjJw4FUAYfNGUnV3RMB1QTAFk8ExIOU0A4ODIjOBwIOC4DKwM2CikJMAQgcxotCRoZWz0mVxFUTQ==');
    try{window.__SB_URL=SUPABASE_URL;window.__SB_ANON=SUPABASE_ANON_KEY;}catch(e){}

    function esc(s){if(!s)return'';var d=document.createElement('div');d.textContent=s;return d.innerHTML.replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
    var _toastQueue=[], _toasting=false;
    function toast(msg){
        _toastQueue.push(msg);
        if(_toasting)return;
        _showNextToast();
    }
    function _showNextToast(){
        if(!_toastQueue.length){_toasting=false;return;}
        _toasting=true;
        var msg=_toastQueue.shift();
        $toast.textContent=msg;$toast.classList.add('on');
        setTimeout(function(){
            $toast.classList.remove('on');
            setTimeout(_showNextToast, 300);
        }, 2000);
    }
// 导出到全局
window.VdbCommon = {
    get SUPABASE_URL() { return SUPABASE_URL; },
    get SUPABASE_ANON_KEY() { return SUPABASE_ANON_KEY; },
    esc: esc,
    toast: toast
};

})();

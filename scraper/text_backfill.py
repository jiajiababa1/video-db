"""
text_backfill.py v2 — 云端文案回填 (反 Cloudflare 版, 与 scraper/main.py v12 同传输层)
================================================================================
为什么重写:
  v1 用 requests 裸直连 monsnode/twjn.php, GitHub Actions 机房 IP 会吃
  Cloudflare 403 挑战页 → 整轮 0 成功。本版直接复用 main.py v12 的 Fetcher:
    httpx(HTTP/2) → curl_cffi(Chrome TLS 指纹) → allorigins → codetabs → jina(仅解析)
  启动时自动探测, 解析失败自动换层, 全部被拦提前结束 (不再空转几万条)。

链路 (与站内 backfillTextForVideo 同逻辑):
  twjn.php?v=<monsnode_id> → 解真实推文 ID (列表 id ≠ 推文 id, 只有 tweet_link 里是真的)
  → api.fxtwitter.com/status/<id> (失败换 vxtwitter, 再失败走代理) → 推文原文(title)+作者
  → 回写 videos。成功顺手带 MP4 (twjn 同一页就有)。

用法:
  python text_backfill.py --limit 400            # 回填最多 400 条无标题视频
  python text_backfill.py --limit 120 --workers 12
  python text_backfill.py test                   # 连通性自检, 打印每层状态, 不写库

环境变量:
  SUPABASE_URL / SUPABASE_SERVICE_KEY (或 SUPABASE_KEY, 与 scraper.yml 同一套, 须 service_role)
  TEXT_WORKERS (默认 12) / RESOLVE_* 复用 main.py 命名亦可

依赖 (与 scraper/main.py 一致, 无需 supabase-py):
  pip install "httpx[http2]" curl_cffi || pip install httpx
"""
import os
import sys
import re
import time
import base64
import random
import threading
import html as htmlmod
from datetime import datetime, timezone
from urllib.parse import quote
from concurrent.futures import ThreadPoolExecutor, as_completed

import httpx

try:
    from curl_cffi import requests as creq
except Exception:
    creq = None

BASE_URL = "https://monsnode.com"
FX_URLS = [
    "https://api.fxtwitter.com/status/{}",
    "https://api.vxtwitter.com/status/{}",
]

PROXY_ALLORIGINS = "https://api.allorigins.win/raw?url="
PROXY_CODETABS = "https://api.codetabs.com/v1/proxy?quest="
PROXY_JINA = "https://r.jina.ai/"
PROBE_MID = "26199120"
JINA_MIN_INTERVAL = float(os.environ.get("JINA_MIN_INTERVAL", "3.0") or 3.0)

REQUEST_TIMEOUT = 25

UA_POOL = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
]

RE_ATOB = re.compile(r"atob\(\s*['\"]([^'\"]{20,})['\"]\s*\)")
RE_MP4_URL = re.compile(r"https?://video\.twimg\.com/[^\s'\"<>)\\\]]+\.mp4[^\s'\"<>)\\\]]*")
RE_STATUS = re.compile(r"status/(\d{12,25})")


def log(msg, level="INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


def _env_int(name, default):
    try:
        v = os.environ.get(name, "").strip()
        return int(v) if v else default
    except Exception:
        return default


def _looks_blocked(text):
    if not text:
        return False
    head = text[:4000]
    return ("Just a moment" in head) or ("Attention Required" in head) or ("__cf_chl" in head)


def _looks_twjn_page(text):
    if not text:
        return False
    return ("atob(" in text) or ("Data does not exist" in text) or ("Link to external site" in text)


def _headers(referer=None):
    h = {
        "User-Agent": random.choice(UA_POOL),
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "ja,en-US;q=0.9,en;q=0.8",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
        "Upgrade-Insecure-Requests": "1",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "none",
        "Sec-Fetch-User": "?1",
        "Connection": "keep-alive",
    }
    if referer:
        h["Referer"] = referer
    return h


def extract_tweet_id(html):
    """从 twjn 页面解真实推文 ID (明文 status/ 优先, atob 混淆其次)。"""
    if not html:
        return None
    m = RE_STATUS.search(html)
    if m:
        return m.group(1)
    for b64 in RE_ATOB.findall(html):
        try:
            d = base64.b64decode(b64).decode("utf-8", "ignore")
        except Exception:
            continue
        t = RE_STATUS.search(d)
        if t:
            return t.group(1)
    return None


def extract_mp4(html):
    """与站内 extractTwjnMp4 / main.py _extract_mp4 同规则 (只取 video.twimg.com)。"""
    if not html:
        return None
    for b64 in RE_ATOB.findall(html):
        try:
            d = base64.b64decode(b64).decode("utf-8", "ignore").strip()
        except Exception:
            continue
        if "video.twimg.com" in d:
            return d.rstrip(".,*)]\"'")
    m = RE_MP4_URL.search(html)
    return m.group(0).rstrip(".,*)]\"'") if m else None


def fx_meta_from_json(data):
    try:
        tw = (data or {}).get("tweet")
        if not tw:
            return None, None
        raw = ((tw.get("raw_text") or {}).get("text")) or tw.get("text") or ""
        title = re.sub(r"https?://t\.co/\S+", "", raw)
        title = re.sub(r"\s+", " ", title).strip()[:500]
        au = tw.get("author") or {}
        author = (au.get("screen_name") or au.get("name") or "").lstrip("@")[:200]
        if not title and not author:
            return None, None
        return title or None, author or None
    except Exception:
        return None, None


class Fetcher:
    """与 main.py v12 同款多传输层抓取器 (精简版: 去掉 Playwright, 保留 jina 兜底)。
    自动探测可用层, 解析失败自动换层。单例跨线程共用 (curl 会话按线程隔离)。"""

    RAW_TIERS = ("httpx", "curl", "allorigins", "codetabs")

    def __init__(self, timeout=REQUEST_TIMEOUT):
        self.timeout = timeout
        try:
            self.client = httpx.Client(timeout=timeout, follow_redirects=True, http2=True)
        except Exception:
            self.client = httpx.Client(timeout=timeout, follow_redirects=True)
        self.proxy_client = httpx.Client(timeout=45, follow_redirects=True)
        self._tls = threading.local()
        self._probe_lock = threading.Lock()
        self._jina_lock = threading.Lock()
        self._jina_last = 0.0
        self.resolve_mode = None
        self.jina_ok = False
        self.blocked = False
        self._stats = {"ok": 0, "fail": 0, "jina_ok": 0}

    def _curl_get(self, url, referer):
        if creq is None:
            return None
        h = {"Referer": referer} if referer else None
        sess = getattr(self._tls, "curl", None)
        if sess is None:
            try:
                sess = creq.Session(impersonate="chrome")
                self._tls.curl = sess
            except Exception:
                sess = False
                self._tls.curl = False
        try:
            if sess:
                r = sess.get(url, headers=h, timeout=self.timeout)
            else:
                r = creq.get(url, headers=h, timeout=self.timeout, impersonate="chrome")
        except Exception:
            return None
        if r.status_code == 200 and not _looks_blocked(r.text or ""):
            return r.text
        return None

    def _proxy_get(self, prefix, url):
        try:
            r = self.proxy_client.get(prefix + quote(url, safe=""), timeout=45)
        except Exception:
            return None
        if r.status_code == 200 and len(r.text) > 200 and not _looks_blocked(r.text):
            return r.text
        return None

    def _jina_get(self, url):
        with self._jina_lock:
            wait = self._jina_last + JINA_MIN_INTERVAL - time.time()
            if wait > 0:
                time.sleep(wait)
            self._jina_last = time.time()
        try:
            r = self.proxy_client.get(PROXY_JINA + url, headers={"Accept": "text/plain"}, timeout=60)
        except Exception:
            return None
        return r.text if (r.status_code == 200 and r.text) else None

    def _get(self, tier, url, referer):
        if tier == "httpx":
            try:
                if url.startswith(PROXY_JINA):
                    r = self.proxy_client.get(url, headers={"Accept": "text/plain"}, timeout=60)
                    return r.text if (r.status_code == 200 and r.text) else None
                # fx/vx 的 JSON 接口: 只需 UA + json Accept; twjn/列表页则送完整浏览器头
                is_api = "fxtwitter.com" in url or "vxtwitter.com" in url
                if is_api:
                    hdrs = {"User-Agent": random.choice(UA_POOL), "Accept": "application/json"}
                else:
                    hdrs = _headers(referer)
                r = self.client.get(url, headers=hdrs, timeout=self.timeout)
            except Exception:
                return None
            if r.status_code != 200:
                return None
            if not is_api and _looks_blocked(r.text):
                return None
            return r.text
        if tier == "curl":
            return self._curl_get(url, referer)
        if tier == "allorigins":
            return self._proxy_get(PROXY_ALLORIGINS, url)
        if tier == "codetabs":
            return self._proxy_get(PROXY_CODETABS, url)
        return None

    def _probe_url(self, tier, url, want_mp4=False):
        try:
            text = self._get(tier, url, BASE_URL + "/")
        except Exception:
            return False
        if not text:
            return False
        if want_mp4:
            return bool(extract_mp4(text)) or _looks_twjn_page(text)
        return True

    def _probe_jina(self):
        try:
            r = self.proxy_client.get(PROXY_JINA + f"{BASE_URL}/twjn.php?v={PROBE_MID}",
                                      headers={"Accept": "text/plain"}, timeout=45)
        except Exception:
            return False
        return r.status_code == 200 and "monsnode" in (r.text or "")

    def probe(self, force=False):
        with self._probe_lock:
            if not force and (self.resolve_mode is not None or self.blocked or self.jina_ok):
                return
            self.blocked = False
            log("探测可用传输层 (monsnode 可能对机房 IP 做 Cloudflare 拦截) ...")
            for tier in self.RAW_TIERS:
                if self._probe_url(tier, f"{BASE_URL}/twjn.php?v={PROBE_MID}", want_mp4=True):
                    self.resolve_mode = tier
                    break
            if self.resolve_mode:
                log(f"  MP4/文案解析层: {self.resolve_mode}")
            else:
                self.jina_ok = self._probe_jina()
                if self.jina_ok:
                    log("  MP4/文案解析层: jina 阅读器 (直连被拦, 速度较慢)")
                else:
                    log("  MP4/文案解析层: ❌ 全部被拦", "ERROR")
            if self.resolve_mode is None and not self.jina_ok:
                self.blocked = True
                log("  ❌ 所有传输层均被封锁 — 本轮无法回填", "ERROR")

    def _tier_retry(self, tier, url, referer, tries):
        for i in range(max(1, tries)):
            try:
                text = self._get(tier, url, referer)
            except Exception:
                text = None
            if text:
                return text
            if i < tries - 1:
                time.sleep(0.6 + i * 0.8)
        return None

    def fetch_resolve(self, url, tries=2, referer=None):
        """twjn.php 解析: 用解析层; 该层失败依次换其它层, 最后兜底 jina。"""
        if self.blocked:
            return None
        if self.resolve_mode is None and not self.jina_ok:
            self.probe()
            if self.blocked:
                return None
        if self.resolve_mode:
            text = self._tier_retry(self.resolve_mode, url, referer, tries)
            if text:
                self._stats["ok"] += 1
                return text
            self._stats["fail"] += 1
            for alt in self.RAW_TIERS:
                if alt == self.resolve_mode:
                    continue
                try:
                    text = self._get(alt, url, referer)
                except Exception:
                    text = None
                if text:
                    self.resolve_mode = alt
                    self._stats["ok"] += 1
                    log(f"  解析层切换 → {alt}")
                    return text
        if self.jina_ok:
            j = self._jina_get(url)
            if j:
                self._stats["ok"] += 1
                self._stats["jina_ok"] += 1
                return j
        return None

    def fetch_json(self, url, tries=2):
        """fx/vx JSON 接口: 直连优先, 失败依次换代理层 (不走 jina, 它返回 markdown 不是 JSON)。"""
        tiers = ("httpx", "curl") if self.resolve_mode in (None, "httpx", "curl") else (self.resolve_mode, "httpx", "curl")
        for tier in tiers:
            try:
                text = self._get(tier, url, None)
            except Exception:
                text = None
            if text and len(text) > 10:
                try:
                    import json as _json
                    return _json.loads(text)
                except Exception:
                    return None
        # 全代理层再试 (allorigins / codetabs 会原样透传 JSON)
        for tier in ("allorigins", "codetabs"):
            try:
                text = self._get(tier, url, None)
            except Exception:
                text = None
            if text and '"tweet"' in text:
                try:
                    import json as _json
                    return _json.loads(text)
                except Exception:
                    continue
        return None

    def close(self):
        for c in (getattr(self, "client", None), getattr(self, "proxy_client", None),
                  getattr(self._tls, "curl", None)):
            try:
                if c:
                    c.close()
            except Exception:
                pass


# ---------------------------------------------------------------- Supabase (httpx 直连, 与 main.py 同风格)
SUPABASE_URL = (os.environ.get("SUPABASE_URL", "") or "").strip().strip("'\"")
SUPABASE_KEY = (
    (os.environ.get("SUPABASE_SERVICE_KEY", "") or os.environ.get("SUPABASE_KEY", "") or "")
    .strip().strip("'\"").replace("\n", "").replace("\r", "")
)


def sb_headers(json_body=False):
    h = {"apikey": SUPABASE_KEY, "Authorization": "Bearer " + SUPABASE_KEY}
    if json_body:
        h["Content-Type"] = "application/json"
    return h


def sb_fetch_empty(limit, offset):
    """取无标题视频 (PostgREST 单次最多 1000 行, 调用方负责 offset 分页)。"""
    take = min(1000, limit - offset) if limit else 1000
    url = (
        SUPABASE_URL + "/rest/v1/videos"
        + "?select=video_id,title,author,monsnode_video_id,video_url,duration,has_mp4"
        + "&or=(title.is.null,title.eq.)"
        + "&monsnode_video_id=not.is.null"
        + "&order=id.desc"
        + f"&limit={take}&offset={offset}"
    )
    r = httpx.get(url, headers=sb_headers(), timeout=60)
    if r.status_code != 200:
        log(f"查询无标题失败: HTTP {r.status_code} {r.text[:120]}", "WARN")
        return []
    return r.json() or []


def sb_patch(video_id, patch):
    url = SUPABASE_URL + "/rest/v1/videos?video_id=eq." + quote(video_id, safe="")
    try:
        r = httpx.patch(url, headers=sb_headers(True), json=patch, timeout=30)
        return r.status_code in (200, 201, 204)
    except Exception:
        return False


# ---------------------------------------------------------------- 单行回填
def fetch_tweet_meta(fetcher, tweet_id):
    if not tweet_id or not re.fullmatch(r"\d{12,25}", str(tweet_id)):
        return None, None
    for tmpl in FX_URLS:
        try:
            data = fetcher.fetch_json(tmpl.format(tweet_id), tries=1)
        except Exception:
            data = None
        if data:
            title, author = fx_meta_from_json(data)
            if title or author:
                return title, author
    return None, None


def backfill_one(fetcher, row):
    """单行回填, 返回 'ok' / 'fail' / 'skip'。row 需含 video_id/title/author/
    monsnode_video_id/video_url/has_mp4。"""
    if (row.get("title") or "").strip():
        return "skip"
    now = datetime.now(timezone.utc).isoformat()
    tweet_id, mp4 = None, None
    mid = (row.get("monsnode_video_id") or "").strip()
    if mid and mid.isdigit():
        # cache-buster 防代理缓存 (站内同策略)
        url = f"{BASE_URL}/twjn.php?v={mid}&_r={random.randint(100000, 999999)}"
        try:
            html = fetcher.fetch_resolve(url, tries=2, referer=BASE_URL + "/")
        except Exception:
            html = None
        if html:
            mp4 = extract_mp4(html)
            tweet_id = extract_tweet_id(html)
    if not tweet_id:
        m = RE_STATUS.search(row.get("video_url") or "")
        tweet_id = m.group(1) if m else None
    title, author = fetch_tweet_meta(fetcher, tweet_id) if tweet_id else (None, None)
    patch = {"updated_at": now}
    if title:
        patch["title"] = title
    if author and (not (row.get("author") or "") or row.get("author") == "anon-user"):
        patch["author"] = author
    if mp4 and not row.get("has_mp4"):
        patch.update({"duration": mp4, "mp4_url": mp4, "has_mp4": True, "needs_rescrape": False})
    if len(patch) <= 1:
        return "fail"
    return "ok" if sb_patch(row["video_id"], patch) else "fail"


def selftest():
    log("自检开始 (逐层探测 twjn + fx) ...")
    f = Fetcher()
    log(f"  curl_cffi: {'已安装 ✅' if creq is not None else '未安装 ⛔ (pip install curl_cffi)'}")
    for tier in Fetcher.RAW_TIERS:
        try:
            t = f._get(tier, f"{BASE_URL}/twjn.php?v={PROBE_MID}", BASE_URL + "/")
        except Exception as e:
            t = None
            log(f"  [{tier:10s}] twjn 异常: {type(e).__name__}: {str(e)[:80]}")
        u = extract_mp4(t)
        if u:
            log(f"  [{tier:10s}] twjn: ✅ OK → {u[:70]}")
        elif t and _looks_twjn_page(t):
            log(f"  [{tier:10s}] twjn: ⚠️ 有响应但该视频无 mp4 (页 {len(t)}B, 推文ID={extract_tweet_id(t)})")
        elif t:
            log(f"  [{tier:10s}] twjn: ⚠️ 有响应但不像 twjn 页 ({len(t)}B)")
        else:
            log(f"  [{tier:10s}] twjn: ❌ 失败/被 Cloudflare 拦截")
    # fx 直连自检 (取探测视频的真实推文 ID)
    tid = None
    try:
        html = f._get(f.resolve_mode or "httpx", f"{BASE_URL}/twjn.php?v={PROBE_MID}", BASE_URL + "/")
        tid = extract_tweet_id(html)
    except Exception:
        pass
    if tid:
        for tmpl in FX_URLS:
            try:
                r = httpx.get(tmpl.format(tid), timeout=20)
                if r.status_code == 200 and '"tweet"' in r.text:
                    log(f"  [fx] {tmpl.split('/')[2]}: ✅ OK (推文 {tid})")
                else:
                    log(f"  [fx] {tmpl.split('/')[2]}: ❌ HTTP {r.status_code}")
            except Exception as e:
                log(f"  [fx] {tmpl.split('/')[2]}: ❌ {type(e).__name__} {str(e)[:60]}")
    else:
        log("  [fx] 跳过 (未拿到探测推文 ID)")
    j = f._probe_jina()
    log(f"  [{'jina':10s}] twjn: {'✅ OK (仅解析可用)' if j else '❌ 失败'}")
    f.close()


def main(limit=500, workers=12):
    if not SUPABASE_URL or len(SUPABASE_KEY) < 100:
        log("请设置 SUPABASE_URL 和 SUPABASE_SERVICE_KEY (或 SUPABASE_KEY) 环境变量", "ERROR")
        sys.exit(1)
    fetcher = Fetcher()
    fetcher.probe()
    if fetcher.blocked:
        log("传输层全部被拦, 本轮跳过 (队列未改动)", "ERROR")
        fetcher.close()
        return
    # offset 分页拉取 (PostgREST 1000 行上限; 同一轮内失败行不重复取)
    rows = []
    offset = 0
    while len(rows) < limit:
        batch = sb_fetch_empty(limit, offset)
        if not batch:
            break
        rows.extend(batch)
        offset += len(batch)
        if len(batch) < min(1000, limit - len(rows) + len(batch)):
            break
        time.sleep(0.3)
    rows = rows[:limit]
    if not rows:
        log("没有无标题视频 🎉")
        fetcher.close()
        return
    log(f"待回填 {len(rows)} 条 (并发 {workers}, 解析层 {fetcher.resolve_mode or 'jina'})")
    done = ok = fail = skip = 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(backfill_one, fetcher, r): r for r in rows}
        for f in as_completed(futs):
            r = futs[f]
            done += 1
            try:
                st = f.result()
            except Exception as e:
                print("ERR", r.get("video_id"), str(e)[:80])
                st = "fail"
            if st == "ok":
                ok += 1
            elif st == "fail":
                fail += 1
            else:
                skip += 1
            print(f"[{done}/{len(rows)}] {r.get('video_id')} -> {st}", flush=True)
    log(f"完成: ok={ok} fail={fail} skip={skip} total={done} ({time.time()-t0:.0f}s) 传输统计={fetcher._stats}")
    fetcher.close()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "test":
        selftest()
    else:
        lim = _env_int("TEXT_LIMIT", 500)
        if "--limit" in sys.argv:
            try:
                lim = int(sys.argv[sys.argv.index("--limit") + 1])
            except Exception:
                pass
        w = _env_int("TEXT_WORKERS", 12)
        if "--workers" in sys.argv:
            try:
                w = int(sys.argv[sys.argv.index("--workers") + 1])
            except Exception:
                pass
        main(limit=lim, workers=max(1, min(w, 32)))

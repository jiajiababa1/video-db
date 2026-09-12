"""
monsnode 爬虫 v12 — 多层反 Cloudflare 传输 + HTTP 优先抓取
================================================================
为什么重写:
  v9 用 Playwright 真实导航抓列表页，2026-09-12 起 GitHub Actions 上
  page.goto(domcontentloaded) 对 *所有* 栏目 100% 超时 → pages_crawled=0，
  一条都存不进，用户看到「抓不全」。而 monsnode 的列表页其实是纯服务端渲染的
  静态 HTML，用普通 HTTP GET 就能拿到全部 80 张卡片。所以改为 httpx 直连。

v10 的改进:
  1. HTTP 直连列表页 (httpx)，稳定 / 极快 / 不受外部 CDN 与 JS 影响
  2. 修复分页参数: monsnode 只认 ?page=N (1..20)。旧的 ?p=N 被服务器忽略，
     导致普通栏目永远只抓到第 1 页。
  3. 新增 search.php 关键词抓取 —— 归档只暴露最新 ~1600 条 (20 页)，
     而搜索能直达整个历史库 (v 号低至几十万)，这是「抓全」的关键。
  4. MP4 解析改为 HTTP GET twjn.php?v=<id>，23 路并发 → 每轮可解析上万条
     (旧版 Playwright 每轮只解析 80 条)。
  5. 不再用「重试 3 次即永久放弃」——实测老视频的 twjn.php 依然有效，
     死链池是被旧版错误解析器毒化的，现在会持续流转全部待解析视频。
  6. 保底回退: 若 HTTP 被 Cloudflare 拦截，装过 playwright 时自动回退浏览器。
  7. v11 关键修复: Supabase/PostgREST 单次查询最多只返回 1000 行 —— 旧版
     sb_pending 不管 limit 设多大都只能拿到 1000 条, 解析队列被死死卡在
     1000/次。现改为 offset 分页拉取, 并新增 apply_mp4_results 批量写回 RPC
     (数据库还没建该函数时自动逐条 PATCH 兜底)。解析改为「边解析边写回」分块,
     避免一次性解析几万条后写回超时。
  8. v12 关键修复: monsnode 起对 GitHub Actions 的机房 IP 返回 Cloudflare 403 挑战页
     (住宅 IP / 浏览器正常, twjn.php 也一样被拦)。新增「传输层」抽象, 启动时自动探测,
     按 httpx(HTTP/2) → curl_cffi(伪装 Chrome TLS 指纹) → allorigins → codetabs 依次尝试,
     分别记住「列表抓取层」和「MP4 解析层」(可不同); 解析再兜底到 jina 阅读器。
     全部被拦时提前结束并明确报错, 不再把几万条当成「解析失败」空转。用 `python main.py test`
     会逐层打印结果, 一眼看出哪层可用。

运行模式:
  python main.py full      # 抓列表 + 保存 + 解析一批 MP4
  python main.py resolve   # 只解析数据库里待处理的 MP4 (轻量, 建议高频跑)
  python main.py test      # 连通性自检, 打印每一步的 HTTP 状态, 用于排错
"""
import os
import sys
import re
import time
import json
import base64
import random
import threading
import html as htmlmod
from datetime import datetime, timezone, timedelta
from urllib.parse import urljoin, quote_plus, quote
from concurrent.futures import ThreadPoolExecutor, as_completed

import httpx

try:
    from curl_cffi import requests as creq  # 浏览器 TLS 指纹 (curl_cffi)
except Exception:
    creq = None

BASE_URL = "https://monsnode.com"

# ---------- 反 Cloudflare 传输层 ----------
# 2026-09-12 起 monsnode 对 GitHub Actions 的机房 IP 返回 Cloudflare 403 挑战页
# (住宅 IP / 浏览器正常访问)。所以按顺序探测可用的「传输层」, 自动选择能通过的那层:
#   1) httpx 直连 (HTTP/2)
#   2) curl_cffi 伪装 Chrome 的 TLS 指纹 (绕过 CF 的 JA3 指纹拦截)
#   3) allorigins 公共代理中转
#   4) codetabs 公共代理中转
# 若以上全部被拦, 仅 MP4 解析再兜底到 jina 阅读器 (r.jina.ai, 只能解析, 不能抓列表)。
PROXY_ALLORIGINS = "https://api.allorigins.win/raw?url="
PROXY_CODETABS = "https://api.codetabs.com/v1/proxy?quest="
PROXY_JINA = "https://r.jina.ai/"
PROBE_MID = "26199120"  # 已知有效的 twjn id, 用于探测解析能力
JINA_MIN_INTERVAL = float(os.environ.get("JINA_MIN_INTERVAL", "3.0") or 3.0)  # jina 免费额度约 20 次/分


def _env_int(name, default):
    try:
        v = os.environ.get(name, "").strip()
        return int(v) if v else default
    except Exception:
        return default


# ---------- 可调参数 (都可用环境变量覆盖) ----------
ARCHIVE_MAX_PAGES   = _env_int("ARCHIVE_MAX_PAGES", 25)     # 归档 ?page=N 上限 (站点实际 ~20)
SEARCH_MAX_PAGES    = _env_int("SEARCH_MAX_PAGES", 15)      # 每个关键词最多翻多少页
RANK_MAX_PAGES      = _env_int("RANK_MAX_PAGES", 5)         # 每个排行周期最多翻多少页
CRAWL_TIME_BUDGET   = _env_int("CRAWL_TIME_BUDGET", 600)    # 抓列表总时间预算(秒)
MP4_WORKERS         = _env_int("MP4_WORKERS", 24)           # twjn.php 并发数
SB_WORKERS          = _env_int("SB_WORKERS", 16)            # 写 Supabase 并发数
FULL_RESOLVE_LIMIT  = _env_int("FULL_RESOLVE_LIMIT", 3000)  # full 模式解析条数
FULL_RESOLVE_BUDGET = _env_int("FULL_RESOLVE_BUDGET", 360)  # full 模式解析时间预算(秒)
RESOLVE_LIMIT       = _env_int("RESOLVE_LIMIT", 20000)      # resolve 模式解析条数
RESOLVE_BUDGET      = _env_int("RESOLVE_BUDGET", 900)       # resolve 模式解析时间预算(秒)

BATCH_SIZE = 100
REQUEST_TIMEOUT = 25

# ---------- 播放页 / 站点结构常量 ----------
CARD_SPLIT = '<div class="listn"'
RE_MID = re.compile(r"redirect\.php\?v=(\d+)")
RE_IMG_SRC = re.compile(r'<img\b[^>]*?\bsrc="([^"]*)"', re.S)
RE_IMG_ALT = re.compile(r'<img\b[^>]*?\balt="([^"]*)"', re.S)
RE_AUTHOR = re.compile(
    r'<div class="user">\s*<a[^>]*>\s*<div>\s*<span>([^<]*)</span>', re.S
)
RE_ATOB = re.compile(r"atob\(\s*'([^']+)'\s*\)")
RE_MP4_URL = re.compile(r"https?://video\.twimg\.com/[^\s'\"<>)\]]+\.mp4[^\s'\"<>)\]]*")
RE_BTN = re.compile(r'<a\s+href="([^"]+)"[^>]*class="btn"[^>]*>(.*?)</a>', re.S)

UA_POOL = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
]

# 搜索词库: 用于翻出归档页看不到的历史内容 (归档只留最新 ~1600 条)
DEFAULT_SEARCH_TERMS = [
    # 英文/通用
    "nsfw", "sex", "porn", "nude", "naked", "hentai", "amateur", "jav",
    "japanese", "asian", "leak", "lingerie", "bikini", "gym", "yoga",
    "shower", "voyeur", "upskirt", "cosplay", "idol", "milf", "tease",
    "spy", "toilet", "sex", "hot", "girl", "tiktok", "onlyfans", "av",
    # 日文
    "素人", "パンチラ", "盗撮", "おっぱい", "巨乳", "美乳", "エロ", "セクシー",
    "水着", "競泳", "着エロ", "JD", "JK", "女子大生", "OL", "人妻", "熟女",
    "ギャル", "コスプレ", "アイドル", "グラビア", "放尿", "フェラ", "オナニー",
    "パイズリ", "中出し", "潮吹き", "乳首", "お尻", "パンスト", "ストッキング",
    "ニーハイ", "制服", "ブルマ", "スク水", "体育", "部活", "マッサージ",
    "整体", "温泉", "混浴", "露出", "野外", "電車", "痴漢", "風呂", "シャワー",
    "筋トレ", "ジム", "脚", "下着",
]


def _search_terms():
    raw = os.environ.get("SEARCH_TERMS", "").strip()
    if not raw:
        terms = DEFAULT_SEARCH_TERMS
    else:
        terms = [t.strip() for t in re.split(r"[,\n]", raw) if t.strip()]
        if not terms:
            terms = DEFAULT_SEARCH_TERMS
    seen, out = set(), []
    for t in terms:
        if t not in seen:
            seen.add(t)
            out.append(t)
    return out


def _rotated_terms():
    """把搜索词轮换一个起点。单轮 full 抓取的时间预算有限, 若每次都从第 1 个词
    开始, 就永远只能抓到前几个词覆盖的历史区间。按小时轮换起点 → 多轮下来
    全部关键词都会被覆盖到。"""
    terms = _search_terms()
    if len(terms) <= 1:
        return terms
    bucket = int(time.time() // 3600)
    off = (bucket * 7) % len(terms)
    return terms[off:] + terms[:off]


# ---------------------------------------------------------------- 日志 / 工具
def log(msg, level="INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


def _looks_blocked(text):
    """Cloudflare / 挑战页判定。注意正常的 monsnode 页面里也含
    'challenges.cloudflare.com' (CF 注入的 JSD 脚本)，所以不能拿它当特征。
    空响应 (如 'Data does not exist.') 不算被拦。"""
    if not text:
        return False
    head = text[:4000]
    return ("Just a moment" in head) or ("Attention Required" in head) or ("__cf_chl" in head)


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


# ---------------------------------------------------------------- HTTP 抓取器
def _looks_twjn_page(text):
    """twjn.php 的页面特征 (用于探测解析层是否可用, 不依赖某个具体视频是否还在)。"""
    if not text:
        return False
    return ("atob(" in text) or ("Data does not exist" in text) or ("Link to external site" in text)


def _extract_mp4(text):
    """从页面里取出 video.twimg.com 的 mp4 链接。
    原始页面: URL 藏在 atob('base64') 里; jina 阅读器: URL 是明文 (markdown)。"""
    if not text:
        return None
    m = RE_ATOB.search(text)
    if m:
        try:
            u = base64.b64decode(m.group(1)).decode("utf-8", "ignore").strip()
            if "video.twimg.com" in u:
                return u.rstrip(".,*)]\"'")
        except Exception:
            pass
    m2 = RE_MP4_URL.search(text)
    return m2.group(0).rstrip(".,*)]\"'") if m2 else None


class Fetcher:
    """多传输层抓取器。会自动探测哪一层能通过 Cloudflare, 分别记住
    「列表抓取层」(self.mode) 与「MP4 解析层」(self.resolve_mode), 二者可能不同。"""

    RAW_TIERS = ("httpx", "curl", "allorigins", "codetabs")

    def __init__(self):
        limits = httpx.Limits(max_connections=MP4_WORKERS + 8, max_keepalive_connections=MP4_WORKERS)
        try:
            self.client = httpx.Client(timeout=REQUEST_TIMEOUT, follow_redirects=True,
                                       limits=limits, http2=True)
        except Exception:
            self.client = httpx.Client(timeout=REQUEST_TIMEOUT, follow_redirects=True, limits=limits)
        self.proxy_client = httpx.Client(timeout=45, follow_redirects=True, limits=limits)
        self._tls = threading.local()
        self._pw_lock = threading.Lock()
        self._pw_disabled = False
        self._probe_lock = threading.Lock()
        self._jina_lock = threading.Lock()
        self._jina_last = 0.0
        self._last_probe = 0.0
        self.mode = None          # 列表抓取使用的传输层
        self.resolve_mode = None  # MP4 解析使用的传输层
        self.jina_ok = False      # 解析是否可兜底到 jina 阅读器
        self.blocked = False
        self._stats = {"ok": 0, "fail": 0, "pw_used": 0, "jina_ok": 0, "tier": None}

    # ---------- 各传输层 ----------
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
                r = sess.get(url, headers=h, timeout=REQUEST_TIMEOUT)
            else:
                r = creq.get(url, headers=h, timeout=REQUEST_TIMEOUT, impersonate="chrome")
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
                r = self.client.get(url, headers=_headers(referer), timeout=REQUEST_TIMEOUT)
            except Exception:
                return None
            return r.text if (r.status_code == 200 and not _looks_blocked(r.text)) else None
        if tier == "curl":
            return self._curl_get(url, referer)
        if tier == "allorigins":
            return self._proxy_get(PROXY_ALLORIGINS, url)
        if tier == "codetabs":
            return self._proxy_get(PROXY_CODETABS, url)
        return None

    # ---------- 探测 ----------
    def _probe_url(self, tier, url, want_mp4=False):
        try:
            text = self._get(tier, url, BASE_URL + "/")
        except Exception:
            return False
        if not text:
            return False
        if want_mp4:
            return bool(_extract_mp4(text)) or _looks_twjn_page(text)
        return CARD_SPLIT in text

    def _probe_jina(self):
        try:
            r = self.proxy_client.get(PROXY_JINA + f"{BASE_URL}/twjn.php?v={PROBE_MID}",
                                      headers={"Accept": "text/plain"}, timeout=45)
        except Exception:
            return False
        return r.status_code == 200 and "monsnode" in (r.text or "")

    def probe(self, force=False):
        with self._probe_lock:
            if not force and (self.mode is not None or self.resolve_mode is not None or self.blocked):
                return
            self._last_probe = time.time()
            self.blocked = False
            log("探测可用传输层 (站点可能对机房 IP 做 Cloudflare 拦截) ...")

            for tier in self.RAW_TIERS:
                if self._probe_url(tier, BASE_URL + "/"):
                    self.mode = tier
                    break
            log(f"  列表抓取层: {self.mode or '❌ 全部被拦'}")

            for tier in self.RAW_TIERS:
                if self._probe_url(tier, f"{BASE_URL}/twjn.php?v={PROBE_MID}", want_mp4=True):
                    self.resolve_mode = tier
                    break
            if self.resolve_mode:
                log(f"  MP4 解析层: {self.resolve_mode}")
            else:
                self.jina_ok = self._probe_jina()
                if self.jina_ok:
                    log("  MP4 解析层: jina 阅读器 (直连被拦, 速度较慢)")
                else:
                    log("  MP4 解析层: ❌ 全部被拦")

            self._stats["tier"] = self.mode or self.resolve_mode
            if self.mode is None and self.resolve_mode is None and not self.jina_ok:
                self.blocked = True
                log("  ❌ 所有传输层均被封锁 — 本轮无法抓取/解析", "ERROR")

    # ---------- 取页面 ----------
    def fetch(self, url, tries=3, referer=None):
        """列表页 (归档/排行/搜索) 抓取。"""
        if self.blocked:
            return None
        if self.mode is None:
            self.probe()
            if self.mode is None:
                self._stats["fail"] += 1
                return None
        last = "unknown"
        for i in range(max(1, tries)):
            try:
                text = self._get(self.mode, url, referer)
            except Exception as e:
                text, last = None, f"{type(e).__name__}: {str(e)[:80]}"
            if text:
                self._stats["ok"] += 1
                return text
            if last == "unknown":
                last = f"{self.mode}: 非 200 或被 Cloudflare 拦截"
            if i < tries - 1:
                time.sleep(1.0 + i * 1.5)
        self._stats["fail"] += 1
        # 当前层反复失败 → 重新探测整条链路 (60s 冷却, 避免风暴)
        if time.time() - self._last_probe > 60:
            self.probe(force=True)
            if self.mode:
                try:
                    text = self._get(self.mode, url, referer)
                except Exception:
                    text = None
                if text:
                    self._stats["ok"] += 1
                    return text
        # 最后兜底: Playwright (仅当装了)
        if not self._pw_disabled:
            text = self._playwright_fetch(url)
            if text:
                self._stats["pw_used"] += 1
                self._stats["ok"] += 1
                return text
        log(f"  抓取失败 {url} — {last}", "WARN")
        return None

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
        """twjn.php 解析: 用解析层; 该层失败时依次换其它层, 最后兜底 jina。"""
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
                    self._stats["tier_switched"] = self._stats.get("tier_switched", 0) + 1
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

    def _playwright_fetch(self, url):
        """用真实浏览器拿页面。只在 HTTP 被 CF 拦截时调用。
        用 wait_until='commit' 避免外部 CDN 拖死 domcontentloaded。"""
        with self._pw_lock:
            if self._pw_disabled:
                return None
            try:
                from playwright.sync_api import sync_playwright
            except Exception:
                self._pw_disabled = True
                return None
            try:
                with sync_playwright() as p:
                    b = p.chromium.launch(headless=True, args=[
                        "--no-sandbox", "--disable-setuid-sandbox",
                        "--disable-dev-shm-usage", "--disable-gpu",
                        "--disable-blink-features=AutomationControlled",
                        "--no-first-run", "--no-default-browser-check", "--mute-audio",
                    ])
                    ctx = b.new_context(
                        user_agent=random.choice(UA_POOL),
                        viewport={"width": 1366, "height": 768},
                        locale="ja-JP", timezone_id="Asia/Tokyo",
                    )
                    try:
                        ctx.add_init_script(
                            "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});"
                        )
                    except Exception:
                        pass
                    pg = ctx.new_page()
                    pg.goto(url, wait_until="commit", timeout=30000)
                    pg.wait_for_timeout(3500)
                    text = pg.content()
                    b.close()
                    if text and len(text) > 500 and not _looks_blocked(text):
                        return text
            except Exception as e:
                log(f"  Playwright 回退失败: {str(e)[:100]}", "WARN")
            return None

    def close(self):
        for c in (self.client, getattr(self, "proxy_client", None), getattr(self._tls, "curl", None)):
            try:
                if c:
                    c.close()
            except Exception:
                pass


# ---------------------------------------------------------------- 列表解析
def parse_cards(html_text, source_url, section):
    """从列表页 HTML 解析全部卡片。
    卡片结构 (服务端渲染, 无需 JS):
      <div class="listn" id="<twitter_status_id>">
        <a href=".../redirect.php?v=<monsnode_id>"><img src="<thumb>" alt="<title>"></a>
        <div class="user"><a ...><div><span>@author</span></div></a></div>
        <div class="vote">...</div>
      </div>
    """
    out = []
    if not html_text:
        return out
    for chunk in html_text.split(CARD_SPLIT)[1:]:
        chunk = chunk[:2500]
        m = re.match(r'\s+id="(\d+)"', chunk)
        if not m:
            continue
        status_id = m.group(1)
        mid_m = RE_MID.search(chunk)
        if not mid_m:
            continue
        mid = mid_m.group(1)
        src_m = RE_IMG_SRC.search(chunk)
        alt_m = RE_IMG_ALT.search(chunk)
        au_m = RE_AUTHOR.search(chunk)
        title = htmlmod.unescape(alt_m.group(1)).strip() if alt_m else ""
        thumb = htmlmod.unescape(src_m.group(1)).strip() if src_m else ""
        author = htmlmod.unescape(au_m.group(1)).strip() if au_m else ""
        out.append({
            "video_id": "v" + status_id,
            "monsnode_video_id": mid,
            "title": title,
            "thumbnail": thumb,
            "author": author,
            "url": "/v" + status_id,
            "source_page": source_url,
            "source_section": section,
        })
    return out


def find_more(html_text):
    """返回页面底部 'More' 按钮指向的相对 URL (无则 None)"""
    if not html_text:
        return None
    for m in RE_BTN.finditer(html_text):
        if "More" in re.sub(r"<[^>]+>", "", m.group(2)):
            return htmlmod.unescape(m.group(1))
    return None


def _next_url(current_url, more):
    if not more:
        return None
    nxt = urljoin(current_url, more)
    if nxt.rstrip("/") == current_url.rstrip("/"):
        return None
    return nxt


# ---------------------------------------------------------------- 抓取各栏目
def crawl_archive(fetcher, deadline):
    """归档: 首页 + ?page=1..N (站点实际到 20 页封顶, More 会指向自身)"""
    vids, seen = [], set()
    url = BASE_URL + "/"
    page = 0
    while url and page < ARCHIVE_MAX_PAGES and time.time() < deadline:
        h = fetcher.fetch(url, referer=BASE_URL + "/")
        if not h:
            break
        cards = parse_cards(h, url, "home" if page == 0 else "latest")
        new = [c for c in cards if c["video_id"] not in seen]
        for c in new:
            seen.add(c["video_id"])
        vids.extend(new)
        log(f"  [归档{page}] {url} → {len(cards)} 卡片, +{len(new)} 新 (累计 {len(vids)})")
        page += 1
        url = _next_url(url, find_more(h))
        time.sleep(0.35)
    return vids


def crawl_section_page(fetcher, label, start_url, max_pages, deadline, seen):
    """通用: 抓一个栏目并顺着 More 翻页"""
    vids = []
    url = start_url
    p = 0
    while url and p < max_pages and time.time() < deadline:
        h = fetcher.fetch(url, referer=BASE_URL + "/")
        if not h or len(h) < 200:
            break
        cards = parse_cards(h, url, label)
        new = [c for c in cards if c["video_id"] not in seen]
        for c in new:
            seen.add(c["video_id"])
        vids.extend(new)
        p += 1
        log(f"  [{label}] {url} → {len(cards)} 卡片, +{len(new)} 新")
        url = _next_url(url, find_more(h))
        time.sleep(0.35)
    return vids


def crawl_ranking(fetcher, deadline, seen):
    vids = []
    periods = [("24h", "24h"), ("3d", "3d"), ("7d", "7d"), ("30d", "30d"), ("", "ranking")]
    for period, label in periods:
        base = BASE_URL + "/?ranking=1" + (("&period=" + period) if period else "")
        for pg in range(1, RANK_MAX_PAGES + 1):
            if time.time() > deadline:
                return vids
            url = base if pg == 1 else base + "&page=" + str(pg)
            h = fetcher.fetch(url, referer=BASE_URL + "/")
            if not h or len(h) < 200:
                break
            cards = parse_cards(h, url, label)
            if not cards:
                break
            new = [c for c in cards if c["video_id"] not in seen]
            for c in new:
                seen.add(c["video_id"])
            vids.extend(new)
            log(f"  [{label}] {url} → {len(cards)} 卡片, +{len(new)} 新")
            if find_more(h) is None and pg > 1:
                break
            time.sleep(0.35)
    return vids


def crawl_search(fetcher, deadline, seen):
    vids = []
    terms = _rotated_terms()
    log(f"阶段3: 关键词搜索 ({len(terms)} 个词) — 直达历史库")
    for term in terms:
        if time.time() > deadline:
            log("  搜索时间预算用完, 停止")
            break
        url = BASE_URL + "/search.php?search=" + quote_plus(term) + "&u=ja"
        p = 0
        got = 0
        while url and p < SEARCH_MAX_PAGES and time.time() < deadline:
            h = fetcher.fetch(url, referer=BASE_URL + "/")
            if not h or len(h) < 200:
                break
            cards = parse_cards(h, url, "search")
            if not cards:
                break
            new = [c for c in cards if c["video_id"] not in seen]
            for c in new:
                seen.add(c["video_id"])
            vids.extend(new)
            got += len(new)
            p += 1
            url = _next_url(url, find_more(h))
            time.sleep(0.3)
        log(f"  [搜索] {term}: {p} 页, +{got} 新 (累计 {len(vids)})")
    return vids


# ---------------------------------------------------------------- Supabase
SUPABASE_URL = os.environ.get("SUPABASE_URL", "").strip().strip("'\"")
SUPABASE_KEY = (
    os.environ.get("SUPABASE_KEY", "").strip().strip("'\"")
    .replace("\n", "").replace("\r", "")
)


def sb_headers(json_body=False):
    h = {"apikey": SUPABASE_KEY, "Authorization": "Bearer " + SUPABASE_KEY}
    if json_body:
        h["Content-Type"] = "application/json"
    return h


def sb_pending(limit):
    """取待解析 MP4 的视频: has_mp4=false 且有 monsnode_video_id
    按 mp4_checked_at 升序(nulls first) → 从未解析/最久未检查的优先, 队列循环流转。
    不再按 retry_count 过滤: 实测老视频 twjn.php 依然有效, 旧版把它误判为死链。

    注意: Supabase 单次请求最多返回 1000 行, 所以必须用 offset 分页循环拉取,
    否则 limit 设多大都只有 1000 条。"""
    rows = []
    page = 1000
    offset = 0
    while len(rows) < limit:
        take = min(page, limit - len(rows))
        url = (
            SUPABASE_URL + "/rest/v1/videos"
            + "?select=video_id,monsnode_video_id"
            + "&has_mp4=is.false"
            + "&monsnode_video_id=not.is.null"
            + "&removed=not.is.true"
            + "&order=mp4_checked_at.asc.nullsfirst,video_id.asc"
            + "&limit=" + str(take)
            + "&offset=" + str(offset)
        )
        try:
            r = httpx.get(url, headers=sb_headers(), timeout=60)
        except Exception as e:
            log(f"查询待解析异常: {e}", "WARN")
            break
        if r.status_code != 200:
            log(f"查询待解析失败: HTTP {r.status_code} {r.text[:120]}", "WARN")
            break
        batch = r.json()
        if not batch:
            break
        rows.extend(batch)
        offset += len(batch)
        if len(batch) < take:
            break
    return [x for x in rows if (x.get("monsnode_video_id") or "").strip().isdigit()]


def sb_save(videos):
    """通过 upsert_videos RPC 批量保存 (该函数不会把已有 has_mp4 覆盖为 false)"""
    if not videos:
        return 0
    now = datetime.now(timezone.utc).isoformat()
    merged = {}
    for v in videos:
        vid = v["video_id"]
        if vid not in merged:
            merged[vid] = dict(v)
        else:
            ex = merged[vid]
            secs = [s for s in (ex.get("source_section") or "").split("|") if s]
            ns = v.get("source_section") or ""
            if ns and ns not in secs:
                secs.append(ns)
            ex["source_section"] = "|".join(secs)
            for k_src, k_dst in (("title", "title"), ("thumbnail", "thumbnail"), ("author", "author")):
                if not ex.get(k_dst) and v.get(k_src):
                    ex[k_dst] = v[k_src]

    records = []
    for vid, v in merged.items():
        records.append({
            "video_id": vid,
            "title": (v.get("title") or "")[:500],
            "thumbnail_url": (v.get("thumbnail") or "")[:1000],
            "video_url": urljoin(BASE_URL, v.get("url", ""))[:1000],
            "author": (v.get("author") or "")[:200],
            "duration": "",
            "mp4_url": "",
            "views": "",
            "monsnode_video_id": (v.get("monsnode_video_id") or "")[:50],
            "source_page": (v.get("source_page") or "")[:500],
            "source_section": (v.get("source_section") or "")[:100],
            "vote_up": 0,
            "vote_down": 0,
            "scraped_at": now,
            "has_mp4": False,
            "needs_rescrape": True,
        })

    saved = 0
    client = httpx.Client(timeout=60)
    try:
        for i in range(0, len(records), BATCH_SIZE):
            batch = records[i:i + BATCH_SIZE]
            try:
                r = client.post(SUPABASE_URL + "/rest/v1/rpc/upsert_videos",
                                headers=sb_headers(True), json={"videos": batch})
                if r.status_code in (200, 201, 204):
                    saved += len(batch)
                else:
                    log(f"  批量保存失败 HTTP {r.status_code}: {r.text[:150]}", "WARN")
                    for rec in batch:
                        rr = client.post(SUPABASE_URL + "/rest/v1/rpc/upsert_videos",
                                         headers=sb_headers(True), json={"videos": [rec]})
                        if rr.status_code in (200, 201, 204):
                            saved += 1
            except Exception as e:
                log(f"  保存异常: {str(e)[:120]}", "WARN")
    finally:
        client.close()
    return saved


def _sb_patch_one(video_id, patch):
    url = SUPABASE_URL + "/rest/v1/videos?video_id=eq." + quote(video_id, safe="")
    try:
        r = httpx.patch(url, headers=sb_headers(True), json=patch, timeout=30)
        return r.status_code in (200, 204)
    except Exception:
        return False


_RPC_BULK = {"state": None}  # None=未探测, True=可用, False=不可用


def sb_write_results(results):
    """results: {mid: (video_id, mp4 | DELETED_MARK | None)}
    成功 → mp4 字段 + has_mp4=true; 源站已删除 → removed=true (从站点隐藏, 不再重试);
    其它失败 → 只更新 mp4_checked_at (让它排到队尾)。

    首选一次性 RPC apply_mp4_results 批量写回 (一条 SQL 更新上千行, 极快,
    大幅降低请求数/超时风险); 若数据库还没有这个函数, 自动回退逐条 PATCH
    (见 sql/11_bulk_results.sql, 建议在 Supabase SQL Editor 里执行一次)。"""
    if not results:
        return 0, 0
    now = datetime.now(timezone.utc).isoformat()
    live = {mid: (vid, mp) for mid, (vid, mp) in results.items() if mp and mp != DELETED_MARK}
    deleted = {mid: vid for mid, (vid, mp) in results.items() if mp == DELETED_MARK}
    hit = len(live)
    fail = len(results) - hit

    if _RPC_BULK["state"] is not False:
        payload = []
        for mid, (vid, mp4) in results.items():
            if mp4 == DELETED_MARK:
                continue
            rec = {"video_id": vid}
            if mp4:
                rec["mp4_url"] = mp4
            payload.append(rec)
        try:
            client = httpx.Client(timeout=180)
            rpc_ok = True
            for i in range(0, len(payload), 1000):
                r = client.post(SUPABASE_URL + "/rest/v1/rpc/apply_mp4_results",
                                headers=sb_headers(True), json={"p_results": payload[i:i + 1000]})
                if r.status_code not in (200, 201, 204):
                    rpc_ok = False
                    if _RPC_BULK["state"] is None and r.status_code in (400, 404):
                        log(f"  批量 RPC 暂不可用 (HTTP {r.status_code}) → 本次回退逐条写入", "WARN")
                    else:
                        log(f"  批量 RPC 失败 HTTP {r.status_code}: {r.text[:120]}", "WARN")
                    break
            client.close()
            if rpc_ok:
                _RPC_BULK["state"] = True
                _mark_deleted(deleted, now)
                return hit, fail
        except Exception as e:
            log(f"  批量 RPC 异常: {str(e)[:120]}", "WARN")
        if _RPC_BULK["state"] is None:
            _RPC_BULK["state"] = False

    # 兜底: 逐条 PATCH
    ok = fail = 0
    with ThreadPoolExecutor(max_workers=SB_WORKERS) as ex:
        futs = []
        for mid, (vid, mp4) in results.items():
            if mp4 == DELETED_MARK:
                futs.append((ex.submit(_sb_patch_one, vid, {
                    "removed": True, "needs_rescrape": False,
                    "mp4_checked_at": now, "updated_at": now,
                }), False))
            elif mp4:
                futs.append((ex.submit(_sb_patch_one, vid, {
                    "duration": mp4, "mp4_url": mp4, "has_mp4": True,
                    "needs_rescrape": False, "retry_count": 0,
                    "mp4_checked_at": now, "updated_at": now,
                }), True))
            else:
                futs.append((ex.submit(_sb_patch_one, vid, {
                    "mp4_checked_at": now, "updated_at": now,
                }), False))
        for f, is_ok in futs:
            try:
                if f.result() and is_ok:
                    ok += 1
                elif not is_ok:
                    fail += 1
            except Exception:
                pass
    return ok, fail


def _mark_deleted(deleted, now):
    """把源站已删除的视频标记 removed=true 从站点隐藏 (不再反复重试占用解析配额)。"""
    if not deleted:
        return
    with ThreadPoolExecutor(max_workers=SB_WORKERS) as ex:
        futs = [ex.submit(_sb_patch_one, vid, {
            "removed": True, "needs_rescrape": False,
            "mp4_checked_at": now, "updated_at": now,
        }) for vid in deleted.values()]
        for f in futs:
            try:
                f.result()
            except Exception:
                pass


def sb_save_status(stats):
    record = {
        "last_run": datetime.now(timezone.utc).isoformat(),
        "videos_found": stats.get("videos_found", 0),
        "videos_saved": stats.get("videos_saved", 0),
        "pages_crawled": stats.get("pages_crawled", 0),
        "errors": "\n".join(stats.get("errors", [])[:10]),
    }
    try:
        c = httpx.Client(timeout=15)
        r = c.post(SUPABASE_URL + "/rest/v1/scrape_status", headers=sb_headers(True), json=record)
        if r.status_code not in (200, 201, 204):
            log(f"状态记录失败 HTTP {r.status_code}: {r.text[:120]}", "WARN")
        c.close()
    except Exception as e:
        log(f"状态记录异常: {e}", "WARN")


# ---------------------------------------------------------------- MP4 解析
DELETED_MARK = "__deleted__"   # twjn.php 明确回复「源站已删除」时使用
_DELETED_HINTS = ("this data has been deleted", "data does not exist", "has been deleted")


def resolve_one(fetcher, mid):
    url = f"{BASE_URL}/twjn.php?v={mid}"
    txt = fetcher.fetch_resolve(url, tries=2, referer=BASE_URL + "/")
    mp4 = _extract_mp4(txt)
    if mp4:
        return mp4
    if txt and any(h in txt.lower() for h in _DELETED_HINTS):
        return DELETED_MARK
    return None


def resolve_batch(fetcher, items, budget):
    """items: [(mid, video_id), ...] → 返回 {mid: (video_id, mp4)}"""
    results = {}
    if not items:
        return results
    t0 = time.time()
    total = len(items)
    done = 0
    by_mid = dict(items)
    with ThreadPoolExecutor(max_workers=MP4_WORKERS) as ex:
        futures = {ex.submit(resolve_one, fetcher, mid): mid for mid in by_mid}
        for f in as_completed(futures):
            mid = futures[f]
            done += 1
            try:
                mp4 = f.result()
            except Exception:
                mp4 = None
            results[mid] = (by_mid[mid], mp4)
            if done % 250 == 0:
                hit = sum(1 for _, mp in results.values() if mp)
                log(f"  解析 {done}/{total} → {hit} MP4 ({time.time()-t0:.0f}s)")
            if time.time() - t0 > budget:
                log(f"  解析时间预算用完 ({budget}s), 处理 {done}/{total}")
                for ff in futures:
                    ff.cancel()
                break
    return results


def resolve_pending(fetcher, limit, budget, tag="解析"):
    """从数据库取待解析视频, 分块「边解析边写回」(时间预算内尽可能多)"""
    fetcher.probe()
    if fetcher.blocked:
        log(f"[{tag}] 传输层全部被 Cloudflare 拦截, 跳过本轮 (数据未被改动)", "ERROR")
        return 0
    targets = sb_pending(limit)
    if not targets:
        log(f"[{tag}] 没有待解析视频 (可能都解析完了 🎉)")
        return 0
    log(f"[{tag}] 待解析 {len(targets)} 条 (并发 {MP4_WORKERS}, 层 {fetcher.resolve_mode or 'jina'})")
    t0 = time.time()
    total = len(targets)
    hit_total = 0
    done = 0
    CHUNK = 500
    FIRST = 40  # 首批小一点, 便于第一时间发现「整批被拦」
    while done < total:
        if time.time() - t0 > budget:
            log(f"[{tag}] 时间预算用完, 已处理 {done}/{total}")
            break
        size = FIRST if done == 0 else CHUNK
        chunk = targets[done:done + size]
        items = [(t["monsnode_video_id"].strip(), t["video_id"]) for t in chunk]
        remaining = max(5, budget - (time.time() - t0))
        ok_before = fetcher._stats["ok"]
        results = resolve_batch(fetcher, items, remaining)
        hit = sum(1 for _, mp in results.values() if mp and mp != DELETED_MARK)
        if fetcher._stats["ok"] == ok_before and hit == 0 and fetcher.resolve_mode is not None:
            log(f"[{tag}] 首批 {len(chunk)} 条全部抓取失败 — 传输层已失效, 提前结束"
                f" (未写入无效结果, 队列保持不变)", "ERROR")
            break
        sb_write_results(results)
        hit_total += hit
        done += len(chunk)
        log(f"[{tag}] 进度 {min(done, total)}/{total} → 累计 MP4 {hit_total}")
    log(f"[{tag}] 完成: 解析成功 {hit_total}, 共处理 {done}/{total} 条")
    return hit_total


# ---------------------------------------------------------------- 主流程
def scrape_all():
    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "pages_crawled": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "mp4_resolved": 0,
        "errors": [],
    }
    fetcher = Fetcher()
    fetcher.probe()
    deadline = time.time() + CRAWL_TIME_BUDGET
    seen = set()
    all_v = []
    try:
        log("=" * 60)
        log("阶段1: 归档页 (首页 + ?page=N)")
        arch = crawl_archive(fetcher, deadline)
        for c in arch:
            seen.add(c["video_id"])
        all_v.extend(arch)
        log(f"  归档合计 {len(arch)} 条")

        log("阶段2: 排行榜 (24h/3d/7d/30d/总榜)")
        rank = crawl_ranking(fetcher, deadline, seen)
        all_v.extend(rank)
        log(f"  排行合计 +{len(rank)} 条")

        log("阶段2b: trending 栏目")
        tr = crawl_section_page(fetcher, "trending", BASE_URL + "/trending", 6, deadline, seen)
        all_v.extend(tr)

        log("阶段3: 关键词搜索 (历史库)")
        sr = crawl_search(fetcher, deadline, seen)
        all_v.extend(sr)

        stats["videos_found"] = len(all_v)
        log(f"阶段4: 保存 {len(all_v)} 条到数据库 ...")
        saved = sb_save(all_v)
        stats["videos_saved"] = saved
        log(f"  保存完成: {saved} 条")

        stats["mp4_resolved"] = resolve_pending(
            fetcher, FULL_RESOLVE_LIMIT, FULL_RESOLVE_BUDGET, tag="解析"
        )
    except Exception as e:
        import traceback
        log(f"抓取流程异常: {e}", "ERROR")
        traceback.print_exc()
        stats["errors"].append(str(e)[:200])
    finally:
        fetcher.close()

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    log(f"HTTP 统计: {fetcher._stats}")
    sb_save_status(stats)
    return stats


def resolve_only():
    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "videos_found": 0, "videos_saved": 0, "pages_crawled": 0,
        "mp4_resolved": 0, "errors": [],
    }
    fetcher = Fetcher()
    try:
        stats["mp4_resolved"] = resolve_pending(
            fetcher, RESOLVE_LIMIT, RESOLVE_BUDGET, tag="解析"
        )
    except Exception as e:
        import traceback
        log(f"解析流程异常: {e}", "ERROR")
        traceback.print_exc()
        stats["errors"].append(str(e)[:200])
    finally:
        fetcher.close()
    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    log(f"HTTP 统计: {fetcher._stats}")
    sb_save_status(stats)
    return stats


def selftest():
    """连通性自检: 逐个传输层尝试列表页和 twjn 解析, 直接告诉你哪层可用。"""
    log("自检开始 (逐个传输层探测) ...")
    fetcher = Fetcher()
    log(f"  curl_cffi: {'已安装 ✅' if creq is not None else '未安装 ⛔ (pip install curl_cffi)'}")
    for tier in Fetcher.RAW_TIERS:
        try:
            h = fetcher._get(tier, BASE_URL + "/", BASE_URL + "/")
        except Exception as e:
            h = None
            log(f"  [{tier:10s}] 列表页异常: {type(e).__name__}: {str(e)[:80]}")
        if h:
            log(f"  [{tier:10s}] 列表页: ✅ OK ({len(h)}B, 卡片={h.count(CARD_SPLIT)})")
        else:
            log(f"  [{tier:10s}] 列表页: ❌ 失败/被 Cloudflare 拦截")
        try:
            t = fetcher._get(tier, BASE_URL + f"/twjn.php?v={PROBE_MID}", BASE_URL + "/")
        except Exception as e:
            t = None
            log(f"  [{tier:10s}] twjn: 异常: {type(e).__name__}: {str(e)[:80]}")
        u = _extract_mp4(t)
        if u:
            log(f"  [{tier:10s}] twjn: ✅ OK → {u[:70]}")
        elif t:
            log(f"  [{tier:10s}] twjn: ⚠️ 有响应但没解析出 mp4")
        else:
            log(f"  [{tier:10s}] twjn: ❌ 失败/被 Cloudflare 拦截")
    j = fetcher._probe_jina()
    log(f"  [{'jina':10s}] twjn: {'✅ OK (仅解析可用)' if j else '❌ 失败'}")
    ok = fetcher.mode is not None or fetcher.resolve_mode is not None or j
    fetcher.close()
    return ok


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "full"
    print("=" * 60)
    log(f"monsnode 爬虫 v12 (多层反 CF 传输) — 模式: {mode}")
    key_ok = bool(SUPABASE_KEY) and len(SUPABASE_KEY) > 100
    log(f"SUPABASE_URL={'已设置' if SUPABASE_URL else '❌'}  SUPABASE_KEY={'已设置' if key_ok else '❌'} ({len(SUPABASE_KEY)} 字符)")
    print("=" * 60)

    if mode == "test":
        selftest()
        return

    if not SUPABASE_URL or not key_ok:
        log("请设置 SUPABASE_URL 和 SUPABASE_KEY 环境变量", "ERROR")
        sys.exit(1)

    if mode == "resolve":
        stats = resolve_only()
        print("\n" + "=" * 60)
        print(f"  MP4 解析: {stats['mp4_resolved']} 个")
        print("=" * 60)
        return

    stats = scrape_all()
    print("\n" + "=" * 60)
    print(f"  发现: {stats['videos_found']}   保存: {stats['videos_saved']}   MP4: {stats['mp4_resolved']}")
    if stats["errors"]:
        print(f"  错误 ({len(stats['errors'])}):")
        for e in stats["errors"][:5]:
            print(f"    - {e[:120]}")
    print("=" * 60)


if __name__ == "__main__":
    main()

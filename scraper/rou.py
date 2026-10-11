"""
rou.video 爬虫模块 v1
================================================================
独立站点: https://rou.video (与 monsnode 不同的站)
专有栏目: source_section='rou', 子分类存在 source_page (分类 URL)

分类配置 (站主按网站实际栏目填写):
    ROU_CATEGORIES = {"显示名": "/路径", ...}
若留空, 则自动从首页导航发现分类链接 (fallback)。

视频 ID 方案: "rou_" + url hash 前 12 位 (与 av4_ 同理, 避免与 monsnode 冲突)
MP4 解析: rou.video 的视频页若直接含 mp4 链接则直接取;
          否则标记 needs_rescrape, 由前端后台解析器补。
"""
import os
import re
import time
import hashlib
import html as htmlmod
from urllib.parse import urljoin

ROU_BASE = "https://rou.video"

# ---- 分类配置 (站主填写, 例: {"最新": "/home", "热门": "/hot", "国产": "/c/chinese"}) ----
ROU_CATEGORIES = {
    u.strip(): v.strip()
    for u, v in (
        pair.split("=", 1) for pair in
        os.environ.get("ROU_CATEGORIES", "").split(",") if "=" in pair
    )
}

ROU_TIME_BUDGET = 240   # 本模块总时间预算(秒)
ROU_MAX_PAGES_PER_CAT = 8  # 每个分类最多抓几页

# ---- 通用视频卡片解析 (多模式 fallback, 适配未知 HTML 结构) ----
# 视频页 URL 模式 (用户确认): /v<id> 或 /v/<id>，如 https://rou.video/v12345
RE_ROU_VURL = re.compile(r'^/v/?[\w-]+/?$')
# 模式1: 标准 <a href="视频页"><img src="缩略图" alt="标题">
RE_ROU_CARD_A = re.compile(
    r'<a[^>]+href="([^"]+)"[^>]*>\s*<img[^>]+src="([^"]+)"[^>]*alt="([^"]*)"',
    re.S)
# 模式2: 卡片 div 包裹
RE_ROU_CARD_B = re.compile(
    r'<div[^>]+class="[^"]*(?:video|card|item|thumb)[^"]*"[^>]*>.*?<a[^>]+href="([^"]+)".*?<img[^>]+src="([^"]+)"',
    re.S)
# 模式3: 裸 mp4 链接 (详情页直链)
RE_ROU_MP4 = re.compile(r'https?://[^\\s\'"<>]+\.mp4[^\\s\'"<>]*')
# 时长 / 播放量
RE_ROU_DURATION = re.compile(r'(\d{1,3}:\d{2}(?::\d{2})?)')
RE_ROU_VIEWS = re.compile(r'([\d,.]+[万kKmM]?)\s*(?:播放|views|观看)')

RE_ROU_NAV = re.compile(r'<a[^>]+href="((?:/[^"]*|https?://rou\.video[^"]*))"[^>]*>([^<]{2,20})</a>')


def _vid_from_url(url):
    """从视频 URL 生成稳定 video_id"""
    h = hashlib.sha1(url.encode()).hexdigest()[:12]
    return "rou_" + h


def discover_categories(html_text):
    """从首页导航自动发现分类 (ROU_CATEGORIES 为空时的 fallback)"""
    out = {}
    if not html_text:
        return out
    for href, name in RE_ROU_NAV.findall(html_text):
        name = htmlmod.unescape(name).strip()
        href = href.strip()
        if not name or len(name) > 20:
            continue
        # 排除非分类链接
        low = href.lower()
        if any(k in low for k in ("login", "register", "search", "upload", "contact", "about",
                                  "privacy", "terms", "dmca", ".css", ".js", "#")):
            continue
        if href.startswith("/"):
            out[name] = href
    return out


def parse_rou_cards(html_text, source_url, category):
    """解析视频卡片, 返回视频记录列表"""
    out, seen = [], set()
    if not html_text:
        return out
    # 先试模式1
    cards = RE_ROU_CARD_A.findall(html_text)
    if len(cards) < 3:
        # fallback 模式2
        cards = [(m[0], m[1], "") for m in RE_ROU_CARD_B.findall(html_text)]
    for href, thumb, title in cards:
        href = htmlmod.unescape(href).strip()
        if not href or href.startswith("#") or href.startswith("javascript:"):
            continue
        # 只收站内视频页: 优先 /v<id> 模式 (用户确认)，fallback 收其他站内链接
        if href.startswith("/"):
            # /v 开头的一定是视频页
            if RE_ROU_VURL.match(href.split("?")[0]):
                full = urljoin(ROU_BASE, href)
            else:
                # 非 /v 链接：排除首页/分类/功能页
                low = href.lower()
                if any(k in low for k in ("/home", "/category", "/tag", "/search",
                                          "/login", "/register", ".css", ".js")):
                    continue
                full = urljoin(ROU_BASE, href)
        elif href.startswith(ROU_BASE):
            full = href
        else:
            continue
        # 过滤明显不是视频页的 (首页本身)
        if full.rstrip("/") in (ROU_BASE, ROU_BASE + "/home"):
            continue
        vid = _vid_from_url(full)
        if vid in seen:
            continue
        seen.add(vid)
        if thumb.startswith("//"):
            thumb = "https:" + thumb
        # 尝试从卡片附近找时长/作者 (宽松)
        out.append({
            "video_id": vid,
            "monsnode_video_id": "",
            "title": htmlmod.unescape(title).strip()[:200],
            "thumbnail": thumb[:1000],
            "author": "",
            "url": full,
            "video_url": full,
            "source_page": source_url,
            "source_section": "rou",
            "has_mp4": False,
            "needs_rescrape": True,
        })
    return out


def parse_rou_detail(html_text, page_url):
    """详情页: 找直链 mp4 / 作者 / 标题"""
    info = {"mp4": None, "author": "", "title": ""}
    if not html_text:
        return info
    m = RE_ROU_MP4.search(html_text)
    if m:
        info["mp4"] = m.group(0)
    mt = re.search(r"<title>(.*?)</title>", html_text, re.S)
    if mt:
        info["title"] = htmlmod.unescape(mt.group(1)).strip()[:200]
    ma = re.search(r'(?:作者|author|up主)[^<]{0,20}[:：]\s*([^<]{1,30})', html_text, re.I)
    if ma:
        info["author"] = htmlmod.unescape(ma.group(1)).strip()
    return info


def crawl_rou(fetcher, deadline, seen, log):
    """主入口: 首页 + 各分类, 返回新视频记录列表"""
    t0 = time.time()
    out = []

    def fetch(url, referer=None):
        try:
            return fetcher.fetch(url, referer=referer or ROU_BASE + "/")
        except Exception:
            return None

    # 1) 首页: 发现分类 + 抓首页视频
    home_html = fetch(ROU_BASE + "/home")
    if not home_html:
        home_html = fetch(ROU_BASE + "/")
    if not home_html:
        log("[rou] 首页抓取失败, 跳过本站", "WARN")
        return out

    cats = dict(ROU_CATEGORIES)
    if not cats:
        cats = discover_categories(home_html)
        log(f"[rou] 自动发现 {len(cats)} 个分类: {list(cats)[:8]}")
    # 首页视频也入库 (分类记为"首页")
    for c in parse_rou_cards(home_html, ROU_BASE + "/home", "首页"):
        if c["video_id"] not in seen:
            seen.add(c["video_id"])
            out.append(c)
    log(f"[rou] 首页 +{len([c for c in out])} 条")

    # 2) 各分类翻页
    for name, path in cats.items():
        if time.time() > deadline:
            break
        base = path if path.startswith("http") else urljoin(ROU_BASE, path)
        added = 0
        for pg in range(1, ROU_MAX_PAGES_PER_CAT + 1):
            if time.time() > deadline:
                break
            url = base + (f"?page={pg}" if "?" not in base else f"&page={pg}") if pg > 1 else base
            h = fetch(url, referer=ROU_BASE + "/home")
            if not h:
                break
            cards = parse_rou_cards(h, url, name)
            new = 0
            for c in cards:
                if c["video_id"] not in seen:
                    seen.add(c["video_id"])
                    out.append(c)
                    new += 1
            added += new
            if new == 0 and pg > 1:
                break  # 翻页无新内容, 换分类
            time.sleep(0.5)
        log(f"[rou] 分类「{name}」+{added} 条")

    # 3) 详情页直链嗅探 (只嗅本轮新抓的, 上限 30 个, 每个很快)
    sniffed = 0
    for c in out[:]:
        if time.time() > deadline or sniffed >= 30:
            break
        if c.get("has_mp4"):
            continue
        h = fetch(c["url"], referer=c["source_page"])
        sniffed += 1
        if not h:
            continue
        info = parse_rou_detail(h, c["url"])
        if info["mp4"]:
            c["has_mp4"] = True
            c["needs_rescrape"] = False
            c["duration"] = info["mp4"]
        if info["author"]:
            c["author"] = info["author"]
        if info["title"] and not c["title"]:
            c["title"] = info["title"]
        time.sleep(0.4)

    log(f"[rou] 完成: +{len(out)} 条 ({time.time()-t0:.0f}s)")
    return out

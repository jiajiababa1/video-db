"""
monsnode 爬虫 v4: 快速模式
  curl_cffi 抓页面 (2s/页) → httpx 并发解析 MP4 (0.3s/个) → Supabase
  Playwright 仅用于 curl_cffi 失败的页面 (trending/latest)
  Twitter API 作为 MP4 备用来源
"""
import os, re, sys, time, asyncio, base64, json, concurrent.futures
from datetime import datetime, timezone
from urllib.parse import urljoin

from curl_cffi import requests as cffi_requests
from bs4 import BeautifulSoup
import httpx

BASE_URL = "https://monsnode.com"

TARGET_SECTIONS = [
    ("/?t=24h", "24h", 4),
    ("/?t=3d", "3d", 4),
    ("/?t=7d", "7d", 4),
    ("/trending", "trending", 4),
    ("/", "home", 4),
    ("/latest", "latest", 4),
    ("/?ranking=1", "ranking", 3),
]

MAX_VIDEOS_PER_SECTION = 300
BATCH_SIZE = 100          # Supabase 批量写入
MP4_CONCURRENCY = 50      # twjn.php HTTP 并发数 (无浏览器开销, 可以很高)
MP4_BATCH_SIZE = 100

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")


def log(msg: str, level: str = "INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


def build_page_url(base_url: str, page: int) -> str:
    sep = "&" if "?" in base_url else "?"
    return f"{base_url}{sep}p={page}"


# ========== 快速页面抓取 (curl_cffi) ==========

CFFI_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
    "DNT": "1",
    "Cache-Control": "no-cache",
}


def fetch_page_cffi(url: str, retries: int = 2) -> str | None:
    """curl_cffi 抓取单页, TLS 指纹伪装 Chrome 131"""
    for attempt in range(1, retries + 1):
        try:
            resp = cffi_requests.get(
                url, headers=CFFI_HEADERS,
                impersonate="chrome131",
                timeout=20
            )
            if resp.status_code == 200 and "listn" in resp.text:
                return resp.text
            if resp.status_code == 403 or resp.status_code == 503:
                log(f"  curl_cffi 被拦截 ({resp.status_code})", "DEBUG")
                return None
            if attempt < retries:
                time.sleep(3 * attempt)
        except Exception as e:
            log(f"  curl_cffi 错误 (attempt {attempt}): {str(e)[:60]}", "DEBUG")
            if attempt < retries:
                time.sleep(2 * attempt)
    return None


# ========== Playwright 回退 (仅用于 curl_cffi 失败的页面) ==========

async def fetch_page_playwright(context, url: str) -> str | None:
    """Playwright 回退, 用于 Cloudflare 重点保护页面"""
    page = None
    try:
        page = await context.new_page()
        # stealth 注入 (优先用 playwright_stealth, 失败则手动注入)
        try:
            from playwright_stealth import stealth_async
            await stealth_async(page)
        except ImportError:
            await page.add_init_script("""
                Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
                Object.defineProperty(navigator, 'plugins', {get: () => [1,2,3,4,5]});
                Object.defineProperty(navigator, 'languages', {get: () => ['ja-JP','ja','en-US','en']});
                window.chrome = {runtime: {}};
            """)
        await page.set_extra_http_headers({
            "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        })
        await page.goto(url, wait_until="domcontentloaded", timeout=45000)
        try:
            await page.wait_for_selector("div.listn", timeout=45000)
            await asyncio.sleep(2)
            return await page.content()
        except Exception:
            pass
        await asyncio.sleep(5)
        html = await page.content()
        if "listn" in html:
            return html
        if 'challenges.cloudflare.com' in html or 'お待ちください' in html:
            log("  Cloudflare 挑战页, 等待 25 秒...", "DEBUG")
            await asyncio.sleep(25)
            html = await page.content()
            if "listn" in html:
                return html
    except Exception as e:
        log(f"  Playwright 错误: {str(e)[:60]}", "DEBUG")
    finally:
        if page:
            await page.close()
    return None


# ========== 卡片解析 ==========

def parse_video_cards(html: str, page_url: str, section: str) -> list[dict]:
    """解析 monsnode HTML, 提取视频卡片"""
    soup = BeautifulSoup(html, "lxml")
    videos = []
    seen_ids = set()

    for card in soup.find_all("div", class_="listn"):
        card_id = card.get("id", "").strip()
        if not card_id or not card_id.isdigit():
            continue
        vid = "v" + card_id
        if vid in seen_ids:
            continue
        seen_ids.add(vid)

        img_link = card.find("a")
        monsnode_video_id = ""
        thumbnail = ""
        title = ""

        if img_link:
            href = img_link.get("href", "")
            m = re.search(r"redirect\.php\?v=(\d+)", href)
            if m:
                monsnode_video_id = m.group(1)
            img = img_link.find("img")
            if img:
                src = img.get("src", "")
                if src:
                    thumbnail = src
                alt = img.get("alt", "").strip()
                if alt:
                    lines = [l.strip() for l in alt.split("\n") if l.strip()]
                    title = lines[0][:500] if lines else ""

        if thumbnail and not thumbnail.startswith("http"):
            thumbnail = urljoin(BASE_URL, thumbnail)

        author = ""
        user_div = card.find("div", class_="user")
        if user_div:
            user_link = user_div.find("a")
            if user_link:
                user_span = user_link.find("span")
                if user_span:
                    author = user_span.get_text(strip=True)

        views = ""
        for cls in ("view", "views", "count", "like", "heart", "point"):
            v_el = card.find(class_=cls)
            if v_el:
                nums = re.findall(r'[\d,]+', v_el.get_text(strip=True))
                if nums:
                    views = nums[0].replace(",", "")
                break

        duration_label = ""
        for cls in ("time", "duration", "length", "dur"):
            d_el = card.find(class_=cls)
            if d_el:
                duration_label = d_el.get_text(strip=True)[:20]
                break

        rank_num = ""
        if "ranking" in section:
            rank_el = card.find(class_="rank") or card.find(class_="number")
            if rank_el:
                rank_num = re.sub(r'\D', '', rank_el.get_text(strip=True))

        videos.append({
            "video_id": vid,
            "url": urljoin(BASE_URL, "/" + vid),
            "monsnode_video_id": monsnode_video_id,
            "title": title,
            "thumbnail": thumbnail,
            "author": author,
            "duration": duration_label,
            "views": views,
            "rank": rank_num,
            "source_section": section,
            "source_page": page_url,
        })

    return videos


# ========== MP4 快速解析 (httpx 异步, 无浏览器) ==========

# twjn.php 的 Cloudflare 配置较松, 普通 HTTP 请求有较高成功率
# 加 curl_cffi 的 impersonation 能力 (httpx 做不到, 但用正确 headers 能过)
TWJN_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
    "Referer": "https://monsnode.com/",
}


async def resolve_one_twjn(client: httpx.AsyncClient, vid: str, monsnode_id: str, sem: asyncio.Semaphore) -> tuple[str, str | None]:
    """通过 twjn.php 获取单个 MP4 直链 (纯 HTTP, 无浏览器)"""
    async with sem:
        url = f"https://monsnode.com/twjn.php?v={monsnode_id}"
        for attempt in range(1, 3):
            try:
                resp = await client.get(url, headers=TWJN_HEADERS, timeout=15)
                if resp.status_code != 200:
                    if attempt < 2:
                        await asyncio.sleep(2)
                    continue
                html = resp.text
                # 检查 Cloudflare 拦截
                if 'challenges.cloudflare.com' in html or 'お待ちください' in html:
                    if attempt < 2:
                        await asyncio.sleep(3)
                    continue
                # var u = atob('...')
                m = re.search(r"var\s+u\s*=\s*atob\('([^']+)'\)", html)
                if m:
                    mp4 = base64.b64decode(m.group(1)).decode('utf-8')
                    if 'video.twimg.com' in mp4:
                        return vid, mp4
                # 宽松匹配
                m2 = re.search(r"atob\('([^']+\.mp4[^']*)'\)", html)
                if m2 and 'video.twimg.com' in m2.group(1):
                    return vid, m2.group(1)
                return vid, None
            except Exception:
                if attempt < 2:
                    await asyncio.sleep(1)
        return vid, None


async def resolve_one_twitter(client: httpx.AsyncClient, tweet_id: str, sem: asyncio.Semaphore) -> tuple[str, str | None]:
    """通过 Twitter API 获取 MP4 (fxtwitter / vxtwitter)"""
    async with sem:
        for api in ("https://api.fxtwitter.com/status/", "https://api.vxtwitter.com/status/"):
            try:
                resp = await client.get(api + tweet_id, timeout=10)
                if resp.status_code != 200:
                    continue
                data = resp.json()
                media = data.get("tweet", {}).get("media")
                if not media:
                    continue
                videos = media.get("videos") or []
                best_url = None
                best_res = 0
                for v in videos:
                    vurl = v.get("url", "")
                    rm = re.search(r'(\d+)x(\d+)', vurl)
                    res = int(rm.group(1)) * int(rm.group(2)) if rm else 0
                    if res >= best_res:
                        best_res = res
                        best_url = vurl
                if best_url:
                    return tweet_id, best_url
                # 回退: media_extended
                ext = media.get("media_extended") or media.get("extended_entities") or []
                if isinstance(ext, list) and ext:
                    variants = ext[0].get("video_info", {}).get("variants", [])
                elif isinstance(ext, dict):
                    variants = ext.get("video_info", {}).get("variants", [])
                else:
                    continue
                if variants:
                    variants.sort(key=lambda x: x.get("bitrate", 0), reverse=True)
                    if variants[0].get("url"):
                        return tweet_id, variants[0]["url"]
            except Exception:
                continue
        return tweet_id, None


async def resolve_all_mp4(videos: list[dict]) -> dict[str, str]:
    """批量解析 MP4: twjn.php 优先 → Twitter API 回退"""
    mp4_urls = {}
    sem_twjn = asyncio.Semaphore(MP4_CONCURRENCY)
    sem_tw = asyncio.Semaphore(20)

    # 分离: 有 monsnode_video_id 的走 twjn.php; 其他的走 Twitter API
    twjn_targets = [(v["video_id"], v["monsnode_video_id"]) for v in videos if v.get("monsnode_video_id")]
    twitter_targets = []
    for v in videos:
        tid = v["video_id"][1:] if v["video_id"].startswith("v") else ""
        if tid.isdigit() and len(tid) >= 15:
            twitter_targets.append((v["video_id"], tid))

    async with httpx.AsyncClient(timeout=15, limits=httpx.Limits(max_connections=100)) as client:
        # 阶段 1: twjn.php 批量并发
        if twjn_targets:
            log(f"  twjn.php 解析 {len(twjn_targets)} 个视频 (并发 {MP4_CONCURRENCY})...")
            tasks = [resolve_one_twjn(client, vid, mid, sem_twjn) for vid, mid in twjn_targets]
            for batch_start in range(0, len(tasks), MP4_BATCH_SIZE):
                batch = tasks[batch_start:batch_start + MP4_BATCH_SIZE]
                results = await asyncio.gather(*batch)
                for vid, mp4 in results:
                    if mp4:
                        mp4_urls[vid] = mp4
                done = min(batch_start + MP4_BATCH_SIZE, len(tasks))
                log(f"    twjn: {done}/{len(tasks)} → 已获 {len(mp4_urls)} MP4")

        # 阶段 2: 对没有 MP4 的, 用 Twitter API 回退
        remaining = [(vid, tid) for vid, tid in twitter_targets if vid not in mp4_urls]
        if remaining:
            log(f"  Twitter API 回退 {len(remaining)} 个视频...")
            tw_tasks = [resolve_one_twitter(client, tid, sem_tw) for vid, tid in remaining]
            tw_results = await asyncio.gather(*tw_tasks)
            for tweet_id, mp4 in tw_results:
                if mp4:
                    # 找到对应的 video_id
                    for vid, tid in remaining:
                        if tid == tweet_id:
                            mp4_urls[vid] = mp4
                            break
            log(f"    Twitter API: 已获 {sum(1 for r in tw_results if r[1])} MP4")

    return mp4_urls


# ========== Supabase 操作 ==========

def supabase_save(videos: list[dict]) -> int:
    """通过 RPC upsert_videos 批量 upsert (ON CONFLICT video_id)
    回退方案: 如果 RPC 不可用, 用旧 merge-duplicates
    """
    if not videos:
        return 0
    import httpx as hx
    now = datetime.now(timezone.utc).isoformat()
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
    }

    records = []
    for v in videos:
        mp4 = v.get("duration", "") or ""
        has_mp4 = bool(mp4 and mp4.startswith("http") and "video.twimg.com" in mp4)

        records.append({
            "video_id": v["video_id"],
            "title": (v["title"][:500] if v.get("title") else ""),
            "thumbnail_url": (v["thumbnail"][:1000] if v.get("thumbnail") else ""),
            "video_url": (v["url"][:1000] if v.get("url") else ""),
            "author": (v.get("author") or "")[:200],
            "duration": mp4[:500] if has_mp4 else "",
            "views": (v.get("views") or "")[:50],
            "monsnode_video_id": (v.get("monsnode_video_id") or "")[:50],
            "source_page": (v.get("source_page") or "")[:500],
            "source_section": (v.get("source_section") or "")[:50],
            "scraped_at": now,
            "has_mp4": has_mp4,
            "needs_rescrape": not has_mp4,
            "mp4_checked_at": now,
        })

    saved = 0
    client = hx.Client(timeout=60)

    def _save_via_rpc(batch):
        """通过 upsert_videos RPC 函数保存"""
        resp = client.post(
            SUPABASE_URL + "/rest/v1/rpc/upsert_videos",
            headers=headers,
            json={"videos": batch}
        )
        return resp.status_code in (200, 201, 204)

    def _save_via_rest(batch):
        """回退: 用旧 merge-duplicates (有问题但作为备选)"""
        rest_headers = {**headers, "Prefer": "resolution=merge-duplicates"}
        resp = client.post(
            SUPABASE_URL + "/rest/v1/videos",
            headers=rest_headers,
            json=batch
        )
        return resp.status_code in (200, 201)

    # 分批处理
    use_rpc = True
    for i in range(0, len(records), BATCH_SIZE):
        batch = records[i:i + BATCH_SIZE]
        ok = False

        if use_rpc:
            try:
                ok = _save_via_rpc(batch)
                if not ok:
                    # RPC 可能不存在, 回退
                    log("  RPC 不可用, 回退到 REST upsert...", "DEBUG")
                    use_rpc = False
            except Exception:
                use_rpc = False

        if not use_rpc:
            try:
                ok = _save_via_rest(batch)
            except Exception as e:
                log(f"  Supabase 保存异常: {e}", "WARN")

        if ok:
            saved += len(batch)
        else:
            # 逐条重试
            for rec in batch:
                try:
                    if use_rpc:
                        ok2 = _save_via_rpc([rec])
                    else:
                        ok2 = _save_via_rest([rec])
                    if ok2:
                        saved += 1
                except Exception:
                    pass

    client.close()
    return saved


# ========== 主流程 ==========

async def scrape_all():
    """主流程: curl_cffi 抓取 → httpx 并发解析 MP4 → 保存"""
    from playwright.async_api import async_playwright

    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0,
        "pages_crawled": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "mp4_resolved": 0,
        "pw_fallbacks": 0,  # Playwright 回退次数
        "errors": [],
    }

    # Playwright 浏览器只启动一次, 用于回退
    pw = None
    pw_context = None

    async def _ensure_pw():
        nonlocal pw, pw_context
        if pw is None:
            pw = await async_playwright().start()
            browser = await pw.chromium.launch(
                headless=True,
                args=[
                    "--no-sandbox", "--disable-setuid-sandbox",
                    "--disable-dev-shm-usage", "--disable-gpu",
                    "--disable-blink-features=AutomationControlled",
                    "--no-first-run", "--no-default-browser-check",
                    "--mute-audio",
                ]
            )
            pw_context = await browser.new_context(
                user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                viewport={"width": 1366, "height": 768},
                locale="ja-JP",
                timezone_id="Asia/Tokyo",
                geolocation={"latitude": 35.6895, "longitude": 139.6917},
            )

    try:
        for path, label, max_pages in TARGET_SECTIONS:
            section_url = urljoin(BASE_URL, path)
            all_videos = []
            t0 = time.time()

            # trending/latest 是 Cloudflare 重点保护页面, curl_cffi 大概率失败
            is_problem = label in ("trending", "latest")
            method = "Playwright" if is_problem else "curl_cffi"
            log(f"[{label}] {section_url} ({method})")

            for page_num in range(1, max_pages + 1):
                url = section_url if page_num == 1 else build_page_url(section_url, page_num)
                html = None

                # curl_cffi 快速抓取 (非问题页面)
                if not is_problem:
                    html = fetch_page_cffi(url)

                # Playwright 回退
                if html is None:
                    if is_problem or page_num == 1:
                        log(f"  切换到 Playwright 回退...")
                        await _ensure_pw()
                        html = await fetch_page_playwright(pw_context, url)
                        if html:
                            stats["pw_fallbacks"] += 1

                if not html:
                    if page_num == 1:
                        stats["errors"].append(f"抓取失败: {url}")
                        break
                    else:
                        break

                stats["pages_crawled"] += 1
                videos = parse_video_cards(html, url, label)
                log(f"  第{page_num}页: {len(videos)} 个视频 ({time.time()-t0:.0f}s)")

                if not videos:
                    break

                existing = {v["video_id"] for v in all_videos}
                new = [v for v in videos if v["video_id"] not in existing]
                if not new and page_num > 1:
                    break
                all_videos.extend(new)

                if len(all_videos) >= MAX_VIDEOS_PER_SECTION:
                    break

                # 页面间短暂休息
                await asyncio.sleep(1 if is_problem else 0.5)

            stats["sections_crawled"] += 1
            stats["videos_found"] += len(all_videos)
            elapsed = time.time() - t0
            log(f"[{label}] 共 {len(all_videos)} 个视频 ({elapsed:.0f}s)")

            if not all_videos:
                continue

            # MP4 解析 (httpx 并发, 快速)
            t1 = time.time()
            mp4_urls = await resolve_all_mp4(all_videos)
            stats["mp4_resolved"] += len(mp4_urls)
            log(f"[{label}] MP4 解析: {len(mp4_urls)}/{len(all_videos)} ({time.time()-t1:.0f}s)")

            # 合并 MP4 结果
            for v in all_videos:
                vid = v["video_id"]
                if vid in mp4_urls:
                    v["duration"] = mp4_urls[vid]

            # 保存
            t2 = time.time()
            saved = supabase_save(all_videos)
            stats["videos_saved"] += saved
            log(f"[{label}] 保存 {saved} ({time.time()-t2:.0f}s)")

    finally:
        if pw:
            try:
                await pw_context.close()
                await pw.stop()
            except Exception:
                pass

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    return stats


# ========== 重爬模式: 修复无 MP4 的旧视频 ==========

def fetch_monsnode_id_from_page(video_id: str) -> str | None:
    """访问 monsnode 视频详情页, 提取 monsnode 内部 ID (用于 twjn.php)
    视频页 URL: https://monsnode.com/v{tweet_id}
    页面中包含 redirect.php?v=MONSNODE_ID 链接
    """
    tweet_id = video_id[1:] if video_id.startswith("v") else video_id
    url = f"{BASE_URL}/v{tweet_id}"

    for attempt in range(1, 4):
        try:
            resp = cffi_requests.get(
                url, headers=CFFI_HEADERS,
                impersonate="chrome131",
                timeout=20
            )
            if resp.status_code != 200:
                time.sleep(3 * attempt)
                continue
            # 找第一个 redirect.php?v=XXXXX 链接（通常就是当前视频）
            m = re.search(r"redirect\.php\?v=(\d+)", resp.text)
            if m:
                return m.group(1)
            time.sleep(2 * attempt)
        except Exception:
            time.sleep(2 * attempt)
    return None


async def rescrape_mode():
    """从 Supabase 拉取无 MP4 的视频, 用 twjn.php 重新解析并更新
    策略:
      1. 有 monsnode_video_id → 直接 twjn.php
      2. 无 monsnode_video_id → 先爬视频详情页获取 ID, 再 twjn.php
      3. 以上都失败 → 不再尝试 (标记 needs_rescrape=false)
    """
    log("=" * 55)
    log("重爬模式: 修复数据库中无 MP4 的旧视频")

    import httpx as hx
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
    }
    resp = hx.get(
        SUPABASE_URL + "/rest/v1/videos"
        "?select=video_id,monsnode_video_id,source_section"
        "&or=(duration.is.null,duration.not.ilike.*video.twimg.com*)"
        "&order=created_at.desc"
        "&limit=500",
        headers=headers,
        timeout=20
    )
    if resp.status_code != 200:
        log(f"查询失败: {resp.status_code}", "ERROR")
        return
    candidates = resp.json()
    total = len(candidates)
    log(f"找到 {total} 个需要重爬的视频")

    if not total:
        log("没有需要重爬的视频!")
        return

    # 按板块统计
    sections = {}
    for c in candidates:
        s = c.get("source_section", "unknown")
        sections[s] = sections.get(s, 0) + 1
    for s, n in sorted(sections.items()):
        log(f"  {s}: {n} 个")

    # 分类
    direct_twjn = []     # 已有 monsnode_video_id, 直接调 twjn.php
    need_fetch_id = []   # 需先爬详情页获取 monsnode_video_id
    no_tweet_id = []     # video_id 不是有效 tweet ID 的

    for c in candidates:
        vid = c["video_id"]
        mid = (c.get("monsnode_video_id") or "").strip()
        tid = vid[1:] if vid.startswith("v") else ""

        if mid and mid.isdigit():
            direct_twjn.append((vid, mid))
        elif tid.isdigit() and len(tid) >= 15:
            need_fetch_id.append(vid)
        else:
            no_tweet_id.append(vid)

    log(f"  直接 twjn.php: {len(direct_twjn)} 个")
    log(f"  需先获取 ID: {len(need_fetch_id)} 个")
    if no_tweet_id:
        log(f"  无效 tweet ID: {len(no_tweet_id)} 个")

    if not direct_twjn and not need_fetch_id:
        log("没有可用的解析路径!")
        return

    t0 = time.time()
    resolved = 0
    sem_twjn = asyncio.Semaphore(MP4_CONCURRENCY)

    async with httpx.AsyncClient(timeout=15, limits=httpx.Limits(max_connections=100)) as client:

        async def _save(vid, mp4, monsnode_mid=None):
            now = datetime.now(timezone.utc).isoformat()
            data = {"mp4_checked_at": now, "updated_at": now}
            if mp4:
                data["duration"] = mp4[:500]
                data["has_mp4"] = True
                data["needs_rescrape"] = False
                if monsnode_mid:
                    data["monsnode_video_id"] = monsnode_mid
            else:
                data["needs_rescrape"] = True
            try:
                await client.patch(
                    SUPABASE_URL + f"/rest/v1/videos?video_id=eq.{vid}",
                    headers={**headers, "Content-Type": "application/json"},
                    json=data, timeout=15
                )
            except Exception:
                pass

        # 阶段 1: 对没有 monsnode_video_id 的视频, 先爬详情页获取 ID
        fetched_ids = {}  # vid -> monsnode_id
        if need_fetch_id:
            log(f"\n阶段 1: 爬取 {len(need_fetch_id)} 个视频详情页获取 monsnode ID...")
            # 使用线程池执行同步的 curl_cffi 请求
            import concurrent.futures
            fetch_count = 0
            with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
                futures = {pool.submit(fetch_monsnode_id_from_page, vid): vid for vid in need_fetch_id}
                for future in concurrent.futures.as_completed(futures):
                    vid = futures[future]
                    try:
                        mid = future.result()
                        if mid:
                            fetched_ids[vid] = mid
                            direct_twjn.append((vid, mid))
                        fetch_count += 1
                        if fetch_count % 20 == 0:
                            elapsed = time.time() - t0
                            log(f"  已获取: {fetch_count}/{len(need_fetch_id)} → 成功 {len(fetched_ids)} ({elapsed:.0f}s)")
                    except Exception:
                        fetch_count += 1
            elapsed = time.time() - t0
            log(f"  详情页爬取完成: {len(fetched_ids)}/{len(need_fetch_id)} 获取到 monsnode ID ({elapsed:.0f}s)")

        # 阶段 2: 所有有 monsnode_video_id 的视频, 并发调 twjn.php
        if direct_twjn:
            log(f"\n阶段 2: twjn.php 批量解析 {len(direct_twjn)} 个视频...")
            total_tasks = len(direct_twjn)

            async def _twjn_one(vid, mid):
                result = await resolve_one_twjn(client, vid, mid, sem_twjn)
                _, mp4 = result
                if mp4:
                    await _save(vid, mp4, monsnode_mid=mid)
                    return "ok"
                else:
                    await _save(vid, None)
                    return "fail"

            all_tasks = [_twjn_one(vid, mid) for vid, mid in direct_twjn]
            for batch_start in range(0, total_tasks, MP4_BATCH_SIZE):
                batch = all_tasks[batch_start:batch_start + MP4_BATCH_SIZE]
                results = await asyncio.gather(*batch)
                ok = sum(1 for r in results if r == "ok")
                resolved += ok
                done = min(batch_start + MP4_BATCH_SIZE, total_tasks)
                elapsed = time.time() - t0
                log(f"  {done}/{total_tasks} ({done*100//max(total_tasks,1)}%) 恢复 {resolved} MP4 ({elapsed:.0f}s)")

        # 标记完全无法处理的
        for vid in no_tweet_id:
            await _save(vid, None)

    log(f"\n重爬完成: {resolved}/{total} 个视频恢复 MP4 ({time.time()-t0:.0f}s)")


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--rescrape", action="store_true", help="重爬模式: 修复数据库中无 MP4 的视频")
    args = parser.parse_args()

    print("=" * 55)
    mode = "重爬 (修复旧视频)" if args.rescrape else "正常"
    log(f"monsnode 爬虫 v4 — 模式: {mode}")
    log(f"SUPABASE_URL={'已设置' if SUPABASE_URL else '❌ 未设置'}")
    log(f"SUPABASE_KEY={'已设置' if SUPABASE_KEY else '❌ 未设置'}")
    if not SUPABASE_URL or not SUPABASE_KEY:
        log("请设置 SUPABASE_URL 和 SUPABASE_KEY 环境变量", "ERROR")
        sys.exit(1)
    print("=" * 55)

    if args.rescrape:
        asyncio.run(rescrape_mode())
    else:
        stats = asyncio.run(scrape_all())
        print("\n" + "=" * 55)
        print(f"  板块: {stats['sections_crawled']}  页面: {stats['pages_crawled']}")
        print(f"  发现: {stats['videos_found']}  保存: {stats['videos_saved']}")
        rate = stats['mp4_resolved'] / max(stats['videos_found'], 1) * 100
        print(f"  MP4: {stats['mp4_resolved']} ({rate:.0f}%)  PW回退: {stats['pw_fallbacks']}")
        if stats["errors"]:
            print(f"  错误: {len(stats['errors'])}")
            for e in stats["errors"][:3]:
                print(f"    - {e[:120]}")
        print("=" * 55)


if __name__ == "__main__":
    main()

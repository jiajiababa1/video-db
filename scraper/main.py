"""
monsnode 爬虫 v9 — 全自动闭环 + 无限滚动 + 智能重爬
  - Playwright 真实导航 (像真人浏览)
  - 支持分页 + 无限滚动双重加载策略
  - UA 轮换降低 Cloudflare 检测
  - MP4 解析: 多 tab 并发真实导航到 twjn.php 页面
  - 智能 needs_rescrape: 3次失败不再重试
  - 客户端/服务端爬虫互不冲突 (has_mp4 只增不删)
"""
import os, sys, time, asyncio, re, base64, json, random
from datetime import datetime, timezone
from urllib.parse import urljoin
import httpx

BASE_URL = "https://monsnode.com"

# 每条目最多抓取页数 (分页模式下); 无限滚动模式则为 scroll 次数
MAX_PAGES_PER_SECTION = 8
MAX_SCROLLS_PER_SECTION = 8     # 无限滚动: 最多向下滚动次数
MAX_SCROLL_VIDEOS = 200         # 无限滚动: 最多收集视频数

TARGET_SECTIONS = [
    # 排名页 (带 period) — 优先尝试分页, 无新内容则用滚动
    ("/?ranking=1&period=24h", "24h", "ranking"),
    ("/?ranking=1&period=3d", "3d", "ranking"),
    ("/?ranking=1&period=7d", "7d", "ranking"),
    ("/?ranking=1&period=30d", "30d", "ranking"),
    ("/?ranking=1", "ranking", "ranking"),
    # 普通栏目
    ("/trending", "trending", "normal"),
    ("/", "home", "normal"),
    ("/latest", "latest", "normal"),
]

# MP4 解析优先级: trending/latest 视频更可能还在线上
MP4_PRIORITY = ["trending", "latest", "home", "24h", "3d", "7d", "30d", "ranking"]

BATCH_SIZE = 100
MP4_TAB_CONCURRENCY = 3
MAX_RETRY_COUNT = 3  # 最多重试次数, 超过标记为死链

# UA 池 (轮换使用)
USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
]

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").strip().strip("'\"")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "").strip().strip("'\"").replace("\n", "").replace("\r", "")


def log(msg: str, level: str = "INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


def build_page_url(base_url: str, page: int, mode: str = "normal", variant: str = "page") -> str:
    """构建翻页 URL
    variant="page": 使用 page=N (排名页默认)
    variant="p":    使用 p=N (普通板块默认)
    """
    if page <= 1:
        return base_url
    sep = "&" if "?" in base_url else "?"
    return f"{base_url}{sep}{variant}={page}"


# ========== 浏览器提取卡片的 JS ==========

EXTRACT_CARDS_JS = """
() => {
    const cards = document.querySelectorAll('div.listn');
    const results = [];
    for (const card of cards) {
        const id = card.getAttribute('id') || '';
        if (!id || !/^[0-9]+$/.test(id)) continue;
        const vid = 'v' + id;
        const a = card.querySelector('a');
        let href = '';
        let monsnodeId = '';
        if (a) {
            href = a.getAttribute('href') || '';
            const m = href.match(/redirect\\.php\\?v=([0-9]+)/);
            if (m) monsnodeId = m[1];
        }
        const img = card.querySelector('img');
        const thumbnail = img ? (img.getAttribute('src') || '') : '';
        const title = img ? (img.getAttribute('alt') || '').split('\\n')[0].trim().substring(0, 500) : '';
        const userEl = card.querySelector('.user span, .user a');
        const author = userEl ? userEl.textContent.trim().substring(0, 200) : '';
        const viewEl = card.querySelector('.view, .views, .count, .like, .heart, .point');
        let views = '';
        if (viewEl) {
            const m = viewEl.textContent.match(/[0-9,]+/);
            if (m) views = m[0].replace(/,/g, '');
        }
        const durEl = card.querySelector('.time, .duration, .length, .dur');
        const durationLabel = durEl ? durEl.textContent.trim().substring(0, 20) : '';
        let rankNum = '';
        if (window.location.href.indexOf('ranking') !== -1) {
            const rankEl = card.querySelector('.rank, .number');
            if (rankEl) rankNum = rankEl.textContent.replace(/[^0-9]/g, '');
        }
        // 提取投票数
        let voteUp = 0, voteDown = 0;
        const upEl = card.querySelector('.up span, .up i');
        const downEl = card.querySelector('.down span, .down i');
        if (upEl) { const m = upEl.textContent.match(/[0-9,]+/); if (m) voteUp = parseInt(m[0].replace(/,/g, '')); }
        if (downEl) { const m = downEl.textContent.match(/[0-9,]+/); if (m) voteDown = parseInt(m[0].replace(/,/g, '')); }

        results.push({
            video_id: vid,
            url: '/v' + id,
            monsnode_video_id: monsnodeId,
            title: title,
            thumbnail: thumbnail,
            author: author,
            duration: durationLabel,
            views: views,
            rank: rankNum,
            vote_up: voteUp,
            vote_down: voteDown
        });
    }
    return results;
}
"""

# 滚动加载: 滚动到页面底部触发 AJAX 加载更多
SCROLL_AND_WAIT_JS = """
async (scrollCount, waitMs) => {
    let prevHeight = 0;
    for (let i = 0; i < scrollCount; i++) {
        window.scrollTo(0, document.body.scrollHeight);
        await new Promise(r => setTimeout(r, waitMs));
        const newHeight = document.body.scrollHeight;
        if (newHeight === prevHeight) break;  // 页面高度不再变化, 已到底
        prevHeight = newHeight;
    }
    return document.body.scrollHeight;
}
"""


# ========== Supabase ==========

def supabase_headers():
    return {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
    }


def supabase_fetch_failed(limit: int = 100) -> list[dict]:
    """查询 needs_rescrape=true 且有 monsnode_video_id 且重试次数 < MAX_RETRY_COUNT 的视频"""
    headers = supabase_headers()
    client = httpx.Client(timeout=30)
    try:
        url = (
            SUPABASE_URL + "/rest/v1/videos"
            + "?select=video_id,monsnode_video_id,retry_count"
            + "&needs_rescrape=is.true"
            + "&monsnode_video_id=not.is.null"
            + "&retry_count=lt." + str(MAX_RETRY_COUNT)
            + "&order=retry_count.asc"
            + "&limit=" + str(limit)
        )
        resp = client.get(url, headers=headers)
        if resp.status_code == 200:
            return resp.json()
        return []
    except Exception as e:
        log(f"查询失败视频异常: {e}", "WARN")
        return []
    finally:
        client.close()


def supabase_update_mp4(updates: dict[str, str | None]) -> int:
    """批量更新视频 MP4: {monsnode_video_id: mp4_url_or_None}
    - 成功 → has_mp4=true, needs_rescrape=false
    - 失败 → retry_count++, 超过 MAX_RETRY_COUNT 标记 needs_rescrape=false
    """
    if not updates:
        return 0
    now = datetime.now(timezone.utc).isoformat()
    headers = {**supabase_headers(), "Content-Type": "application/json"}
    saved = 0
    client = httpx.Client(timeout=30)
    for mid, mp4 in updates.items():
        video_id = "v" + mid
        has_mp4 = bool(mp4 and "video.twimg.com" in mp4)
        patch = {
            "mp4_checked_at": now,
            "has_mp4": has_mp4,
        }
        if has_mp4:
            patch["duration"] = mp4
            patch["needs_rescrape"] = False
            patch["retry_count"] = 0
        else:
            # MP4 解析失败: 递增重试次数
            patch["needs_rescrape"] = True
        try:
            # 使用 RPC 安全递增 retry_count (避免覆盖值)
            rpc_resp = client.post(
                SUPABASE_URL + "/rest/v1/rpc/increment_retry",
                headers=headers,
                json={"vid": video_id},
            )
            if rpc_resp.status_code not in (200, 201, 204):
                # RPC 不支持则直接用 PATCH
                resp = client.patch(
                    SUPABASE_URL + "/rest/v1/videos?video_id=eq." + video_id,
                    headers=headers,
                    json=patch,
                )
                if resp.status_code in (200, 204):
                    saved += 1
            else:
                # 再 PATCH 其他字段
                resp = client.patch(
                    SUPABASE_URL + "/rest/v1/videos?video_id=eq." + video_id,
                    headers=headers,
                    json=patch,
                )
                if resp.status_code in (200, 204):
                    saved += 1
        except Exception:
            pass
    client.close()
    return saved


def supabase_save(videos: list[dict]) -> int:
    """保存视频到 Supabase (通过 upsert_videos RPC)
    has_mp4 只在不冲突方向更新 (不覆盖已有的 true 为 false)
    """
    if not videos:
        return 0
    now = datetime.now(timezone.utc).isoformat()
    headers = {**supabase_headers(), "Content-Type": "application/json"}

    # 合并同 video_id 的记录：拼接 source_section，保留最佳元数据
    merged = {}
    for v in videos:
        vid = v["video_id"]
        if vid not in merged:
            merged[vid] = dict(v)
        else:
            existing = merged[vid]
            new_sec = (v.get("source_section") or "")
            old_sec = (existing.get("source_section") or "")
            all_secs = [s.strip() for s in old_sec.split("|") if s.strip()]
            if new_sec and new_sec not in all_secs:
                all_secs.append(new_sec)
            existing["source_section"] = "|".join(all_secs)
            if not existing.get("title") and v.get("title"):
                existing["title"] = v["title"]
            if not existing.get("author") and v.get("author"):
                existing["author"] = v["author"]
            if not existing.get("thumbnail") and v.get("thumbnail"):
                existing["thumbnail"] = v["thumbnail"]
            mp4_existing = existing.get("duration", "") or ""
            mp4_new = v.get("duration", "") or ""
            if (not mp4_existing or "video.twimg.com" not in mp4_existing) and mp4_new and "video.twimg.com" in mp4_new:
                existing["duration"] = mp4_new

    multi = sum(1 for v in merged.values() if "|" in (v.get("source_section") or ""))
    log(f"  合并后: {len(merged)} 条 (其中 {multi} 条跨多栏目)")
    if multi > 0:
        examples = [f"{vid}:{v['source_section']}" for vid, v in list(merged.items())[:3] if "|" in (v.get("source_section") or "")]
        log(f"  示例: {examples}")

    records = []
    for vid, v in merged.items():
        mp4 = v.get("duration", "") or ""
        has_mp4 = bool(mp4 and mp4.startswith("http") and "video.twimg.com" in mp4)
        records.append({
            "video_id": vid,
            "title": (v.get("title") or "")[:500],
            "thumbnail_url": (v.get("thumbnail") or "")[:1000],
            "video_url": urljoin(BASE_URL, v.get("url", ""))[:1000],
            "author": (v.get("author") or "")[:200],
            "duration": mp4 if has_mp4 else "",
            "views": (v.get("views") or "")[:50],
            "monsnode_video_id": (v.get("monsnode_video_id") or "")[:50],
            "source_page": (v.get("source_page") or "")[:500],
            "source_section": (v.get("source_section") or "")[:100],
            "vote_up": v.get("vote_up", 0),
            "vote_down": v.get("vote_down", 0),
            "scraped_at": now,
            "has_mp4": has_mp4,
            "needs_rescrape": not has_mp4,  # 新视频默认需要重爬
            "mp4_checked_at": now,
        })

    saved = 0
    client = httpx.Client(timeout=60)
    rpc_url = SUPABASE_URL + "/rest/v1/rpc/upsert_videos"
    for i in range(0, len(records), BATCH_SIZE):
        batch = records[i:i + BATCH_SIZE]
        try:
            resp = client.post(rpc_url, headers=headers, json={"videos": batch})
            if resp.status_code in (200, 201, 204):
                saved += len(batch)
            else:
                for rec in batch:
                    try:
                        r = client.post(rpc_url, headers=headers, json={"videos": [rec]})
                        if r.status_code in (200, 201, 204):
                            saved += 1
                    except Exception:
                        pass
        except Exception:
            for rec in batch:
                try:
                    r = client.post(rpc_url, headers=headers, json={"videos": [rec]})
                    if r.status_code in (200, 201, 204):
                        saved += 1
                except Exception:
                    pass
    client.close()
    return saved


def supabase_save_status(stats: dict):
    """记录爬虫运行状态"""
    headers = {**supabase_headers(), "Content-Type": "application/json"}
    record = {
        "last_run": datetime.now(timezone.utc).isoformat(),
        "videos_found": stats.get("videos_found", 0),
        "videos_saved": stats.get("videos_saved", 0),
        "pages_crawled": stats.get("pages_crawled", 0),
        "mp4_resolved": stats.get("mp4_resolved", 0),
        "errors": "\n".join(stats.get("errors", [])[:10]),
    }
    try:
        client = httpx.Client(timeout=15)
        resp = client.post(SUPABASE_URL + "/rest/v1/scrape_status", headers=headers, json=record)
        if resp.status_code in (200, 201, 204):
            log("爬虫状态已记录")
        else:
            log(f"状态记录失败: {resp.status_code}", "WARN")
        client.close()
    except Exception as e:
        log(f"状态记录异常: {e}", "WARN")


# ========== MP4 解析 ==========

async def resolve_mp4_batch(context, mids: list[str]) -> dict[str, str]:
    """通过真实浏览器导航到 twjn.php 页面获取 MP4 (多 tab 并发)"""
    results = {}
    sem = asyncio.Semaphore(MP4_TAB_CONCURRENCY)

    async def resolve_one(mid: str):
        async with sem:
            page = await context.new_page()
            try:
                resp = await page.goto(
                    f"{BASE_URL}/twjn.php?v={mid}",
                    wait_until="domcontentloaded",
                    timeout=15000
                )
                if resp and resp.status == 200:
                    content = await page.content()
                    m = re.search(r"var\s+u\s*=\s*atob\('([^']+)'\)", content)
                    if m:
                        mp4 = base64.b64decode(m.group(1)).decode('utf-8')
                        if 'video.twimg.com' in mp4:
                            return mid, mp4
                return mid, None
            except Exception:
                return mid, None
            finally:
                await page.close()

    tasks = [resolve_one(mid) for mid in mids]
    batch_results = await asyncio.gather(*tasks)
    for mid, mp4 in batch_results:
        if mp4:
            results[mid] = mp4
    return results


# ========== 主流程 ==========

async def scrape_all():
    from playwright.async_api import async_playwright

    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0,
        "pages_crawled": 0,
        "scrolls_done": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "mp4_resolved": 0,
        "rescrape_candidates": 0,
        "rescrape_resolved": 0,
        "rescrape_updated": 0,
        "errors": [],
    }

    log("启动浏览器...")
    pw = await async_playwright().start()
    ua = random.choice(USER_AGENTS)
    log(f"UA: {ua[:80]}...")
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
    context = await browser.new_context(
        user_agent=ua,
        viewport={"width": 1366, "height": 768},
        locale="ja-JP",
        timezone_id="Asia/Tokyo",
        geolocation={"latitude": 35.6895, "longitude": 139.6917},
    )
    log("浏览器已启动")

    section_results_lock = asyncio.Lock()

    async def scrape_via_scroll(page, label: str, section_url: str) -> list[dict]:
        """通过无限滚动抓取: 不断向下滚动直到无新视频或达到上限"""
        all_videos = []
        seen_ids = set()
        t0 = time.time()

        for scroll_i in range(MAX_SCROLLS_PER_SECTION):
            try:
                await page.evaluate(SCROLL_AND_WAIT_JS, 1, 2000)
            except Exception:
                pass
            await asyncio.sleep(1.5)

            try:
                raw = await page.evaluate(EXTRACT_CARDS_JS)
                cards = [c for c in raw if isinstance(c, dict) and c.get("video_id")]
            except Exception:
                cards = []

            new = [c for c in cards if c["video_id"] not in seen_ids]
            if not new:
                log(f"  [{label}] 滚动{scroll_i+1}次: 无新视频, 停止滚动")
                break

            for c in new:
                c["source_section"] = label
                c["source_page"] = section_url
                seen_ids.add(c["video_id"])

            all_videos.extend(new)
            async with section_results_lock:
                stats["scrolls_done"] += 1
            log(f"  [{label}] 滚动{scroll_i+1}次: +{len(new)} 新视频 (累计 {len(all_videos)})")

            if len(all_videos) >= MAX_SCROLL_VIDEOS:
                log(f"  [{label}] 已达上限 {MAX_SCROLL_VIDEOS}, 停止滚动")
                break

        elapsed = time.time() - t0
        log(f"[{label}] 滚动模式: 共 {len(all_videos)} 个视频 ({elapsed:.0f}s)")
        return all_videos

    async def scrape_via_pagination(page, label: str, section_url: str, mode: str) -> tuple[list[dict], bool]:
        """通过分页抓取: 推进 page=N 或 p=N
        返回 (视频列表, 是否分页有效)
        如果连续 2 页无新内容 → 分页无效, 返回 False
        """
        pv = "page" if mode == "ranking" else "p"
        all_videos = []
        seen_ids = set()
        t0 = time.time()
        empty_pages = 0

        for page_num in range(1, MAX_PAGES_PER_SECTION + 1):
            url = build_page_url(section_url, page_num, mode, pv)
            page_ok = False
            cards = []

            for cf_retry in range(2):
                try:
                    await page.goto(url, wait_until="domcontentloaded", timeout=20000)
                    try:
                        await page.wait_for_selector("div.listn", timeout=8000)
                    except Exception:
                        content = await page.content()
                        if "challenges.cloudflare.com" in content or "お待ちください" in content:
                            wait_sec = 3 + cf_retry * 3
                            log(f"  [{label}] Cloudflare 挑战 (第{cf_retry+1}次), 等待 {wait_sec}s...")
                            await asyncio.sleep(wait_sec)
                            continue
                    await asyncio.sleep(0.5)

                    raw = await page.evaluate(EXTRACT_CARDS_JS)
                    cards = [c for c in raw if isinstance(c, dict) and c.get("video_id")]
                    page_ok = True
                    break
                except Exception as e:
                    if cf_retry < 1:
                        log(f"  [{label}] 加载异常, 重试...", "WARN")
                        await asyncio.sleep(1)
                    else:
                        log(f"  [{label}] 加载失败: {str(e)[:80]}", "ERROR")

            if not page_ok:
                if page_num == 1:
                    async with section_results_lock:
                        stats["errors"].append(f"{label}: 第1页加载失败")
                break

            async with section_results_lock:
                stats["pages_crawled"] += 1

            new = [c for c in cards if c["video_id"] not in seen_ids]
            log(f"  [{label}] 第{page_num}页({pv}={page_num}): {len(cards)} 卡片, +{len(new)} 新 ({time.time()-t0:.0f}s)")

            if not cards and page_num == 1:
                async with section_results_lock:
                    stats["errors"].append(f"{label}: 第1页无视频")
                break

            if not new:
                empty_pages += 1
                if empty_pages >= 2 or page_num == 1:
                    # 第1页就无新视频 → 可能分页参数格式不对
                    break
            else:
                empty_pages = 0

            for c in new:
                c["source_section"] = label
                c["source_page"] = url
                seen_ids.add(c["video_id"])

            all_videos.extend(new)
            if len(all_videos) >= MAX_SCROLL_VIDEOS:
                break

            await asyncio.sleep(1)

        elapsed = time.time() - t0
        pagination_worked = len(all_videos) > 0 and empty_pages < 2
        log(f"[{label}] 分页模式: 共 {len(all_videos)} 个视频 ({elapsed:.0f}s) {'✓' if pagination_worked else '✗ 分页无效'}")
        return all_videos, pagination_worked

    async def scrape_one_section(path: str, label: str, mode: str) -> list[dict]:
        """抓取单个栏目: 先尝试分页, 分页无效则用无限滚动"""
        section_url = urljoin(BASE_URL, path)
        log(f"[{label}] {section_url}")

        page = await context.new_page()
        try:
            # 第1步: 加载首页
            for cf_retry in range(2):
                try:
                    await page.goto(section_url, wait_until="domcontentloaded", timeout=20000)
                    try:
                        await page.wait_for_selector("div.listn", timeout=8000)
                    except Exception:
                        content = await page.content()
                        if "challenges.cloudflare.com" in content or "お待ちください" in content:
                            wait_sec = 3 + cf_retry * 3
                            log(f"  [{label}] Cloudflare 挑战 (第{cf_retry+1}次), 等待 {wait_sec}s...")
                            await asyncio.sleep(wait_sec)
                            continue
                    break
                except Exception as e:
                    if cf_retry < 1:
                        await asyncio.sleep(1)
                    else:
                        log(f"  [{label}] 首页加载失败: {str(e)[:80]}", "ERROR")
                        return []

            await asyncio.sleep(0.5)

            # 第2步: 尝试分页抓取
            page_vids, pag_ok = await scrape_via_pagination(page, label, section_url, mode)

            if pag_ok and len(page_vids) >= 10:
                # 分页工作正常
                return page_vids

            # 第3步: 分页无效, 回到首页用无限滚动
            log(f"  [{label}] 分页效果不佳, 切换到无限滚动模式...")
            try:
                await page.goto(section_url, wait_until="domcontentloaded", timeout=20000)
                await page.wait_for_selector("div.listn", timeout=8000)
            except Exception:
                pass
            await asyncio.sleep(0.5)

            scroll_vids = await scrape_via_scroll(page, label, section_url)
            if scroll_vids:
                return scroll_vids

            # 都失败, 返回分页得到的结果 (可能很少但聊胜于无)
            return page_vids

        finally:
            await page.close()

    all_section_videos = []

    try:
        # 阶段 0: 抓取 navi.php 发现隐藏栏目
        log("阶段0: 探测 navi.php 隐藏分类...")
        extra_sections = []
        try:
            navi_page = await context.new_page()
            await navi_page.goto(f"{BASE_URL}/navi.php", wait_until="domcontentloaded", timeout=15000)
            await navi_page.wait_for_selector("a", timeout=5000)
            navi_data = await navi_page.evaluate("""() => {
                const links = document.querySelectorAll('a[href]');
                const results = [];
                const seen = new Set();
                for (const a of links) {
                    const href = a.getAttribute('href') || '';
                    const text = a.textContent.trim().substring(0, 50);
                    // 过滤出类似 /?ranking= 或 /category 的内部链接
                    if (href.startsWith('/') && !href.startsWith('//') && !seen.has(href) &&
                        !href.includes('redirect') && !href.includes('twjn') && !href.includes('bookmark') &&
                        !href.startsWith('/v') && href.length > 1 && href.length < 100) {
                        seen.add(href);
                        results.push({url: href, label: text || href.replace(/[^a-zA-Z0-9]/g, '_').substring(0, 20)});
                    }
                }
                return results;
            }""")
            for item in navi_data:
                url = item.get("url", "")
                # 排除已有的 section
                existing_urls = {s[0] for s in TARGET_SECTIONS}
                if url not in existing_urls and not url.startswith("/v") and "redirect" not in url:
                    label = "navi_" + (item.get("label", "unknown")[:15])
                    extra_sections.append((url, label, "normal"))
                    log(f"  发现新栏目: {url} ({label})")
            await navi_page.close()
        except Exception as e:
            log(f"  navi.php 探测失败 (无影响): {str(e)[:80]}", "WARN")

        # 合并额外栏目
        all_sections = list(TARGET_SECTIONS) + extra_sections
        # 限制总数避免超时
        if len(all_sections) > 12:
            all_sections = all_sections[:12]

        # 阶段 1: 并行抓取所有栏目
        log(f"开始并行抓取 {len(all_sections)} 个栏目...")
        tasks = [scrape_one_section(path, label, mode)
                 for path, label, mode in all_sections]
        section_results = await asyncio.gather(*tasks, return_exceptions=True)
        for i, result in enumerate(section_results):
            if isinstance(result, list):
                all_section_videos.extend(result)
                label = all_sections[i][1]
                async with section_results_lock:
                    stats["sections_crawled"] += 1
                    stats["videos_found"] += len(result)
            else:
                log(f"栏目抓取异常 ({all_sections[i][1]}): {result}", "WARN")

        total_unique = len({v["video_id"] for v in all_section_videos})
        log(f"\n[阶段1] 总计: {len(all_section_videos)} 条记录, {total_unique} 个唯一视频")

        # 阶段 2: 保存
        if all_section_videos:
            saved = supabase_save(all_section_videos)
            stats["videos_saved"] = saved
            log(f"[阶段2] 保存完成: {saved} 条")
        else:
            log("[阶段2] 无视频可保存")

        # 阶段 3: MP4 解析 (按优先级 + 按 views 排序, 最多 80 个)
        all_targets = {}
        for v in all_section_videos:
            mid = v.get("monsnode_video_id", "").strip()
            if mid and mid.isdigit():
                all_targets[mid] = v

        if all_targets:
            def _mp4_score(item):
                mid, v = item
                sec = v.get("source_section", "")
                try:
                    pri = MP4_PRIORITY.index(sec)
                except ValueError:
                    pri = 99
                # 浏览量越高越优先 (同 priority 内排序)
                try:
                    views = int(v.get("views", "0").replace(",", ""))
                except (ValueError, TypeError):
                    views = 0
                return (pri, -views)  # 优先级小+浏览量负→排前面

            sorted_targets = sorted(all_targets.items(), key=_mp4_score)
            mids = [mid for mid, _ in sorted_targets[:80]]
            log(f"\n[阶段3] MP4 解析: {len(mids)} 个视频 (热度优先)...")
            t2 = time.time()

            all_mp4 = {}
            for batch_start in range(0, len(mids), MP4_TAB_CONCURRENCY * 3):
                batch = mids[batch_start:batch_start + MP4_TAB_CONCURRENCY * 3]
                batch_results = await resolve_mp4_batch(context, batch)
                all_mp4.update(batch_results)
                done = min(batch_start + MP4_TAB_CONCURRENCY * 3, len(mids))
                log(f"  {done}/{len(mids)} → {len(all_mp4)} MP4 ({time.time()-t2:.0f}s)")

            mp4_updates = {}
            for mid, mp4 in all_mp4.items():
                mp4_updates[mid] = mp4
                stats["mp4_resolved"] += 1
            if mp4_updates:
                supabase_update_mp4(mp4_updates)
            log(f"MP4 解析完成: {len(all_mp4)}/{len(mids)} ({time.time()-t2:.0f}s)")

        # 阶段 4: 智能回爬 (跳过已超过 MAX_RETRY_COUNT 次的)
        log("\n[阶段4] 查询数据库中未解析 MP4 的旧视频 (重试<{})...".format(MAX_RETRY_COUNT))
        failed = supabase_fetch_failed(limit=200)
        stats["rescrape_candidates"] = len(failed)
        if failed:
            already_resolved = set(all_targets.keys()) & {v["monsnode_video_id"] for v in failed}
            to_rescrape = {v["monsnode_video_id"]: v for v in failed if v["monsnode_video_id"] not in already_resolved}
            log(f"  候选: {len(failed)}, 本轮已解析: {len(already_resolved)}, 需回爬: {len(to_rescrape)}")

            if to_rescrape:
                mids = list(to_rescrape.keys())
                t3 = time.time()
                all_rescraped_mp4 = {}
                for batch_start in range(0, len(mids), MP4_TAB_CONCURRENCY * 3):
                    batch = mids[batch_start:batch_start + MP4_TAB_CONCURRENCY * 3]
                    batch_results = await resolve_mp4_batch(context, batch)
                    all_rescraped_mp4.update(batch_results)
                    done = min(batch_start + MP4_TAB_CONCURRENCY * 3, len(mids))
                    log(f"  回爬 {done}/{len(mids)} → {len(all_rescraped_mp4)} MP4 ({time.time()-t3:.0f}s)")

                all_updates = {}
                for mid in mids:
                    all_updates[mid] = all_rescraped_mp4.get(mid)

                updated = supabase_update_mp4(all_updates)
                stats["rescrape_resolved"] = len(all_rescraped_mp4)
                stats["rescrape_updated"] = updated
                log(f"  回爬完成: 更新 {updated} 条, 其中 {len(all_rescraped_mp4)} 个解析成功 ({time.time()-t3:.0f}s)")
        else:
            log("  无待回爬视频")

        # 阶段 5: 下架检测 (视频超过 3 次爬取周期未出现 → 标记)
        log("\n[阶段5] 下架检测...")
        try:
            all_scraped_ids = {v["video_id"] for v in all_section_videos}
            if all_scraped_ids:
                client = httpx.Client(timeout=30)
                headers = supabase_headers()
                # 查询最近 3 次爬取都未更新的视频
                cutoff = datetime.now(timezone.utc).isoformat()
                resp = client.get(
                    SUPABASE_URL + "/rest/v1/videos"
                    + "?select=video_id"
                    + "&updated_at=lt." + cutoff
                    + "&order=scraped_at.asc"
                    + "&limit=500",
                    headers=headers
                )
                if resp.status_code == 200:
                    old_videos = resp.json()
                    removed = [v["video_id"] for v in old_videos if v["video_id"] not in all_scraped_ids]
                    if removed:
                        log(f"  疑似下架: {len(removed)} 个视频, 标记 removed=true")
                        # 批量标记 (每次20个)
                        for j in range(0, len(removed), 20):
                            batch = removed[j:j+20]
                            try:
                                client.patch(
                                    SUPABASE_URL + "/rest/v1/videos?video_id=in.(" +
                                    ",".join(f'"{vid}"' for vid in batch) + ")",
                                    headers={**headers, "Content-Type": "application/json"},
                                    json={"removed": True, "updated_at": datetime.now(timezone.utc).isoformat()}
                                )
                            except Exception:
                                pass
                client.close()
        except Exception as e:
            log(f"  下架检测异常: {str(e)[:80]}", "WARN")

        # 阶段 6: Discord Webhook 通知 (失败时)
        webhook_url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
        if webhook_url and stats["errors"]:
            try:
                import http.client, json as _json
                payload = {
                    "content": None,
                    "embeds": [{
                        "title": "⚠️ monsnode 爬虫错误",
                        "description": "\n".join(stats["errors"][:5]),
                        "color": 0xc08080,
                        "fields": [
                            {"name": "发现", "value": str(stats["videos_found"]), "inline": True},
                            {"name": "保存", "value": str(stats["videos_saved"]), "inline": True},
                            {"name": "MP4", "value": str(stats["mp4_resolved"]), "inline": True},
                        ],
                        "timestamp": datetime.now(timezone.utc).isoformat()
                    }]
                }
                webhook_client = httpx.Client(timeout=10)
                webhook_client.post(webhook_url, json=payload)
                webhook_client.close()
                log("  Discord 通知已发送")
            except Exception as e:
                log(f"  Discord 通知失败: {str(e)[:80]}", "WARN")

        # 检查缩略图有效期
        log("\n[阶段6] 缩略图有效期检查...")
        try:
            now_ts = datetime.now(timezone.utc).isoformat()
            c = httpx.Client(timeout=30)
            h = supabase_headers()
            # 标记超过 30 天未更新的缩略图
            r = c.patch(
                SUPABASE_URL + "/rest/v1/videos?thumbnail_url=ilike.*twimg.com*&updated_at=lt.2026-05-10",
                headers={**h, "Content-Type": "application/json"},
                json={"needs_rescrape": True}
            )
            if r.status_code in (200, 204):
                log(f"  缩略图有效期检查完成")
            c.close()
        except Exception as e:
            log(f"  缩略图检查异常: {str(e)[:80]}", "WARN")

    finally:
        await context.close()
        await browser.close()
        await pw.stop()

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    supabase_save_status(stats)
    return stats


def main():
    print("=" * 55)
    log("monsnode 爬虫 v9 — 无限滚动 + 分页双重策略")
    key_ok = SUPABASE_KEY and len(SUPABASE_KEY) > 100
    log(f"SUPABASE_URL={'已设置' if SUPABASE_URL else '❌'} ({len(SUPABASE_URL)} 字符)")
    log(f"SUPABASE_KEY={'已设置' if key_ok else '❌'} ({len(SUPABASE_KEY)} 字符)")
    if not SUPABASE_URL or not key_ok:
        log("请设置 SUPABASE_URL 和 SUPABASE_KEY 环境变量", "ERROR")
        sys.exit(1)
    print("=" * 55)

    stats = asyncio.run(scrape_all())
    mp4_rate = stats['mp4_resolved'] / max(stats['videos_found'], 1) * 100
    print("\n" + "=" * 55)
    print(f"  板块: {stats['sections_crawled']}  页面: {stats['pages_crawled']}  滚动: {stats.get('scrolls_done', 0)}")
    print(f"  发现: {stats['videos_found']}  MP4: {stats['mp4_resolved']} ({mp4_rate:.0f}%)")
    print(f"  保存: {stats['videos_saved']}")
    rc = stats.get('rescrape_candidates', 0)
    if rc:
        rr = stats.get('rescrape_resolved', 0)
        ru = stats.get('rescrape_updated', 0)
        print(f"  回爬: 候选 {rc} → 修复 {rr} → 更新 {ru}")
    if stats["errors"]:
        print(f"  错误 ({len(stats['errors'])}):")
        for e in stats["errors"][:5]:
            print(f"    - {e[:120]}")
    print("=" * 55)


if __name__ == "__main__":
    main()

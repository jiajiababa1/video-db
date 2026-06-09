"""
monsnode 爬虫 v3: 抓取 → twjn.php 获取 MP4 → 存入 Supabase
新增: 可播放性检测 + 重爬标记 + 数据质量统计
"""
import os, re, sys, time, asyncio, base64
from datetime import datetime, timezone
from urllib.parse import urljoin

from bs4 import BeautifulSoup

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

MAX_RETRIES = 2
MAX_VIDEOS_PER_SECTION = 300
BATCH_SIZE = 50
TWJN_CONCURRENCY = 8

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")


def log(msg: str, level: str = "INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


def build_page_url(base_url: str, page: int) -> str:
    sep = "&" if "?" in base_url else "?"
    return f"{base_url}{sep}p={page}"


# ========== 页面抓取 (Playwright) ==========

async def _stealth_inject(page):
    """用 playwright-stealth 全面隐藏 headless 特征"""
    try:
        from playwright_stealth import stealth_async
        await stealth_async(page)
    except ImportError:
        await page.add_init_script("""
            Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
            Object.defineProperty(navigator, 'plugins', {get: () => [1,2,3,4,5]});
            Object.defineProperty(navigator, 'languages', {get: () => ['ja-JP','ja','en-US','en']});
            window.chrome = {runtime: {}};
            const originalQuery = window.navigator.permissions.query;
            window.navigator.permissions.query = (parameters) => (
                parameters.name === 'notifications' ?
                Promise.resolve({state: Notification.permission}) :
                originalQuery(parameters)
            );
        """)


async def fetch_page(context, url: str, retries: int = MAX_RETRIES, is_problem_page: bool = False) -> str | None:
    """用 Playwright 抓取单页, 等待 Cloudflare JS 验证完成
    is_problem_page: trending/latest 等被 Cloudflare 重点保护的页面, 需要更长等待
    """
    wait_time = 45000 if is_problem_page else 30000
    extra_sleep = 5 if is_problem_page else 2

    for attempt in range(1, retries + 1):
        page = None
        try:
            page = await context.new_page()
            await _stealth_inject(page)
            await page.set_extra_http_headers({
                "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                "DNT": "1",
                "Upgrade-Insecure-Requests": "1",
                "Sec-Fetch-Dest": "document",
                "Sec-Fetch-Mode": "navigate",
                "Sec-Fetch-Site": "none",
                "Sec-Fetch-User": "?1",
                "Cache-Control": "no-cache",
            })
            await page.goto(url, wait_until="domcontentloaded", timeout=wait_time)

            # 等待 Cloudflare 验证完成
            try:
                await page.wait_for_selector("div.listn", timeout=wait_time)
                await asyncio.sleep(extra_sleep)
                return await page.content()
            except Exception:
                try:
                    await page.wait_for_load_state("networkidle", timeout=20000)
                except Exception:
                    pass
                await asyncio.sleep(extra_sleep)

            html = await page.content()
            if "listn" in html:
                return html

            # Cloudflare 挑战页 - 给问题页面更长时间
            if 'challenges.cloudflare.com' in html or 'お待ちください' in html:
                wait_sec = 25 if is_problem_page else 15
                log(f"检测到 Cloudflare 挑战页, 等待 {wait_sec} 秒...", "DEBUG")
                await asyncio.sleep(wait_sec)
                html = await page.content()
                if "listn" in html:
                    return html

            # 调试: 失败时保存截图
            if attempt == retries:
                try:
                    title = await page.title()
                    body_preview = (html or "")[:600]
                    log(f"页面标题: {title}", "DEBUG")
                    log(f"HTML 前 600 字符: {body_preview}", "DEBUG")
                    await page.screenshot(path="/tmp/monsnode_debug.png", full_page=False)
                    log("已保存截图: /tmp/monsnode_debug.png", "DEBUG")
                except Exception:
                    pass
            log(f"页面无视频内容 (attempt {attempt})", "WARN")
        except Exception as e:
            log(f"网络错误 (attempt {attempt}): {str(e)[:80]}", "WARN")
        finally:
            if page:
                await page.close()
        if attempt < retries:
            await asyncio.sleep(5 * attempt)
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

        # 作者
        author = ""
        user_div = card.find("div", class_="user")
        if user_div:
            user_link = user_div.find("a")
            if user_link:
                user_span = user_link.find("span")
                if user_span:
                    author = user_span.get_text(strip=True)

        # 播放量
        views = ""
        for cls in ("view", "views", "count", "like", "heart", "point"):
            v_el = card.find(class_=cls)
            if v_el:
                nums = re.findall(r'[\d,]+', v_el.get_text(strip=True))
                if nums:
                    views = nums[0].replace(",", "")
                break

        # 时长标签
        duration_label = ""
        for cls in ("time", "duration", "length", "dur"):
            d_el = card.find(class_=cls)
            if d_el:
                duration_label = d_el.get_text(strip=True)[:20]
                break

        # 排名
        rank_num = ""
        if "ranking" in section:
            rank_el = card.find(class_="rank") or card.find(class_="number")
            if rank_el:
                rank_num = re.sub(r'\D', '', rank_el.get_text(strip=True))

        videos.append({
            "video_id": vid,
            "url": urljoin(BASE_URL, "/" + vid),
            "monsnode_video_id": monsnode_video_id,
            "redirect_url": urljoin(BASE_URL, f"redirect.php?v={monsnode_video_id}") if monsnode_video_id else "",
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


# ========== twjn.php → MP4 直链 ==========

async def resolve_via_twjn(context, videos: list[dict]) -> dict[str, str]:
    """通过 twjn.php 直接获取 MP4 直链"""
    mp4_urls = {}
    sem = asyncio.Semaphore(TWJN_CONCURRENCY)

    async def _get_one(v: dict):
        vid = v["video_id"]
        monsnode_id = v.get("monsnode_video_id", "")
        if not monsnode_id:
            return vid, None

        async with sem:
            for attempt in range(1, 3):
                page = None
                try:
                    page = await context.new_page()
                    from playwright_stealth import stealth_async
                    await stealth_async(page)
                    await page.goto(
                        f"https://monsnode.com/twjn.php?v={monsnode_id}",
                        wait_until="domcontentloaded", timeout=20000
                    )
                    await page.wait_for_timeout(3000)
                    html = await page.content()

                    if 'challenges.cloudflare.com' in html or 'お待ちください' in html:
                        await page.wait_for_timeout(5000)
                        html = await page.content()

                    # 提取 base64: var u = atob('xxx')
                    m = re.search(r"var\s+u\s*=\s*atob\('([^']+)'\)", html)
                    if m:
                        mp4_url = base64.b64decode(m.group(1)).decode('utf-8')
                        if 'video.twimg.com' in mp4_url:
                            return vid, mp4_url
                    # 降级匹配
                    m2 = re.search(r"atob\('([^']+\.mp4[^']*)'\)", html)
                    if m2:
                        mp4_url = m2.group(1)
                        if 'video.twimg.com' in mp4_url:
                            return vid, mp4_url

                    if attempt < 2:
                        await asyncio.sleep(5)

                except Exception:
                    pass
                finally:
                    if page:
                        try:
                            await page.close()
                        except Exception:
                            pass
            return vid, None

    to_resolve = [v for v in videos if v.get("monsnode_video_id")]
    if not to_resolve:
        log("  没有 monsnode_video_id, 跳过 twjn.php 解析")
        return {}

    total = len(to_resolve)
    results = {}

    for i in range(0, total, BATCH_SIZE):
        batch = to_resolve[i:i + BATCH_SIZE]
        tasks = [_get_one(v) for v in batch]
        batch_results = await asyncio.gather(*tasks)
        for vid, mp4_url in batch_results:
            if mp4_url:
                results[vid] = mp4_url
        log(f"  twjn.php 解析: {min(i+BATCH_SIZE, total)}/{total} → 已获取 {len(results)} 个 MP4")

    return results


# ========== Supabase 操作 ==========

def supabase_save(videos: list[dict]) -> int:
    """批量 upsert 到 Supabase, 自动兼容旧表结构 (无 has_mp4 等新列)"""
    if not videos:
        return 0
    import httpx as hx
    now = datetime.now(timezone.utc).isoformat()
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates",
    }

    # 构建记录: 先包含新字段, 如果数据库不支持会自动回退
    records = []
    for v in videos:
        mp4 = v.get("duration", "") or ""
        has_mp4 = bool(mp4 and mp4.startswith("http") and "video.twimg.com" in mp4)

        rec = {
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
            "updated_at": now,
        }
        # 尝试包含新字段 (数据库可能没有这些列, 失败时会自动剥离)
        rec["has_mp4"] = has_mp4
        rec["needs_rescrape"] = not has_mp4
        rec["mp4_checked_at"] = now
        records.append(rec)

    saved = 0
    client = hx.Client(timeout=30)
    _new_cols_ok = True  # 数据库是否有新列

    def _strip_new_cols(rec):
        """移除新列 (兼容旧表)"""
        for k in ("has_mp4", "needs_rescrape", "mp4_checked_at", "playable"):
            rec.pop(k, None)
        return rec

    try:
        for i in range(0, len(records), BATCH_SIZE):
            batch = records[i:i + BATCH_SIZE]
            try:
                resp = client.post(
                    SUPABASE_URL + "/rest/v1/videos",
                    headers=headers,
                    json=batch
                )
                if resp.status_code in (200, 201, 409):
                    saved += len(batch)
                elif resp.status_code == 400 and _new_cols_ok:
                    # 可能是新列不存在, 剥离后重试
                    err_text = resp.text.lower()
                    if "column" in err_text and ("has_mp4" in err_text or "needs_rescrape" in err_text):
                        log("检测到数据库无新列, 自动兼容旧表结构...", "WARN")
                        _new_cols_ok = False
                        batch = [_strip_new_cols(r) for r in batch]
                        resp2 = client.post(
                            SUPABASE_URL + "/rest/v1/videos",
                            headers=headers,
                            json=batch
                        )
                        if resp2.status_code in (200, 201, 409):
                            saved += len(batch)
                        else:
                            log(f"Supabase {resp2.status_code}: {resp2.text[:100]}", "WARN")
                    else:
                        log(f"Supabase {resp.status_code}: {resp.text[:100]}", "WARN")
                else:
                    log(f"Supabase {resp.status_code}: {resp.text[:100]}", "WARN")
                    # 如果已知无新列, 先剥离再逐条重试
                    if not _new_cols_ok:
                        for rec in batch:
                            _strip_new_cols(rec)
                            try:
                                resp2 = client.post(
                                    SUPABASE_URL + "/rest/v1/videos",
                                    headers=headers,
                                    json=[rec]
                                )
                                if resp2.status_code in (200, 201, 409):
                                    saved += 1
                            except Exception:
                                pass
            except Exception as e:
                log(f"Supabase 批量异常: {e}", "WARN")
    finally:
        client.close()
    return saved


def fetch_rescrape_candidates(limit: int = 100) -> list[dict]:
    """获取需要重爬的视频列表 (无 MP4 的视频)
    兼容旧表: needs_rescrape 列不存在时, 用 duration 判断
    """
    import httpx as hx
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
    }
    try:
        # 先尝试用 needs_rescrape 列查询
        resp = hx.get(
            SUPABASE_URL + "/rest/v1/videos"
            "?select=video_id,monsnode_video_id,source_section"
            "&needs_rescrape=eq.true"
            "&monsnode_video_id=not.is.null"
            "&order=created_at.desc"
            f"&limit={limit}",
            headers=headers,
            timeout=20
        )
        if resp.status_code == 200:
            return resp.json()
        # 列不存在, 用 duration 判断: 空 or 不含 video.twimg.com
        resp2 = hx.get(
            SUPABASE_URL + "/rest/v1/videos"
            "?select=video_id,monsnode_video_id,source_section"
            "&or=(duration.is.null,duration.not.ilike.*video.twimg.com*)"
            "&monsnode_video_id=not.is.null"
            "&order=created_at.desc"
            f"&limit={limit}",
            headers=headers,
            timeout=20
        )
        if resp2.status_code == 200:
            return resp2.json()
    except Exception as e:
        log(f"获取重爬候选失败: {e}", "WARN")
    return []


def update_mp4_status(video_id: str, mp4_url: str | None):
    """更新单个视频的 MP4 状态 (兼容旧表)"""
    import httpx as hx
    now = datetime.now(timezone.utc).isoformat()
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
    }
    # 先尝试包含新字段
    data = {
        "mp4_checked_at": now,
        "updated_at": now,
    }
    if mp4_url:
        data["duration"] = mp4_url[:500]
        data["has_mp4"] = True
        data["needs_rescrape"] = False
    else:
        data["needs_rescrape"] = True

    try:
        resp = hx.patch(
            SUPABASE_URL + f"/rest/v1/videos?video_id=eq.{video_id}",
            headers=headers,
            json=data,
            timeout=15
        )
        # 如果新列不存在, 只用旧字段重试
        if resp.status_code == 400 and "column" in resp.text.lower():
            data.pop("has_mp4", None)
            data.pop("needs_rescrape", None)
            data.pop("mp4_checked_at", None)
            data.pop("playable", None)
            if not mp4_url:
                # 没有 MP4 也没有新列可标记, 至少更新 checked_at
                data = {"duration": "", "updated_at": now}
            hx.patch(
                SUPABASE_URL + f"/rest/v1/videos?video_id=eq.{video_id}",
                headers=headers,
                json=data,
                timeout=15
            )
    except Exception:
        pass


# ========== 主流程 ==========

async def scrape_all(rescrape_mode: bool = False):
    """主流程: 抓取卡片 → twjn.php 获取 MP4 → 保存
    rescrape_mode: True 时优先重爬 needs_rescrape 的视频
    """
    from playwright.async_api import async_playwright

    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0,
        "pages_crawled": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "mp4_resolved": 0,
        "rescraped": 0,
        "errors": [],
    }

    async with async_playwright() as p:
        user_agent = (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/131.0.0.0 Safari/537.36"
        )
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--no-sandbox", "--disable-setuid-sandbox",
                "--disable-dev-shm-usage", "--disable-gpu",
                "--disable-blink-features=AutomationControlled",
                "--disable-features=IsolateOrigins,site-per-process",
                "--disable-site-isolation-trials",
                "--disable-web-security",
                "--no-first-run", "--no-default-browser-check",
                "--disable-infobars", "--hide-scrollbars",
                "--mute-audio",
            ]
        )
        context = await browser.new_context(
            user_agent=user_agent,
            viewport={"width": 1366, "height": 768},
            locale="ja-JP",
            timezone_id="Asia/Tokyo",
            permissions=["geolocation"],
            geolocation={"latitude": 35.6895, "longitude": 139.6917},
        )

        try:
            # ====== 重爬模式: 优先处理 needs_rescrape 的视频 ======
            if rescrape_mode:
                log("=" * 55)
                log("重爬模式: 获取 needs_rescrape 的视频...")
                candidates = fetch_rescrape_candidates(200)
                log(f"找到 {len(candidates)} 个需要重爬的视频")

                if candidates:
                    # 用 twjn.php 重新解析 MP4
                    results = await resolve_via_twjn(context, [
                        {"video_id": c["video_id"], "monsnode_video_id": c["monsnode_video_id"]}
                        for c in candidates
                    ])

                    rescraped_ok = 0
                    for c in candidates:
                        vid = c["video_id"]
                        mp4 = results.get(vid)
                        update_mp4_status(vid, mp4)
                        if mp4:
                            rescraped_ok += 1

                    stats["rescraped"] = rescraped_ok
                    log(f"重爬完成: {rescraped_ok}/{len(candidates)} 个视频恢复了 MP4")
                else:
                    log("没有需要重爬的视频")

            # ====== 正常抓取模式 ======
            for path, label, max_pages in TARGET_SECTIONS:
                section_url = urljoin(BASE_URL, path)
                all_videos = []

                # trending 和 latest 是 Cloudflare 重点保护页面
                is_problem = label in ("trending", "latest")
                if is_problem:
                    log(f"[{label}] {section_url} (重点页面, 增强等待)")
                else:
                    log(f"[{label}] {section_url}")

                # 步骤1: 抓取页面、解析卡片
                for page_num in range(1, max_pages + 1):
                    url = section_url if page_num == 1 else build_page_url(section_url, page_num)
                    html = await fetch_page(context, url, is_problem_page=is_problem)

                    if not html:
                        if page_num == 1:
                            stats["errors"].append(f"首页抓取失败: {url}")
                            break
                        else:
                            log(f"[{label}] 第{page_num}页失败, 停止翻页", "WARN")
                            break

                    stats["pages_crawled"] += 1
                    videos = parse_video_cards(html, url, label)
                    log(f"  第{page_num}页: {len(videos)} 个视频")

                    if not videos:
                        log(f"[{label}] 无视频, 停止翻页")
                        break

                    existing = {v["video_id"] for v in all_videos}
                    new = [v for v in videos if v["video_id"] not in existing]
                    if not new and page_num > 1:
                        break

                    all_videos.extend(new)
                    if len(all_videos) >= MAX_VIDEOS_PER_SECTION:
                        break

                    await asyncio.sleep(3 if is_problem else 2)

                stats["sections_crawled"] += 1
                stats["videos_found"] += len(all_videos)
                log(f"[{label}] 共发现 {len(all_videos)} 个视频")

                if not all_videos:
                    continue

                # 步骤2: twjn.php → MP4 直链
                log(f"[{label}] twjn.php 获取 MP4 直链 ({len(all_videos)} 个)...")
                mp4_urls = await resolve_via_twjn(context, all_videos)
                stats["mp4_resolved"] += len(mp4_urls)
                log(f"[{label}] 已获取 {len(mp4_urls)} 个 MP4 直链")

                # 合并结果
                for v in all_videos:
                    vid = v["video_id"]
                    if vid in mp4_urls:
                        v["duration"] = mp4_urls[vid]

                # 步骤3: 存入 Supabase
                saved = supabase_save(all_videos)
                stats["videos_saved"] += saved
                log(f"[{label}] 已保存 {saved} 条记录")

                await asyncio.sleep(2)

        finally:
            await context.close()
            await browser.close()

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    return stats


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--rescrape", action="store_true", help="重爬模式: 优先处理 needs_rescrape 的视频")
    parser.add_argument("--fast", action="store_true", help="快速模式: 只抓首页")
    args = parser.parse_args()

    print("=" * 55)
    log("monsnode 爬虫 v3 (可播放性检测 + 重爬标记)")
    if args.rescrape:
        log("模式: 重爬 (优先恢复无 MP4 的视频)")
    log(f"SUPABASE_URL={'已设置' if SUPABASE_URL else '❌ 未设置'}")
    log(f"SUPABASE_KEY={'已设置' if SUPABASE_KEY else '❌ 未设置'}")
    if not SUPABASE_URL or not SUPABASE_KEY:
        log("请设置 SUPABASE_URL 和 SUPABASE_KEY 环境变量", "ERROR")
        sys.exit(1)
    if not SUPABASE_URL.startswith("http"):
        log(f"SUPABASE_URL 缺少协议头: {SUPABASE_URL}", "ERROR")
        sys.exit(1)
    print("=" * 55)

    if args.fast:
        global TARGET_SECTIONS
        TARGET_SECTIONS = [(path, label, 1) for path, label, _ in TARGET_SECTIONS]
        log("快速模式: 每个板块只抓首页")

    stats = asyncio.run(scrape_all(rescrape_mode=args.rescrape))

    print("\n" + "=" * 55)
    print(f"  板块: {stats['sections_crawled']}  页面: {stats['pages_crawled']}")
    print(f"  发现: {stats['videos_found']}  保存: {stats['videos_saved']}")
    print(f"  MP4 直链: {stats['mp4_resolved']} (成功率: {stats['mp4_resolved']/max(stats['videos_found'],1)*100:.0f}%)")
    if stats.get("rescraped"):
        print(f"  重爬恢复: {stats['rescraped']} 个视频")
    if stats["errors"]:
        print(f"  错误: {len(stats['errors'])}")
        for e in stats["errors"][:3]:
            print(f"    - {e[:120]}")
    print("=" * 55)


if __name__ == "__main__":
    main()

"""
monsnode 爬虫 v2: 抓取 → twjn.php 直接获取 MP4 → 存入 Supabase
核心原理: twjn.php?v={视频ID} → base64解码 → video.twimg.com 直链 MP4
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

MAX_RETRIES = 3
MAX_VIDEOS_PER_SECTION = 300
BATCH_SIZE = 50
TWJN_CONCURRENCY = 8  # twjn.php 请求并发数

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")


def log(msg: str, level: str = "INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


def build_page_url(base_url: str, page: int) -> str:
    sep = "&" if "?" in base_url else "?"
    return f"{base_url}{sep}p={page}"


# ========== 页面抓取 (Playwright) ==========

async def fetch_page(browser, url: str, retries: int = MAX_RETRIES) -> str | None:
    """用 Playwright 抓取单页, 等待 Cloudflare JS 验证完成"""
    for attempt in range(1, retries + 1):
        page = None
        try:
            page = await browser.new_page()
            await page.set_extra_http_headers({
                "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                "DNT": "1",
            })
            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            try:
                await page.wait_for_selector("div.listn", timeout=30000)
                await asyncio.sleep(1)
                return await page.content()
            except Exception:
                pass
            html = await page.content()
            if "listn" in html:
                return html
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

        vid = "v" + card_id  # 推文ID 作为我们的 video_id
        if vid in seen_ids:
            continue
        seen_ids.add(vid)

        img_link = card.find("a")
        monsnode_video_id = ""
        thumbnail = ""
        title = ""

        if img_link:
            href = img_link.get("href", "")
            # 提取 monsnode 内部视频ID (用于 twjn.php)
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


# ========== twjn.php → MP4 直链 (核心) ==========

async def resolve_via_twjn(browser, videos: list[dict]) -> dict[str, str]:
    """通过 twjn.php 直接获取 MP4 直链
    twjn.php 页面中有一段 `var u = atob('base64编码的MP4直链')`
    只需解码即可拿到 video.twimg.com 的直链
    """
    mp4_urls = {}
    sem = asyncio.Semaphore(TWJN_CONCURRENCY)

    async def _get_one(v: dict):
        vid = v["video_id"]
        monsnode_id = v.get("monsnode_video_id", "")
        if not monsnode_id:
            return vid, None

        async with sem:
            page = None
            try:
                page = await browser.new_page()
                await page.goto(
                    f"https://monsnode.com/twjn.php?v={monsnode_id}",
                    wait_until="domcontentloaded", timeout=15000
                )
                # twjn.php 页面很轻量, 不需要等 JS 执行完
                # 但需要等一小会确保 base64 字符串在 DOM 中
                await page.wait_for_timeout(600)
                html = await page.content()

                # 提取 base64: atob('xxx')
                m = re.search(r"atob\('([^']+)'\)", html)
                if m:
                    mp4_url = base64.b64decode(m.group(1)).decode('utf-8')
                    if 'video.twimg.com' in mp4_url:
                        return vid, mp4_url

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


# ========== Supabase 保存 ==========

def supabase_save(videos: list[dict]) -> int:
    """批量 upsert 到 Supabase"""
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
    records = []
    for v in videos:
        # duration 字段存: MP4直链 (可播放) 或 空
        mp4 = v.get("duration", "") or ""
        if mp4 and not mp4.startswith("http"):
            mp4 = ""

        records.append({
            "video_id": v["video_id"],
            "title": (v["title"][:500] if v.get("title") else ""),
            "thumbnail_url": (v["thumbnail"][:1000] if v.get("thumbnail") else ""),
            "video_url": (v["url"][:1000] if v.get("url") else ""),
            "author": (v.get("author") or "")[:200],
            "duration": mp4[:500],
            "views": (v.get("views") or "")[:50],
            "monsnode_video_id": (v.get("monsnode_video_id") or "")[:50],
            "source_page": (v.get("source_page") or "")[:500],
            "source_section": (v.get("source_section") or "")[:50],
            "scraped_at": now,
            "updated_at": now,
        })

    saved = 0
    client = hx.Client(timeout=30)
    try:
        for i in range(0, len(records), BATCH_SIZE):
            batch = records[i:i + BATCH_SIZE]
            ok = False
            for attempt in range(1, 4):
                try:
                    resp = client.post(
                        SUPABASE_URL + "/rest/v1/videos",
                        headers=headers,
                        json=batch
                    )
                    if resp.status_code in (200, 201, 409):
                        saved += len(batch)
                        ok = True
                        break
                    else:
                        log(f"Supabase {resp.status_code}: {resp.text[:100]}", "WARN")
                        if attempt < 3:
                            time.sleep(2 ** attempt)
                except Exception as e:
                    log(f"Supabase 异常: {e}", "WARN")
                    time.sleep(1)

            if not ok:
                for rec in batch:
                    try:
                        resp = client.post(
                            SUPABASE_URL + "/rest/v1/videos",
                            headers=headers,
                            json=[rec]
                        )
                        if resp.status_code in (200, 201, 409):
                            saved += 1
                    except Exception:
                        pass
    finally:
        client.close()
    return saved


# ========== 主流程 ==========

async def scrape_all():
    """主流程: 抓取卡片 → twjn.php 获取 MP4 → 保存"""
    from playwright.async_api import async_playwright

    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0,
        "pages_crawled": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "mp4_resolved": 0,
        "errors": [],
    }

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--no-sandbox", "--disable-setuid-sandbox",
                "--disable-dev-shm-usage", "--disable-gpu"
            ]
        )

        try:
            for path, label, max_pages in TARGET_SECTIONS:
                section_url = urljoin(BASE_URL, path)
                all_videos = []
                log(f"[{label}] {section_url}")

                # 步骤1: 抓取页面、解析卡片
                for page_num in range(1, max_pages + 1):
                    url = section_url if page_num == 1 else build_page_url(section_url, page_num)
                    html = await fetch_page(browser, url)

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

                    await asyncio.sleep(2)

                stats["sections_crawled"] += 1
                stats["videos_found"] += len(all_videos)
                log(f"[{label}] 共发现 {len(all_videos)} 个视频")

                if not all_videos:
                    continue

                # 步骤2: twjn.php → MP4 直链 (用同一个 Playwright 浏览器)
                log(f"[{label}] twjn.php 获取 MP4 直链 ({len(all_videos)} 个)...")
                mp4_urls = await resolve_via_twjn(browser, all_videos)
                stats["mp4_resolved"] += len(mp4_urls)
                log(f"[{label}] 已获取 {len(mp4_urls)} 个 MP4 直链")

                # 合并结果
                for v in all_videos:
                    vid = v["video_id"]
                    if vid in mp4_urls:
                        v["duration"] = mp4_urls[vid]
                    # 没有 MP4 的保持 duration 为空 (前端会客户端解析)

                # 步骤3: 存入 Supabase
                saved = supabase_save(all_videos)
                stats["videos_saved"] += saved
                log(f"[{label}] 已保存 {saved} 条记录")

                await asyncio.sleep(2)

        finally:
            await browser.close()

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    return stats


def main():
    if not SUPABASE_URL or not SUPABASE_KEY:
        log("请设置 SUPABASE_URL 和 SUPABASE_KEY 环境变量", "ERROR")
        sys.exit(1)

    print("=" * 55)
    log("monsnode 爬虫 v2 (twjn.php 直链 MP4)")
    print("=" * 55)

    stats = asyncio.run(scrape_all())

    print("\n" + "=" * 55)
    print(f"  板块: {stats['sections_crawled']}  页面: {stats['pages_crawled']}")
    print(f"  发现: {stats['videos_found']}  保存: {stats['videos_saved']}")
    print(f"  MP4 直链: {stats['mp4_resolved']} (成功率: {stats['mp4_resolved']/max(stats['videos_found'],1)*100:.0f}%)")
    if stats["errors"]:
        print(f"  错误: {len(stats['errors'])}")
        for e in stats["errors"][:3]:
            print(f"    - {e[:120]}")
    print("=" * 55)


if __name__ == "__main__":
    main()

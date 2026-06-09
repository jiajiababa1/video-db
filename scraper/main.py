"""
monsnode 一站式爬虫: 抓取 → 解析重定向 → 获取 MP4 → 存入 Supabase
用 Playwright 绕过 Cloudflare, curl_cffi 调 fxtwitter API
一次运行, 直接产出可播放的 MP4 直链
"""
import os, re, sys, time, asyncio
from datetime import datetime, timezone
from urllib.parse import urljoin
from concurrent.futures import ThreadPoolExecutor, as_completed

from bs4 import BeautifulSoup

BASE_URL = "https://monsnode.com"

TARGET_SECTIONS = [
    ("/?t=24h", "24h", 3),
    ("/?t=3d", "3d", 3),
    ("/?t=7d", "7d", 3),
    ("/trending", "trending", 3),
    ("/", "home", 3),
    ("/latest", "latest", 3),
    ("/?ranking=1", "ranking", 2),
]

MAX_RETRIES = 2
MAX_VIDEOS_PER_SECTION = 200
BATCH_SIZE = 50
REDIRECT_CONCURRENCY = 5
MP4_CONCURRENCY = 10

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
            # 超时检查页面内容
            html = await page.content()
            if "listn" in html:
                return html
            log(f"页面无视频内容 (attempt {attempt})", "WARN")
        except Exception as e:
            err = str(e)
            wait = 5 * attempt
            log(f"网络错误 (attempt {attempt}): {err[:80]}, 等待 {wait}s", "WARN")
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
        redirect_url = ""
        thumbnail = ""
        title = ""

        if img_link:
            href = img_link.get("href", "")
            m = re.search(r"redirect\.php\?v=(\d+)", href)
            if m:
                redirect_url = urljoin(BASE_URL, f"redirect.php?v={m.group(1)}")

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
            "redirect_url": redirect_url,
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


# ========== 重定向解析 → 推文 ID (用同一个 Playwright 浏览器, 并发) ==========

async def resolve_redirects(browser, videos: list[dict]) -> dict[str, str | None]:
    """用现有的 Playwright 浏览器跟重定向, 提取推文 ID"""
    sem = asyncio.Semaphore(REDIRECT_CONCURRENCY)

    async def _resolve_one(v: dict):
        redirect = v.get("redirect_url", "")
        if not redirect:
            return v["video_id"], None
        async with sem:
            page = None
            try:
                page = await browser.new_page()
                # &t=1 让 monsnode 直接 302 到 Twitter 推文页
                await page.goto(redirect + "&t=1", wait_until="commit", timeout=15000)
                await page.wait_for_timeout(800)
                m = re.search(r"status/(\d+)", page.url)
                if m:
                    return v["video_id"], m.group(1)
            except Exception:
                pass
            finally:
                if page:
                    try:
                        await page.close()
                    except Exception:
                        pass
        return v["video_id"], None

    to_resolve = [v for v in videos if v.get("redirect_url")]
    if not to_resolve:
        return {}

    total = len(to_resolve)
    results = {}
    # 逐批并发处理, 显示进度
    for i in range(0, total, BATCH_SIZE):
        batch = to_resolve[i:i + BATCH_SIZE]
        tasks = [_resolve_one(v) for v in batch]
        batch_results = await asyncio.gather(*tasks)
        for vid, tid in batch_results:
            if tid:
                results[vid] = tid
        log(f"  重定向解析: {i + len(batch)}/{total} → 已获取 {len(results)} 个推文ID")

    return results


# ========== fxtwitter API → MP4 (curl_cffi, 多线程) ==========

def resolve_mp4_urls(tweet_ids: dict[str, str]) -> dict[str, str]:
    """通过 fxtwitter API 批量获取 MP4 直链"""
    try:
        from curl_cffi import requests as cffi_requests
    except ImportError:
        log("curl_cffi 未安装, 跳过 MP4 解析", "WARN")
        return {}

    mp4_urls = {}

    def _get_one(vid: str, tid: str):
        try:
            resp = cffi_requests.get(
                f"https://api.fxtwitter.com/status/{tid}",
                impersonate="chrome124", timeout=15
            )
            if resp.status_code == 200:
                data = resp.json()
                media = (data.get("tweet", {}).get("media", {}) or {})
                videos = media.get("videos", [])
                if videos:
                    return vid, videos[-1].get("url", "")
        except Exception:
            pass
        return vid, None

    total = len(tweet_ids)
    completed = 0
    with ThreadPoolExecutor(max_workers=MP4_CONCURRENCY) as executor:
        futures = {executor.submit(_get_one, vid, tid): vid for vid, tid in tweet_ids.items()}
        for future in as_completed(futures):
            completed += 1
            vid, url = future.result()
            if url:
                mp4_urls[vid] = url
            if completed % 20 == 0 or completed == total:
                log(f"  MP4 解析: {completed}/{total} → 已获取 {len(mp4_urls)} 个")

    return mp4_urls


async def resolve_mp4_via_twitter_page(browser, tweet_ids: dict[str, str]) -> dict[str, str]:
    """用 Playwright 直接加载 Twitter 移动版页面, 从 HTML 中提取视频 URL
    这是 fxtwitter API 失败后的兜底方案, 最可靠 (真实浏览器渲染)
    """
    mp4_urls = {}
    sem = asyncio.Semaphore(3)  # 限并发

    async def _get_one(vid: str, tid: str):
        async with sem:
            page = None
            try:
                page = await browser.new_page()
                # 移动版 Twitter 页面更轻量
                await page.goto(
                    f"https://mobile.twitter.com/i/status/{tid}",
                    wait_until="domcontentloaded", timeout=20000
                )
                await page.wait_for_timeout(1500)
                html = await page.content()

                # 尝试多种正则匹配 video URL
                patterns = [
                    r'https?://video\.twimg\.com/[^"\'<>\s]+\.mp4',
                    r'video\.twimg\.com/amplify_video/[^"\'<>\s]+',
                    r'video\.twimg\.com/ext_tw_video/[^"\'<>\s]+',
                ]
                for pat in patterns:
                    m = re.search(pat, html)
                    if m:
                        url = m.group(0)
                        if not url.startswith("http"):
                            url = "https://" + url
                        return vid, url

                # 尝试从 Twitter 页面中的 data 属性提取
                m = re.search(r'data-media-url="([^"]+)"', html)
                if m:
                    return vid, m.group(1)

                m = re.search(r'property="og:video"[^>]+content="([^"]+)"', html)
                if m:
                    return vid, m.group(1)

            except Exception:
                pass
            finally:
                if page:
                    try:
                        await page.close()
                    except Exception:
                        pass
        return vid, None

    to_resolve = list(tweet_ids.items())
    total = len(to_resolve)
    log(f"  Twitter 页面直接解析: {total} 个 (移动版)...")

    for i in range(0, total, 10):
        batch = to_resolve[i:i + 10]
        tasks = [_get_one(vid, tid) for vid, tid in batch]
        results = await asyncio.gather(*tasks)
        for vid, url in results:
            if url:
                mp4_urls[vid] = url
        log(f"  Twitter 页面解析: {min(i+10, total)}/{total} → 已获取 {len(mp4_urls)} 个")

    return mp4_urls


# ========== Supabase 保存 ==========

def supabase_save(videos: list[dict]) -> int:
    """批量 upsert 到 Supabase (POST with merge-duplicates)"""
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
        # duration 字段优先级: 已解析的 MP4 URL > Twitter URL > redirect URL > 空
        dur = v.get("duration", "") or ""
        redirect = v.get("redirect_url", "")
        if dur and dur.startswith("http"):
            final_dur = dur[:500]
        elif redirect:
            final_dur = redirect[:500]
        else:
            final_dur = ""

        records.append({
            "video_id": v["video_id"],
            "title": (v["title"][:500] if v.get("title") else ""),
            "thumbnail_url": (v["thumbnail"][:1000] if v.get("thumbnail") else ""),
            "video_url": (v["url"][:1000] if v.get("url") else ""),
            "author": (v.get("author") or "")[:200],
            "duration": final_dur,
            "views": (v.get("views") or "")[:50],
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
                    if resp.status_code in (200, 201):
                        saved += len(batch)
                        ok = True
                        break
                    elif resp.status_code == 409:
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

            # 批量失败则逐条重试
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
    """主流程: 抓取 → 重定向解析 → MP4 解析 → 保存"""
    from playwright.async_api import async_playwright

    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0,
        "pages_crawled": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "redirects_resolved": 0,
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

                # 步骤1: 抓取页面
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

                # 步骤2: 解析重定向 → 推文 ID (用同一个浏览器, 并发)
                log(f"[{label}] 解析重定向 → 推文 ID ({len(all_videos)} 个)...")
                tweet_ids = await resolve_redirects(browser, all_videos)
                stats["redirects_resolved"] += len(tweet_ids)
                log(f"[{label}] 已解析 {len(tweet_ids)} 个推文 ID")

                # 步骤3: fxtwitter API → MP4 直链 (curl_cffi 多线程)
                if tweet_ids:
                    log(f"[{label}] 获取 MP4 直链 ({len(tweet_ids)} 个)...")
                    mp4_urls = resolve_mp4_urls(tweet_ids)
                    stats["mp4_resolved"] += len(mp4_urls)
                    log(f"[{label}] fxtwitter API: {len(mp4_urls)} 个 MP4")

                    # 步骤3b: 对未解析的推文, 用 Playwright 直接解析 Twitter 页面
                    unresolved = {vid: tid for vid, tid in tweet_ids.items() if vid not in mp4_urls}
                    if unresolved:
                        log(f"[{label}] Twitter 页面兜底: {len(unresolved)} 个未解析...")
                        mp4_urls2 = await resolve_mp4_via_twitter_page(browser, unresolved)
                        mp4_urls.update(mp4_urls2)
                        stats["mp4_resolved"] += len(mp4_urls2)
                        log(f"[{label}] Twitter 页面兜底: +{len(mp4_urls2)} 个 MP4")

                    # 将结果合并到视频数据
                    for v in all_videos:
                        vid = v["video_id"]
                        if vid in mp4_urls:
                            v["duration"] = mp4_urls[vid]
                        elif vid in tweet_ids:
                            # 有推文 ID 但无 MP4 → 保存 Twitter URL
                            v["duration"] = f"https://x.com/i/status/{tweet_ids[vid]}"

                # 步骤4: 存入 Supabase
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
    log("monsnode 一站式爬虫 (抓取 → 解析 → MP4 → 入库)")
    print("=" * 55)

    stats = asyncio.run(scrape_all())

    print("\n" + "=" * 55)
    print(f"  板块: {stats['sections_crawled']}  页面: {stats['pages_crawled']}")
    print(f"  发现: {stats['videos_found']}  保存: {stats['videos_saved']}")
    print(f"  重定向→推文ID: {stats['redirects_resolved']}")
    print(f"  MP4直链: {stats['mp4_resolved']}")
    if stats["errors"]:
        print(f"  错误: {len(stats['errors'])}")
        for e in stats["errors"][:3]:
            print(f"    - {e[:120]}")
    print("=" * 55)


if __name__ == "__main__":
    main()

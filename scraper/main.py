"""
monsnode.com 视频爬虫 v5
- 优先使用 Playwright 无头 Chromium 绕过 Cloudflare
- 本地环境可用 curl_cffi 加速（通过 --fast 参数）
- 抓取多时间段页面 + 热门/最新/排行
- 通过 Supabase REST API 存入数据库
"""
import os
import re
import sys
import json
import time
import asyncio
from datetime import datetime, timezone
from urllib.parse import urljoin

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

REQUEST_DELAY = 2.0
MAX_RETRIES = 2
MAX_VIDEOS_PER_SECTION = 200
BATCH_SIZE = 50

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")


def log(msg: str, level: str = "INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}")


def build_page_url(base_url: str, page: int) -> str:
    sep = "&" if "?" in base_url else "?"
    return f"{base_url}{sep}p={page}"


# ========== Playwright 模式 ==========

async def _fetch_playwright(browser, url: str, label: str) -> str | None:
    """用 Playwright 抓取单页，等待 Cloudflare JS 验证完成"""
    page = None
    try:
        page = await browser.new_page()
        await page.set_extra_http_headers({
            "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        })
        # domcontentloaded 快速触发，然后等 Cloudflare JS Challenge 完成
        await page.goto(url, wait_until="domcontentloaded", timeout=30000)
        # 等最多 30 秒让 Cloudflare JS challenge 完成并加载视频卡片
        try:
            await page.wait_for_selector("div.listn", timeout=30000)
            await asyncio.sleep(1)
            return await page.content()
        except Exception:
            pass
        # 超时了，保存调试信息
        title = await page.title()
        html = await page.content()
        if label == "home":
            try:
                with open("debug_page.html", "w", encoding="utf-8") as f:
                    f.write(html)
                log("已保存 debug_page.html", "INFO")
            except Exception:
                pass
        log(f"等待超时: title='{title[:60]}', len={len(html)}", "WARN")
    except Exception as e:
        log(f"Playwright 错误: {str(e)[:100]}", "WARN")
    finally:
        if page:
            await page.close()
    return None


async def scrape_with_playwright() -> dict:
    """Playwright 模式主流程"""
    from playwright.async_api import async_playwright
    import subprocess

    # 确保 Chromium 已安装（含系统依赖）
    try:
        subprocess.run([sys.executable, "-m", "playwright", "install", "--with-deps", "chromium"],
                       capture_output=True, timeout=120)
    except Exception:
        pass

    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0, "pages_crawled": 0,
        "videos_found": 0, "videos_saved": 0, "errors": [],
    }

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=["--no-sandbox", "--disable-setuid-sandbox",
                  "--disable-dev-shm-usage", "--disable-gpu"]
        )
        try:
            for path, label, max_pages in TARGET_SECTIONS:
                section_url = urljoin(BASE_URL, path)
                all_videos = []
                log(f"[{label}] {section_url}")

                for page_num in range(1, max_pages + 1):
                    url = section_url if page_num == 1 else build_page_url(section_url, page_num)

                    for attempt in range(1, MAX_RETRIES + 1):
                        html = await _fetch_playwright(browser, url, label)
                        if html:
                            break
                        if attempt < MAX_RETRIES:
                            wait = 5 * attempt
                            log(f"重试 (attempt {attempt}): 等待 {wait}s", "WARN")
                            await asyncio.sleep(wait)

                    if not html:
                        if page_num == 1:
                            stats["errors"].append(f"首页抓取失败: {url}")
                            break
                        else:
                            log(f"[{label}] 第{page_num}页失败，停止翻页", "WARN")
                            break

                    stats["pages_crawled"] += 1
                    videos = parse_video_cards(html, url, label)
                    log(f"  第{page_num}页: {len(videos)} 个视频")

                    if not videos:
                        log(f"[{label}] 无视频，停止翻页")
                        break

                    existing = {v["video_id"] for v in all_videos}
                    new = [v for v in videos if v["video_id"] not in existing]
                    if not new and page_num > 1:
                        break

                    all_videos.extend(new)
                    if len(all_videos) >= MAX_VIDEOS_PER_SECTION:
                        break

                    await asyncio.sleep(REQUEST_DELAY)

                stats["sections_crawled"] += 1
                stats["videos_found"] += len(all_videos)
                log(f"[{label}] 共 {len(all_videos)} 个视频")

                if all_videos:
                    # 解析重定向 URL 获取真实视频源地址 (Playwright 环境用 httpx)
                    resolved = resolve_redirect_urls(all_videos, use_curl_cffi=False)
                    log(f"[{label}] 已解析 {resolved} 个真实地址")

                    saved = supabase_save(all_videos)
                    stats["videos_saved"] += saved
                    log(f"[{label}] 已保存 {saved}")

                await asyncio.sleep(REQUEST_DELAY)
        finally:
            await browser.close()

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    return stats


# ========== curl_cffi 模式 (本地快速) ==========

def scrape_with_curl_cffi() -> dict:
    """curl_cffi 模式（本地使用，GitHub Actions 上 IP 被封）"""
    from curl_cffi import requests

    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0, "pages_crawled": 0,
        "videos_found": 0, "videos_saved": 0, "errors": [],
    }

    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
    }

    for path, label, max_pages in TARGET_SECTIONS:
        section_url = urljoin(BASE_URL, path)
        all_videos = []
        log(f"[{label}] {section_url}")

        for page_num in range(1, max_pages + 1):
            url = section_url if page_num == 1 else build_page_url(section_url, page_num)

            soup = None
            for attempt in range(1, MAX_RETRIES + 1):
                try:
                    resp = requests.get(url, headers=headers, impersonate="chrome124", timeout=30)
                    if resp.status_code == 200:
                        soup = BeautifulSoup(resp.text, "lxml")
                        break
                    elif resp.status_code in (403, 429):
                        time.sleep(10 * attempt)
                except Exception:
                    time.sleep(5 * attempt)

            if not soup:
                if page_num == 1:
                    stats["errors"].append(f"首页抓取失败: {url}")
                    break
                else:
                    log(f"[{label}] 第{page_num}页失败，停止翻页", "WARN")
                    break

            stats["pages_crawled"] += 1
            videos = parse_video_cards(soup, url, label)
            log(f"  第{page_num}页: {len(videos)} 个视频")

            if not videos and page_num == 1:
                # 调试: 保存 HTML 看看页面内容
                try:
                    debug_file = f"debug_{label}.html"
                    with open(debug_file, "w", encoding="utf-8") as f:
                        f.write(str(soup)[:5000])
                    log(f"已保存调试文件 {debug_file} (前5000字符)", "INFO")
                except Exception:
                    pass

            if not videos:
                break

            existing = {v["video_id"] for v in all_videos}
            new = [v for v in videos if v["video_id"] not in existing]
            if not new and page_num > 1:
                break

            all_videos.extend(new)
            if len(all_videos) >= MAX_VIDEOS_PER_SECTION:
                break

            time.sleep(REQUEST_DELAY)

        stats["sections_crawled"] += 1
        stats["videos_found"] += len(all_videos)
        log(f"[{label}] 共 {len(all_videos)} 个视频")

        if all_videos:
            # 解析重定向 URL 获取真实视频源地址
            resolved = resolve_redirect_urls(all_videos, headers, use_curl_cffi=True)
            log(f"[{label}] 已解析 {resolved} 个真实地址")

            saved = supabase_save(all_videos)
            stats["videos_saved"] += saved
            log(f"[{label}] 已保存 {saved}")

        time.sleep(REQUEST_DELAY)

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    return stats


# ========== 共用解析 ==========

def parse_video_cards(soup_or_html, page_url: str, section: str) -> list[dict]:
    """解析 monsnode 页面，提取视频卡片"""
    if isinstance(soup_or_html, str):
        soup = BeautifulSoup(soup_or_html, "lxml")
    else:
        soup = soup_or_html

    videos = []
    seen_ids = set()

    cards = soup.find_all("div", class_="listn")

    for card in cards:
        card_id = card.get("id", "").strip()
        if not card_id or not card_id.isdigit():
            continue

        vid = "v" + card_id
        if vid in seen_ids:
            continue
        seen_ids.add(vid)

        img_link = card.find("a")
        redirect_num = ""
        redirect_url = ""
        thumbnail = ""
        title = ""

        if img_link:
            href = img_link.get("href", "")
            m = re.search(r"redirect\.php\?v=(\d+)", href)
            if m:
                redirect_num = m.group(1)
                redirect_url = urljoin(BASE_URL, f"redirect.php?v={redirect_num}")

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

        # 提取播放量 / 热度
        views = ""
        for cls in ("view", "views", "count", "like", "heart", "point"):
            v_el = card.find(class_=cls)
            if v_el:
                txt = v_el.get_text(strip=True)
                # 清洗数字
                nums = re.findall(r'[\d,]+', txt)
                if nums:
                    views = nums[0].replace(",", "")
                break

        # 提取视频时长
        duration = ""
        for cls in ("time", "duration", "length", "dur"):
            d_el = card.find(class_=cls)
            if d_el:
                duration = d_el.get_text(strip=True)[:20]
                break

        # 提取 ranking 排名数字 (ranking 页面)
        rank_num = ""
        if "ranking" in section:
            rank_el = card.find(class_="rank") or card.find(class_="number")
            if rank_el:
                rank_num = re.sub(r'\D', '', rank_el.get_text(strip=True))

        video_url = urljoin(BASE_URL, "/" + vid)

        videos.append({
            "video_id": vid,
            "url": video_url,
            "redirect_url": redirect_url,
            "title": title,
            "thumbnail": thumbnail,
            "author": author,
            "duration": duration,
            "views": views,
            "rank": rank_num,
            "source_section": section,
            "source_page": page_url,
        })

    return videos


# ========== 重定向解析 ==========

def resolve_redirect_urls(videos: list[dict], headers: dict = None, use_curl_cffi: bool = True) -> int:
    """批量解析 redirect URL, 获取真实视频源地址存入 duration 字段"""
    if not videos:
        return 0

    def _resolve_curl_cffi(video):
        redirect = video.get("redirect_url", "")
        if not redirect:
            return
        try:
            from curl_cffi import requests as cffi_requests
            resp = cffi_requests.get(redirect, headers=headers or {},
                                     impersonate="chrome124",
                                     allow_redirects=True, timeout=15)
            final = str(resp.url)
            if final and final != redirect:
                video["duration"] = final[:200]
        except Exception:
            pass

    def _resolve_httpx(video):
        redirect = video.get("redirect_url", "")
        if not redirect:
            return
        try:
            import httpx as hx
            with hx.Client(follow_redirects=True, timeout=15) as client:
                resp = client.head(redirect)
                final = str(resp.url)
                if final and final != redirect:
                    video["duration"] = final[:200]
        except Exception:
            pass

    resolve_fn = _resolve_curl_cffi if use_curl_cffi else _resolve_httpx

    # 多线程并行解析 (最多 5 个并发)
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
        list(executor.map(resolve_fn, videos))

    resolved = sum(1 for v in videos if v.get("duration", "").startswith("http"))
    return resolved


# ========== Supabase ==========

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
        redirect = v.get("redirect_url", "")
        # 优先使用已解析的真实地址 (resolve_redirect_urls 会设置 v["duration"])
        resolved_duration = v.get("duration") or redirect
        records.append({
            "video_id": v["video_id"],
            "title": (v["title"][:500] if v["title"] else ""),
            "thumbnail_url": (v["thumbnail"][:1000] if v["thumbnail"] else ""),
            "video_url": (v["url"][:1000] if v["url"] else ""),
            "author": v.get("author", "")[:200],
            "duration": resolved_duration[:200],
            "views": v.get("views", "")[:50],
            "source_page": v.get("source_page", "")[:500],
            "source_section": v.get("source_section", "")[:50],
            "scraped_at": now,
            "updated_at": now,
        })
    saved = 0
    client = hx.Client(timeout=30)
    try:
        for i in range(0, len(records), BATCH_SIZE):
            batch = records[i:i + BATCH_SIZE]
            ok = False
            for attempt in range(1, 3):
                try:
                    resp = client.post(SUPABASE_URL + "/rest/v1/videos", headers=headers, json=batch)
                    if resp.status_code in (200, 201):
                        saved += len(batch)
                        ok = True
                        break
                    elif resp.status_code == 409:
                        # 数据已存在, 也算成功
                        saved += len(batch)
                        ok = True
                        break
                    else:
                        log(f"Supabase {resp.status_code}: {resp.text[:100]}", "WARN")
                        if attempt < 2:
                            time.sleep(2)
                except Exception as e:
                    log(f"Supabase异常: {e}", "WARN")
                    time.sleep(1)
            # 批量失败则逐条尝试
            if not ok:
                for rec in batch:
                    try:
                        resp = client.post(SUPABASE_URL + "/rest/v1/videos", headers=headers, json=[rec])
                        if resp.status_code in (200, 201, 409):
                            saved += 1
                    except Exception:
                        pass
    finally:
        client.close()
    return saved


def _save_status(stats: dict):
    if not SUPABASE_URL or not SUPABASE_KEY:
        return
    try:
        import httpx as hx
        headers = {
            "apikey": SUPABASE_KEY,
            "Authorization": "Bearer " + SUPABASE_KEY,
            "Content-Type": "application/json",
        }
        body = {
            "last_run": stats["finished_at"],
            "videos_saved": stats["videos_saved"],
            "videos_found": stats["videos_found"],
            "pages_crawled": stats["pages_crawled"],
            "errors": json.dumps(stats["errors"][:5]) if stats["errors"] else "",
        }
        client = hx.Client(timeout=10)
        try:
            client.post(SUPABASE_URL + "/rest/v1/scrape_status", headers=headers, json=body)
        finally:
            client.close()
    except Exception:
        pass


def _scrape_failed_with_playwright(error_list: list) -> dict:
    """用 Playwright 回退抓取 curl_cffi 失败的页面"""
    import subprocess
    result = {"videos_found": 0, "videos_saved": 0, "pages_crawled": 0, "remaining_errors": []}

    # 从错误信息中提取 URL 和 label
    failed_sections = []
    url_label_map = {urljoin(BASE_URL, p): lb for p, lb, _ in TARGET_SECTIONS}
    # 也添加带参数的 URL
    for path, label, _ in TARGET_SECTIONS:
        section_url = urljoin(BASE_URL, path)
        for e in error_list:
            if section_url in e:
                failed_sections.append((section_url, label))
                break

    if not failed_sections:
        result["remaining_errors"] = error_list
        return result

    # 确保 Chromium 已安装
    try:
        subprocess.run([sys.executable, "-m", "playwright", "install", "chromium"],
                       capture_output=True, timeout=120)
    except Exception:
        pass

    import asyncio as aio
    from playwright.async_api import async_playwright

    async def _pw_scrape():
        nonlocal result
        async with async_playwright() as p:
            browser = await p.chromium.launch(
                headless=True,
                args=["--no-sandbox", "--disable-setuid-sandbox",
                      "--disable-dev-shm-usage", "--disable-gpu"]
            )
            try:
                for section_url, label in failed_sections:
                    all_videos = []
                    log(f"[PW回退] [{label}] {section_url}")
                    page = None
                    try:
                        page = await browser.new_page()
                        await page.set_extra_http_headers({
                            "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
                            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                        })
                        await page.goto(section_url, wait_until="domcontentloaded", timeout=30000)
                        try:
                            await page.wait_for_selector("div.listn", timeout=30000)
                            await aio.sleep(1)
                        except Exception:
                            pass
                        html = await page.content()
                        if html:
                            soup = BeautifulSoup(html, "lxml")
                            videos = parse_video_cards(soup, section_url, label)
                            log(f"  {len(videos)} 个视频")
                            all_videos = videos
                            result["pages_crawled"] += 1
                    except Exception as e:
                        log(f"Playwright 错误: {str(e)[:80]}", "WARN")
                    finally:
                        if page:
                            await page.close()

                    result["videos_found"] += len(all_videos)
                    if all_videos:
                        saved = supabase_save(all_videos)
                        result["videos_saved"] += saved
                        log(f"[PW回退] [{label}] 保存 {saved}")
                    await aio.sleep(2)
                result["remaining_errors"] = []  # 已处理
            finally:
                await browser.close()

    aio.run(_pw_scrape())
    return result


# ========== 主入口 ==========

def detect_env() -> str:
    """检测运行环境: 'github' | 'local'"""
    if os.environ.get("GITHUB_ACTIONS") == "true":
        return "github"
    return "local"


def main():
    if not SUPABASE_URL or not SUPABASE_KEY:
        log("请设置 SUPABASE_URL 和 SUPABASE_KEY", "ERROR")
        sys.exit(1)

    fast_mode = "--fast" in sys.argv
    env = detect_env()

    print("=" * 55)
    log(f"monsnode 爬虫 v5 | 环境: {env} | 模式: {'curl_cffi' if fast_mode else 'Playwright'}")
    print("=" * 55)

    if fast_mode or env == "local":
        stats = scrape_with_curl_cffi()
        # 对 curl_cffi 失败的页面, 尝试 Playwright 回退
        if stats["errors"]:
            log("尝试 Playwright 回退失败页面...", "INFO")
            pw_stats = _scrape_failed_with_playwright(stats["errors"])
            stats["videos_found"] += pw_stats["videos_found"]
            stats["videos_saved"] += pw_stats["videos_saved"]
            stats["pages_crawled"] += pw_stats["pages_crawled"]
            # 清除已处理的错误
            stats["errors"] = pw_stats.get("remaining_errors", [])
    else:
        stats = asyncio.run(scrape_with_playwright())

    _save_status(stats)

    print("\n" + "=" * 55)
    print(f"  Section: {stats['sections_crawled']}  页面: {stats['pages_crawled']}")
    print(f"  发现: {stats['videos_found']}  保存: {stats['videos_saved']}")
    if stats["errors"]:
        print(f"  错误: {len(stats['errors'])}")
        for e in stats["errors"][:5]:
            print(f"    - {e[:120]}")
    print("=" * 55)


if __name__ == "__main__":
    main()

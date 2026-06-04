"""
monsnode.com 瑙嗛鐖櫕 v5
- 浣跨敤 Playwright 鏃犲ご Chromium 缁曡繃 Cloudflare
- 鐪熷疄娴忚鍣ㄧ幆澧冿紝鑳藉鐞?JS Challenge + TLS 鎸囩汗
- 鎶撳彇澶氭椂闂存椤甸潰 + 鐑棬/鏈€鏂?鎺掕
- 閫氳繃 Supabase REST API 瀛樺叆鏁版嵁搴?"""
import os
import re
import sys
import json
import time
import asyncio
from datetime import datetime, timezone
from urllib.parse import urljoin

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
MAX_RETRIES = 3
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


async def fetch_page_playwright(browser, url: str, retries: int = MAX_RETRIES) -> str | None:
    """鐢?Playwright 鏃犲ご娴忚鍣ㄦ姄鍙栭〉闈?""
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
            # 绛変竴浼氬効璁?Cloudflare challenge 瀹屾垚
            await asyncio.sleep(2)
            html = await page.content()
            if "listn" in html:
                return html
            elif "Checking your browser" in html or "cf-browser-verification" in html.lower():
                log(f"Cloudflare 楠岃瘉涓紝绛夊緟...", "WARN")
                await asyncio.sleep(5)
                html = await page.content()
                if "listn" in html:
                    return html
            log(f"椤甸潰鏃犺棰戝唴瀹?(attempt {attempt})", "WARN")
        except Exception as e:
            err_msg = str(e)
            if "net::ERR" in err_msg or "timeout" in err_msg.lower():
                wait = 5 * attempt
                log(f"缃戠粶閿欒 (attempt {attempt}): {err_msg[:60]}, 绛夊緟 {wait}s", "WARN")
            else:
                wait = 3 * attempt
                log(f"閿欒 (attempt {attempt}): {err_msg[:60]}, 绛夊緟 {wait}s", "WARN")
        finally:
            if page:
                await page.close()
        if attempt < retries:
            await asyncio.sleep(5 * attempt)
    return None


def parse_video_cards(html: str, page_url: str, section: str) -> list[dict]:
    """瑙ｆ瀽 HTML 鎻愬彇瑙嗛鍗＄墖"""
    from bs4 import BeautifulSoup
    soup = BeautifulSoup(html, "lxml")
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

        video_url = urljoin(BASE_URL, "/" + vid)

        videos.append({
            "video_id": vid,
            "url": video_url,
            "redirect_url": redirect_url,
            "title": title,
            "thumbnail": thumbnail,
            "author": author,
            "duration": "",
            "views": "",
            "source_section": section,
            "source_page": page_url,
        })

    return videos


def supabase_save(videos: list[dict]) -> int:
    """鎵归噺 upsert 鍒?Supabase"""
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
        records.append({
            "video_id": v["video_id"],
            "title": (v["title"][:500] if v["title"] else ""),
            "thumbnail_url": (v["thumbnail"][:1000] if v["thumbnail"] else ""),
            "video_url": (v["url"][:1000] if v["url"] else ""),
            "author": v.get("author", "")[:200],
            "duration": redirect[:50],
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
            for attempt in range(1, 4):
                try:
                    resp = client.post(SUPABASE_URL + "/rest/v1/videos", headers=headers, json=batch)
                    if resp.status_code in (200, 201):
                        saved += len(batch)
                        break
                    else:
                        log(f"Supabase {resp.status_code}: {resp.text[:100]}", "WARN")
                        if attempt < 3:
                            time.sleep(2 ** attempt)
                except Exception as e:
                    log(f"Supabase寮傚父: {e}", "WARN")
                    time.sleep(2)
    finally:
        client.close()
    return saved


async def scrape_all():
    """涓绘祦绋?- 浣跨敤 Playwright"""
    from playwright.async_api import async_playwright

    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0,
        "pages_crawled": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "errors": [],
    }

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--no-sandbox",
                "--disable-setuid-sandbox",
                "--disable-dev-shm-usage",
                "--disable-gpu",
            ]
        )

        try:
            for path, label, max_pages in TARGET_SECTIONS:
                section_url = urljoin(BASE_URL, path)
                all_videos = []
                log(f"[{label}] {section_url}")

                for page_num in range(1, max_pages + 1):
                    url = section_url if page_num == 1 else build_page_url(section_url, page_num)
                    html = await fetch_page_playwright(browser, url)

                    if not html:
                        if page_num == 1:
                            stats["errors"].append(f"棣栭〉鎶撳彇澶辫触: {url}")
                            break
                        else:
                            log(f"[{label}] 绗瑊page_num}椤靛け璐ワ紝鍋滄缈婚〉", "WARN")
                            break

                    stats["pages_crawled"] += 1
                    videos = parse_video_cards(html, url, label)
                    log(f"  绗瑊page_num}椤? {len(videos)} 涓棰?)

                    if not videos:
                        log(f"[{label}] 鏃犺棰戯紝鍋滄缈婚〉")
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
                log(f"[{label}] 鍏?{len(all_videos)} 涓棰?)

                if all_videos:
                    saved = supabase_save(all_videos)
                    stats["videos_saved"] += saved
                    log(f"[{label}] 宸蹭繚瀛?{saved}")

                await asyncio.sleep(REQUEST_DELAY)
        finally:
            await browser.close()

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    return stats


def main():
    if not SUPABASE_URL or not SUPABASE_KEY:
        log("璇疯缃?SUPABASE_URL 鍜?SUPABASE_KEY", "ERROR")
        sys.exit(1)

    print("=" * 55)
    log("monsnode 鐖櫕 v5 (Playwright)")
    print("=" * 55)

    stats = asyncio.run(scrape_all())

    print("\n" + "=" * 55)
    print(f"  Section: {stats['sections_crawled']}  椤甸潰: {stats['pages_crawled']}")
    print(f"  鍙戠幇: {stats['videos_found']}  淇濆瓨: {stats['videos_saved']}")
    if stats["errors"]:
        print(f"  閿欒: {len(stats['errors'])}")
        for e in stats["errors"][:5]:
            print(f"    - {e[:120]}")
    print("=" * 55)


if __name__ == "__main__":
    main()

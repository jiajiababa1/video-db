"""
monsnode.com 瑙嗛鐖櫕 v4
- 浣跨敤 curl_cffi 妯℃嫙 Chrome TLS 鎸囩汗缁曡繃 Cloudflare
- 鎶撳彇澶氭椂闂存椤甸潰锛?4灏忔椂/3澶?7澶?鐑棬/鎺ㄨ崘/鏈€鏂?鎺掕锛?- 姝ｇ‘鎻愬彇瑙嗛ID銆佺缉鐣ュ浘銆佹爣棰樸€佷綔鑰呫€乺edirect缂栧彿
- 鎸囨暟閫€閬块噸璇?+ 璇︾粏鏃ュ織
- 閫氳繃 Supabase REST API 瀛樺叆鏁版嵁搴?"""

import os
import re
import time
import sys
import json
import traceback
from datetime import datetime, timezone
from urllib.parse import urljoin

from curl_cffi import requests
from bs4 import BeautifulSoup

# ========== 閰嶇疆 ==========

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

# Chrome 125 瀹屾暣璇锋眰澶?HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
    "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
    "Accept-Encoding": "gzip, deflate, br",
    "Cache-Control": "no-cache",
    "Sec-Ch-Ua": '"Google Chrome";v="125", "Chromium";v="125", "Not.A/Brand";v="24"',
    "Sec-Ch-Ua-Mobile": "?0",
    "Sec-Ch-Ua-Platform": '"Windows"',
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Upgrade-Insecure-Requests": "1",
    "DNT": "1",
}

REQUEST_DELAY = 2.0
MAX_RETRIES = 4
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


def fetch_page(url: str, referer: str = "", retries: int = MAX_RETRIES) -> BeautifulSoup | None:
    """鐢?curl_cffi 鎶撳彇椤甸潰锛屾ā鎷?Chrome 125 TLS 鎸囩汗"""
    headers = dict(HEADERS)
    headers["Referer"] = referer if referer else "https://www.google.com/"

    for attempt in range(1, retries + 1):
        try:
            resp = requests.get(
                url,
                headers=headers,
                impersonate="chrome124",
                timeout=30,
            )
            if resp.status_code == 200:
                return BeautifulSoup(resp.text, "lxml")
            elif resp.status_code == 429:
                wait = 30 * attempt
                log(f"闄愭祦 (429)锛岀瓑寰?{wait}s...", "WARN")
                time.sleep(wait)
            elif resp.status_code == 403:
                wait = 10 * attempt
                log(f"鎷︽埅 (403)锛岀瓑寰?{wait}s 閲嶈瘯 (绗瑊attempt}娆?...", "WARN")
                time.sleep(wait)
            elif resp.status_code >= 500:
                wait = 2 ** attempt
                log(f"鏈嶅姟鍣ㄩ敊璇?{resp.status_code}锛岀瓑寰?{wait}s...", "WARN")
                time.sleep(wait)
            else:
                log(f"HTTP {resp.status_code}: {url}", "ERROR")
                return None
        except Exception as e:
            err_msg = str(e)
            if "curl" in err_msg.lower() or "reset" in err_msg.lower():
                wait = 5 * attempt
                log(f"杩炴帴閲嶇疆 {url[:50]}锛岀瓑寰?{wait}s (绗瑊attempt}娆?...", "WARN")
            else:
                wait = 3 * attempt
                log(f"鎶撳彇澶辫触 {url[:50]}: {e}", "WARN")
            if attempt < retries:
                time.sleep(wait)
    return None


def find_video_cards(soup: BeautifulSoup, page_url: str, section: str) -> list[dict]:
    """瑙ｆ瀽 monsnode 椤甸潰锛屾彁鍙栬棰戝崱鐗?""
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


# ========== Supabase (鐢?httpx 淇濈暀锛屽洜涓哄彧鏈夊啓鍏ラ渶瑕? ==========

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


# ========== 涓绘祦绋?==========

def scrape_all() -> dict:
    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0,
        "pages_crawled": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "errors": [],
    }

    for path, label, max_pages in TARGET_SECTIONS:
        section_url = urljoin(BASE_URL, path)
        all_videos = []

        log(f"[{label}] {section_url}")

        for page in range(1, max_pages + 1):
            url = section_url if page == 1 else build_page_url(section_url, page)
            referer = section_url if page > 1 else ""

            soup = fetch_page(url, referer=referer)
            if not soup:
                if page == 1:
                    stats["errors"].append(f"棣栭〉鎶撳彇澶辫触: {url}")
                    break
                else:
                    log(f"[{label}] 绗瑊page}椤靛け璐ワ紝鍋滄缈婚〉", "WARN")
                    break

            stats["pages_crawled"] += 1
            videos = find_video_cards(soup, url, label)
            log(f"  绗瑊page}椤? {len(videos)} 涓棰?)

            if not videos:
                log(f"[{label}] 鏃犺棰戯紝鍋滄缈婚〉")
                break

            existing = {v["video_id"] for v in all_videos}
            new = [v for v in videos if v["video_id"] not in existing]
            if not new and page > 1:
                break

            all_videos.extend(new)
            if len(all_videos) >= MAX_VIDEOS_PER_SECTION:
                break

            time.sleep(REQUEST_DELAY)

        stats["sections_crawled"] += 1
        stats["videos_found"] += len(all_videos)
        log(f"[{label}] 鍏?{len(all_videos)} 涓棰?)

        if all_videos:
            saved = supabase_save(all_videos)
            stats["videos_saved"] += saved
            log(f"[{label}] 宸蹭繚瀛?{saved}")

        time.sleep(REQUEST_DELAY)

    _save_status(stats)
    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    return stats


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


def main():
    if not SUPABASE_URL or not SUPABASE_KEY:
        log("璇疯缃?SUPABASE_URL 鍜?SUPABASE_KEY", "ERROR")
        sys.exit(1)

    print("=" * 55)
    log("monsnode 鐖櫕 v4 (curl_cffi)")
    print("=" * 55)

    stats = scrape_all()

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

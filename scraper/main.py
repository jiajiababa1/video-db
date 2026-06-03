"""
monsnode.com 瑙嗛鐖櫕
浠?monsnode 鎶撳彇瑙嗛灏侀潰銆佽棰戦摼鎺ワ紝瀛樺叆 Supabase 鏁版嵁搴?姣忓ぉ瀹氭椂杩愯涓€娆?浣跨敤 Supabase REST API 鐩存帴鎿嶄綔锛屾棤闇€ SDK
"""

import os
import re
import time
import sys
from datetime import datetime, timezone
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup

# ========== 閰嶇疆 ==========

BASE_URL = "https://monsnode.com"
TARGET_PAGES = [
    "/trending",
    "/",
    "/latest",
]

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language": "ja,en-US;q=0.9,en;q=0.8,zh-CN;q=0.7,zh;q=0.6",
    "DNT": "1",
}

REQUEST_DELAY = 2
MAX_VIDEOS_PER_PAGE = 100

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")


# ========== Supabase REST API ==========

def supabase_api_headers():
    """鏋勫缓 Supabase REST API 璇锋眰澶?""
    return {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
    }


def save_videos(videos: list[dict]) -> int:
    """閫氳繃 REST API 鎵归噺 upsert 瑙嗛鏁版嵁"""
    if not videos:
        return 0

    now = datetime.now(timezone.utc).isoformat()
    records = []
    for v in videos:
        records.append({
            "video_id": v["video_id"],
            "title": (v["title"][:500] if v["title"] else ""),
            "thumbnail_url": (v["thumbnail"][:1000] if v["thumbnail"] else ""),
            "video_url": (v["url"][:1000] if v["url"] else ""),
            "author": v.get("author", "")[:200],
            "duration": v.get("duration", "")[:50],
            "views": v.get("views", "")[:50],
            "source_page": v.get("source_page", "")[:500],
            "updated_at": now,
        })

    api_headers = supabase_api_headers()
    # upsert 妯″紡: 鍐茬獊鏃跺悎骞?    api_headers["Prefer"] = "resolution=merge-duplicates"

    saved = 0
    batch_size = 50
    client = httpx.Client(timeout=30)

    try:
        for i in range(0, len(records), batch_size):
            batch = records[i : i + batch_size]
            try:
                resp = client.post(
                    SUPABASE_URL + "/rest/v1/videos",
                    headers=api_headers,
                    json=batch,
                )
                if resp.status_code in (200, 201):
                    saved += len(batch)
                else:
                    print(f"  [ERROR] API 杩斿洖 {resp.status_code}: {resp.text[:200]}")
                    # 閫愭潯閲嶈瘯
                    for rec in batch:
                        try:
                            r = client.post(
                                SUPABASE_URL + "/rest/v1/videos",
                                headers=api_headers,
                                json=[rec],
                            )
                            if r.status_code in (200, 201):
                                saved += 1
                            else:
                                print(f"  [ERROR] 鍗曟潯鍐欏叆澶辫触 {rec['video_id']}: {r.status_code}")
                        except Exception as e2:
                            print(f"  [ERROR] 鍗曟潯鍐欏叆寮傚父 {rec['video_id']}: {e2}")
            except Exception as e:
                print(f"  [ERROR] 鎵规鍐欏叆澶辫触: {e}")
    finally:
        client.close()

    return saved


# ========== 鏁版嵁鎻愬彇閫昏緫 ==========

def extract_video_id(url: str) -> str | None:
    match = re.search(r"(v\d{15,25})", url)
    return match.group(1) if match else None


def find_video_cards(soup: BeautifulSoup, page_url: str) -> list[dict]:
    """瑙ｆ瀽 monsnode 椤甸潰缁撴瀯锛屾彁鍙栬棰戝崱鐗囨暟鎹?    椤甸潰缁撴瀯: div.listn[id=瑙嗛ID] > a[href=redirect] > img[src][alt]
                          > div.user > a[href=/v{id}] > span (浣滆€?
    """
    videos = []
    seen_ids = set()

    # 鐩存帴鍖归厤 div.listn 鍗＄墖
    cards = soup.find_all("div", class_="listn")
    for card in cards:
        # 瑙嗛 ID 鏉ヨ嚜 div.listn 鐨?id 灞炴€?        card_id = card.get("id", "").strip()
        if not card_id or not card_id.isdigit():
            continue
        vid = "v" + card_id
        if vid in seen_ids:
            continue
        seen_ids.add(vid)

        video_data = {
            "video_id": vid,
            "url": urljoin(BASE_URL, "/" + vid),
            "title": "",
            "thumbnail": "",
            "author": "",
        }

        # 鎻愬彇灏侀潰鍥惧拰鏍囬 (img 鏍囩鍦?a 鏍囩鍐?
        img = card.find("img")
        if img:
            src = img.get("src", "")
            if src:
                video_data["thumbnail"] = urljoin(BASE_URL, src)
            alt = img.get("alt", "").strip()
            if alt:
                # alt 鍙兘鍖呭惈澶氳锛屽彇绗竴琛屼綔涓烘爣棰?                video_data["title"] = alt.split("\n")[0].strip()[:500]

        # 鎻愬彇浣滆€?(div.user > a > span)
        user_div = card.find("div", class_="user")
        if user_div:
            user_link = user_div.find("a")
            if user_link:
                user_span = user_link.find("span")
                if user_span:
                    video_data["author"] = user_span.get_text(strip=True)

        videos.append(video_data)

    print(f"  浠?{page_url} 鎵惧埌 {len(videos)} 涓棰?)
    return videos


def fetch_page(client: httpx.Client, url: str) -> BeautifulSoup | None:
    try:
        resp = client.get(url, headers=HEADERS, timeout=30, follow_redirects=True)
        resp.raise_for_status()
        return BeautifulSoup(resp.text, "lxml")
    except Exception as e:
        print(f"  [ERROR] 鎶撳彇澶辫触 {url}: {e}")
        return None


# ========== 璋冭瘯妯″紡 ==========

def debug_page(url: str):
    print(f"\n[DEBUG] 姝ｅ湪涓嬭浇椤甸潰: {url}")
    client = httpx.Client(http2=True)
    try:
        resp = client.get(url, headers=HEADERS, timeout=30, follow_redirects=True)
        soup = BeautifulSoup(resp.text, "lxml")

        debug_file = "debug_page.html"
        with open(debug_file, "w", encoding="utf-8") as f:
            f.write(soup.prettify())
        print(f"[DEBUG] HTML 宸蹭繚瀛樺埌 {debug_file}")

        print(f"[DEBUG] 椤甸潰鏍囬: {soup.title.string if soup.title else 'N/A'}")
        print(f"[DEBUG] 閾炬帴鎬绘暟: {len(soup.find_all('a'))}")
        print(f"[DEBUG] 鍥剧墖鎬绘暟: {len(soup.find_all('img'))}")
        print(f"[DEBUG] 瑙嗛鏍囩鏁? {len(soup.find_all('video'))}")

        v_links = soup.find_all("a", href=re.compile(r"/v\d+"))
        print(f"[DEBUG] /v{{id}} 鏍煎紡閾炬帴鏁? {len(v_links)}")
        for link in v_links[:5]:
            print(f"  - {link.get('href')}: {link.get_text(strip=True)[:80]}")

        all_classes = set()
        for tag in soup.find_all(True):
            if tag.get("class"):
                all_classes.update(tag["class"])
        print(f"[DEBUG] 椤甸潰 CSS class (鍓?0): {sorted(list(all_classes))[:30]}")

    except Exception as e:
        print(f"[DEBUG] 涓嬭浇澶辫触: {e}")
    finally:
        client.close()


# ========== 涓绘祦绋?==========

def scrape_all() -> dict:
    stats = {"pages_crawled": 0, "videos_found": 0, "videos_saved": 0, "errors": []}

    client = httpx.Client(http2=True, timeout=30)
    try:
        for page_path in TARGET_PAGES:
            url = urljoin(BASE_URL, page_path)
            print(f"\n[鎶撳彇] {url}")

            soup = fetch_page(client, url)
            if not soup:
                stats["errors"].append(f"椤甸潰鎶撳彇澶辫触: {url}")
                continue

            stats["pages_crawled"] += 1

            videos = find_video_cards(soup, url)
            for v in videos:
                v["source_page"] = url

            if len(videos) > MAX_VIDEOS_PER_PAGE:
                videos = videos[:MAX_VIDEOS_PER_PAGE]

            stats["videos_found"] += len(videos)

            if videos:
                saved = save_videos(videos)
                stats["videos_saved"] += saved
                print(f"  宸蹭繚瀛?{saved} 鏉″埌 Supabase")

            time.sleep(REQUEST_DELAY)

    except Exception as e:
        stats["errors"].append(str(e))
        print(f"[ERROR] {e}")
    finally:
        client.close()

    return stats


# ========== 鍏ュ彛 ==========

def main():
    debug = "--debug" in sys.argv

    if debug:
        print("=" * 50)
        print("璋冭瘯妯″紡: 鍒嗘瀽 monsnode.com 椤甸潰缁撴瀯")
        print("=" * 50)
        for page_path in TARGET_PAGES:
            debug_page(urljoin(BASE_URL, page_path))
        return

    if not SUPABASE_URL or not SUPABASE_KEY:
        print("[ERROR] 璇疯缃幆澧冨彉閲?SUPABASE_URL 鍜?SUPABASE_KEY")
        print("  $env:SUPABASE_URL = \"https://xxx.supabase.co\"")
        print("  $env:SUPABASE_KEY = \"your_service_role_key\"")
        sys.exit(1)

    print("=" * 50)
    print(f"monsnode 鐖櫕鍚姩 - {datetime.now().isoformat()}")
    print("=" * 50)

    stats = scrape_all()

    print("\n" + "=" * 50)
    print("鎶撳彇瀹屾垚!")
    print(f"  鎶撳彇椤甸潰鏁? {stats['pages_crawled']}")
    print(f"  鍙戠幇瑙嗛鏁? {stats['videos_found']}")
    print(f"  淇濆瓨瑙嗛鏁? {stats['videos_saved']}")
    if stats["errors"]:
        print(f"  閿欒: {stats['errors']}")
    print("=" * 50)


if __name__ == "__main__":
    main()

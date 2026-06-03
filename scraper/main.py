"""
monsnode.com 视频爬虫
从 monsnode 抓取视频封面、视频链接，存入 Supabase 数据库
每天定时运行一次
使用 Supabase REST API 直接操作，无需 SDK
"""

import os
import re
import time
import sys
from datetime import datetime, timezone
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup

# ========== 配置 ==========

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
    """构建 Supabase REST API 请求头"""
    return {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
    }


def save_videos(videos: list[dict]) -> int:
    """通过 REST API 批量 upsert 视频数据"""
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
    # upsert 模式: 冲突时合并
    api_headers["Prefer"] = "resolution=merge-duplicates"

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
                    print(f"  [ERROR] API 返回 {resp.status_code}: {resp.text[:200]}")
                    # 逐条重试
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
                                print(f"  [ERROR] 单条写入失败 {rec['video_id']}: {r.status_code}")
                        except Exception as e2:
                            print(f"  [ERROR] 单条写入异常 {rec['video_id']}: {e2}")
            except Exception as e:
                print(f"  [ERROR] 批次写入失败: {e}")
    finally:
        client.close()

    return saved


# ========== 数据提取逻辑 ==========

def extract_video_id(url: str) -> str | None:
    match = re.search(r"(v\d{15,25})", url)
    return match.group(1) if match else None


def find_video_cards(soup: BeautifulSoup, page_url: str) -> list[dict]:
    """解析 monsnode 页面结构，提取视频卡片数据
    页面结构: div.listn[id=视频ID] > a[href=redirect] > img[src][alt]
                          > div.user > a[href=/v{id}] > span (作者)
    """
    videos = []
    seen_ids = set()

    # 直接匹配 div.listn 卡片
    cards = soup.find_all("div", class_="listn")
    for card in cards:
        # 视频 ID 来自 div.listn 的 id 属性
        card_id = card.get("id", "").strip()
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

        # 提取封面图和标题 (img 标签在 a 标签内)
        img = card.find("img")
        if img:
            src = img.get("src", "")
            if src:
                video_data["thumbnail"] = urljoin(BASE_URL, src)
            alt = img.get("alt", "").strip()
            if alt:
                # alt 可能包含多行，取第一行作为标题
                video_data["title"] = alt.split("\n")[0].strip()[:500]

        # 提取作者 (div.user > a > span)
        user_div = card.find("div", class_="user")
        if user_div:
            user_link = user_div.find("a")
            if user_link:
                user_span = user_link.find("span")
                if user_span:
                    video_data["author"] = user_span.get_text(strip=True)

        videos.append(video_data)

    print(f"  从 {page_url} 找到 {len(videos)} 个视频")
    return videos


def fetch_page(client: httpx.Client, url: str) -> BeautifulSoup | None:
    try:
        resp = client.get(url, headers=HEADERS, timeout=30, follow_redirects=True)
        resp.raise_for_status()
        return BeautifulSoup(resp.text, "lxml")
    except Exception as e:
        print(f"  [ERROR] 抓取失败 {url}: {e}")
        return None


# ========== 调试模式 ==========

def debug_page(url: str):
    print(f"\n[DEBUG] 正在下载页面: {url}")
    client = httpx.Client(http2=True)
    try:
        resp = client.get(url, headers=HEADERS, timeout=30, follow_redirects=True)
        soup = BeautifulSoup(resp.text, "lxml")

        debug_file = "debug_page.html"
        with open(debug_file, "w", encoding="utf-8") as f:
            f.write(soup.prettify())
        print(f"[DEBUG] HTML 已保存到 {debug_file}")

        print(f"[DEBUG] 页面标题: {soup.title.string if soup.title else 'N/A'}")
        print(f"[DEBUG] 链接总数: {len(soup.find_all('a'))}")
        print(f"[DEBUG] 图片总数: {len(soup.find_all('img'))}")
        print(f"[DEBUG] 视频标签数: {len(soup.find_all('video'))}")

        v_links = soup.find_all("a", href=re.compile(r"/v\d+"))
        print(f"[DEBUG] /v{{id}} 格式链接数: {len(v_links)}")
        for link in v_links[:5]:
            print(f"  - {link.get('href')}: {link.get_text(strip=True)[:80]}")

        all_classes = set()
        for tag in soup.find_all(True):
            if tag.get("class"):
                all_classes.update(tag["class"])
        print(f"[DEBUG] 页面 CSS class (前30): {sorted(list(all_classes))[:30]}")

    except Exception as e:
        print(f"[DEBUG] 下载失败: {e}")
    finally:
        client.close()


# ========== 主流程 ==========

def scrape_all() -> dict:
    stats = {"pages_crawled": 0, "videos_found": 0, "videos_saved": 0, "errors": []}

    client = httpx.Client(http2=True, timeout=30)
    try:
        for page_path in TARGET_PAGES:
            url = urljoin(BASE_URL, page_path)
            print(f"\n[抓取] {url}")

            soup = fetch_page(client, url)
            if not soup:
                stats["errors"].append(f"页面抓取失败: {url}")
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
                print(f"  已保存 {saved} 条到 Supabase")

            time.sleep(REQUEST_DELAY)

    except Exception as e:
        stats["errors"].append(str(e))
        print(f"[ERROR] {e}")
    finally:
        client.close()

    return stats


# ========== 入口 ==========

def main():
    debug = "--debug" in sys.argv

    if debug:
        print("=" * 50)
        print("调试模式: 分析 monsnode.com 页面结构")
        print("=" * 50)
        for page_path in TARGET_PAGES:
            debug_page(urljoin(BASE_URL, page_path))
        return

    if not SUPABASE_URL or not SUPABASE_KEY:
        print("[ERROR] 请设置环境变量 SUPABASE_URL 和 SUPABASE_KEY")
        print("  $env:SUPABASE_URL = \"https://xxx.supabase.co\"")
        print("  $env:SUPABASE_KEY = \"your_service_role_key\"")
        sys.exit(1)

    print("=" * 50)
    print(f"monsnode 爬虫启动 - {datetime.now().isoformat()}")
    print("=" * 50)

    stats = scrape_all()

    print("\n" + "=" * 50)
    print("抓取完成!")
    print(f"  抓取页面数: {stats['pages_crawled']}")
    print(f"  发现视频数: {stats['videos_found']}")
    print(f"  保存视频数: {stats['videos_saved']}")
    if stats["errors"]:
        print(f"  错误: {stats['errors']}")
    print("=" * 50)


if __name__ == "__main__":
    main()

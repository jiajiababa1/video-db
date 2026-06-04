"""
monsnode.com 视频爬虫 v3
- 抓取多时间段页面（24小时/3天/7天/热门/推荐/最新/排行）
- 正确提取视频ID、缩略图、标题、作者、redirect编号
- 指数退避重试 + 详细日志
- 通过 Supabase REST API 存入数据库
"""

import os
import re
import time
import sys
import json
import traceback
from datetime import datetime, timezone
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup

# ========== 配置 ==========

BASE_URL = "https://monsnode.com"

# (路径, 标签, 抓取页数)
TARGET_SECTIONS = [
    ("/?t=24h", "24h", 3),
    ("/?t=3d", "3d", 3),
    ("/?t=7d", "7d", 3),
    ("/trending", "trending", 3),
    ("/", "home", 3),
    ("/latest", "latest", 3),
    ("/?ranking=1", "ranking", 2),
]

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language": "ja,en-US;q=0.9,en;q=0.8,zh-CN;q=0.7,zh;q=0.6",
    "DNT": "1",
}

REQUEST_DELAY = 1.5
MAX_RETRIES = 3
MAX_VIDEOS_PER_SECTION = 200
BATCH_SIZE = 50

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")


# ========== 工具函数 ==========

def log(msg: str, level: str = "INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}")


def safe_get_text(el, default: str = "") -> str:
    return el.get_text(strip=True) if el else default


def build_page_url(base_url: str, page: int) -> str:
    """构建分页URL"""
    sep = "&" if "?" in base_url else "?"
    return f"{base_url}{sep}p={page}"


# ========== Supabase REST API ==========

def supabase_api_headers():
    return {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
    }


def save_videos(videos: list[dict]) -> int:
    """批量 upsert 视频数据到 Supabase"""
    if not videos:
        return 0

    now = datetime.now(timezone.utc).isoformat()
    records = []
    for v in videos:
        # redirect_url 存到 duration 字段 (monsnode列表页无时长信息, 复用该字段)
        redirect = v.get("redirect_url", "")
        records.append({
            "video_id": v["video_id"],
            "title": (v["title"][:500] if v["title"] else ""),
            "thumbnail_url": (v["thumbnail"][:1000] if v["thumbnail"] else ""),
            "video_url": (v["url"][:1000] if v["url"] else ""),
            "author": v.get("author", "")[:200],
            "duration": redirect[:50],  # 复用duration字段存储redirect_url
            "views": v.get("views", "")[:50],
            "source_page": v.get("source_page", "")[:500],
            "source_section": v.get("source_section", "")[:50],
            "scraped_at": now,
            "updated_at": now,
        })

    headers = supabase_api_headers()
    headers["Prefer"] = "resolution=merge-duplicates"

    saved = 0
    client = httpx.Client(timeout=30)

    try:
        for i in range(0, len(records), BATCH_SIZE):
            batch = records[i:i + BATCH_SIZE]
            for attempt in range(1, MAX_RETRIES + 1):
                try:
                    resp = client.post(
                        SUPABASE_URL + "/rest/v1/videos",
                        headers=headers,
                        json=batch,
                    )
                    if resp.status_code in (200, 201):
                        saved += len(batch)
                        break
                    elif resp.status_code == 409:
                        ok = 0
                        for rec in batch:
                            try:
                                inner = client.post(
                                    SUPABASE_URL + "/rest/v1/videos",
                                    headers=headers,
                                    json=[rec],
                                )
                                if inner.status_code in (200, 201):
                                    ok += 1
                                else:
                                    log(f"单条写入失败 {rec['video_id']}: {inner.status_code}", "WARN")
                            except Exception as e2:
                                log(f"单条写入异常 {rec['video_id']}: {e2}", "WARN")
                        saved += ok
                        break
                    else:
                        log(f"API 返回 {resp.status_code}: {resp.text[:200]} (尝试 {attempt}/{MAX_RETRIES})", "WARN")
                        if attempt < MAX_RETRIES:
                            time.sleep(2 ** attempt)
                except Exception as e:
                    log(f"批次写入异常: {e} (尝试 {attempt}/{MAX_RETRIES})", "WARN")
                    if attempt < MAX_RETRIES:
                        time.sleep(2 ** attempt)
    finally:
        client.close()

    return saved


# ========== 页面抓取 ==========

def fetch_with_retry(client: httpx.Client, url: str, max_retries: int = MAX_RETRIES) -> BeautifulSoup | None:
    """带重试的页面抓取"""
    for attempt in range(1, max_retries + 1):
        try:
            resp = client.get(url, headers=HEADERS, timeout=30, follow_redirects=True)
            resp.raise_for_status()
            return BeautifulSoup(resp.text, "lxml")
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 429:
                wait = 30 * attempt
                log(f"触发限流 (429)，等待 {wait}s...", "WARN")
                time.sleep(wait)
            elif e.response.status_code >= 500:
                log(f"服务器错误 {e.response.status_code} (尝试 {attempt}/{max_retries})", "WARN")
                time.sleep(2 ** attempt)
            else:
                log(f"HTTP {e.response.status_code}: {url}", "ERROR")
                return None
        except Exception as e:
            log(f"抓取失败 {url}: {e} (尝试 {attempt}/{max_retries})", "WARN")
            if attempt < max_retries:
                time.sleep(2 ** attempt)
    return None


def find_video_cards(soup: BeautifulSoup, page_url: str, section: str) -> list[dict]:
    """解析 monsnode 页面，提取视频卡片"""
    videos = []
    seen_ids = set()

    # 找到所有 listn 卡片
    cards = soup.find_all("div", class_="listn")
    log(f"  找到 {len(cards)} 个卡片")

    for card in cards:
        card_id = card.get("id", "").strip()
        if not card_id or not card_id.isdigit():
            continue

        vid = "v" + card_id
        if vid in seen_ids:
            continue
        seen_ids.add(vid)

        # 查找缩略图和 redirect 链接
        img_link = card.find("a")
        redirect_num = ""
        redirect_url = ""
        thumbnail = ""
        title = ""

        if img_link:
            href = img_link.get("href", "")
            # 提取 redirect.php?v=NUMBER 中的数字
            m = re.search(r"redirect\.php\?v=(\d+)", href)
            if m:
                redirect_num = m.group(1)
                redirect_url = urljoin(BASE_URL, f"redirect.php?v={redirect_num}")

            # 提取缩略图
            img = img_link.find("img")
            if img:
                src = img.get("src", "")
                if src:
                    thumbnail = src  # Twitter CDN 完整URL，不需要 urljoin
                alt = img.get("alt", "").strip()
                if alt:
                    lines = [l.strip() for l in alt.split("\n") if l.strip()]
                    title = lines[0][:500] if lines else ""

        # 如果 thumbnail 是相对路径才需要 urljoin
        if thumbnail and not thumbnail.startswith("http"):
            thumbnail = urljoin(BASE_URL, thumbnail)

        # 提取作者
        author = ""
        user_div = card.find("div", class_="user")
        if user_div:
            user_link = user_div.find("a")
            if user_link:
                user_span = user_link.find("span")
                if user_span:
                    author = user_span.get_text(strip=True)

        # 视频详情页 URL
        video_url = urljoin(BASE_URL, "/" + vid)

        video_data = {
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
        }

        videos.append(video_data)

    return videos


# ========== 主流程 ==========

def scrape_all() -> dict:
    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0,
        "pages_crawled": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "errors": [],
    }

    client = httpx.Client(http2=True, timeout=30)

    try:
        for path, label, max_pages in TARGET_SECTIONS:
            section_url = urljoin(BASE_URL, path)
            all_section_videos = []

            log(f"[{label}] 开始抓取: {section_url}")

            for page in range(1, max_pages + 1):
                url = section_url if page == 1 else build_page_url(section_url, page)
                if page > 1:
                    log(f"[{label}] 第 {page} 页: {url}")

                soup = fetch_with_retry(client, url)
                if not soup:
                    if page == 1:
                        stats["errors"].append(f"首页抓取失败: {url}")
                        break
                    else:
                        log(f"[{label}] 第 {page} 页抓取失败，停止翻页", "WARN")
                        break

                stats["pages_crawled"] += 1
                videos = find_video_cards(soup, url, label)

                if not videos:
                    log(f"[{label}] 第 {page} 页无视频，停止翻页")
                    break

                # 检查是否有新视频（去重）
                existing_ids = {v["video_id"] for v in all_section_videos}
                new_videos = [v for v in videos if v["video_id"] not in existing_ids]
                if not new_videos and page > 1:
                    log(f"[{label}] 第 {page} 页都是重复视频，停止翻页")
                    break

                all_section_videos.extend(new_videos)

                if len(all_section_videos) >= MAX_VIDEOS_PER_SECTION:
                    log(f"[{label}] 已达单 section 上限 {MAX_VIDEOS_PER_SECTION}，停止翻页")
                    break

                time.sleep(REQUEST_DELAY)

            stats["sections_crawled"] += 1
            stats["videos_found"] += len(all_section_videos)
            log(f"[{label}] 共找到 {len(all_section_videos)} 个视频 ({stats['pages_crawled']} 页)")

            if all_section_videos:
                saved = save_videos(all_section_videos)
                stats["videos_saved"] += saved
                log(f"[{label}] 已保存 {saved} 条")

            time.sleep(REQUEST_DELAY)

        _save_scrape_status(stats)

    except Exception as e:
        stats["errors"].append(str(e))
        log(f"主流程异常: {e}\n{traceback.format_exc()}", "ERROR")
    finally:
        client.close()

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    return stats


def _save_scrape_status(stats: dict):
    """记录爬虫运行状态到 Supabase"""
    if not SUPABASE_URL or not SUPABASE_KEY:
        return
    try:
        headers = supabase_api_headers()
        body = {
            "last_run": stats["finished_at"],
            "videos_saved": stats["videos_saved"],
            "videos_found": stats["videos_found"],
            "pages_crawled": stats["pages_crawled"],
            "errors": json.dumps(stats["errors"][:5]) if stats["errors"] else "",
        }
        client = httpx.Client(timeout=10)
        try:
            client.post(SUPABASE_URL + "/rest/v1/scrape_status", headers=headers, json=body)
        finally:
            client.close()
    except Exception:
        pass


# ========== 入口 ==========

def main():
    if not SUPABASE_URL or not SUPABASE_KEY:
        log("请设置环境变量 SUPABASE_URL 和 SUPABASE_KEY", "ERROR")
        print("  $env:SUPABASE_URL = \"https://xxx.supabase.co\"")
        print("  $env:SUPABASE_KEY = \"your_service_role_key\"")
        sys.exit(1)

    print("=" * 55)
    log("monsnode 爬虫 v3 启动")
    print("=" * 55)

    stats = scrape_all()

    print("\n" + "=" * 55)
    print("  抓取完成!")
    print(f"  抓取 section 数: {stats['sections_crawled']}")
    print(f"  抓取页面数:     {stats['pages_crawled']}")
    print(f"  发现视频数:     {stats['videos_found']}")
    print(f"  保存视频数:     {stats['videos_saved']}")
    if stats["errors"]:
        print(f"  错误数:         {len(stats['errors'])}")
        for e in stats["errors"][:5]:
            print(f"    - {e[:120]}")
    print("=" * 55)


if __name__ == "__main__":
    main()

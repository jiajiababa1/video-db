"""
monsnode.com 视频爬虫 v2
- 抓取多个页面的多页数据
- 提取更多元数据（播放量、时长等）
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
from urllib.parse import urljoin, urlparse, parse_qs

import httpx
from bs4 import BeautifulSoup

# ========== 配置 ==========

BASE_URL = "https://monsnode.com"
TARGET_SECTIONS = [
    # (路径, 标签, 抓取页数)
    ("/trending", "trending", 3),
    ("/", "home", 3),
    ("/latest", "latest", 3),
]

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language": "ja,en-US;q=0.9,en;q=0.8,zh-CN;q=0.7,zh;q=0.6",
    "DNT": "1",
}

REQUEST_DELAY = 1.5
MAX_RETRIES = 3
MAX_VIDEOS_PER_SECTION = 300
BATCH_SIZE = 50
DETAIL_PAGE_RATIO = 0.05  # 只抓取 5% 视频的详情页 (避免请求过多)

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")


# ========== 工具函数 ==========

def log(msg: str, level: str = "INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}")


def safe_get_text(el, default: str = "") -> str:
    return el.get_text(strip=True) if el else default


def extract_video_id(raw: str) -> str | None:
    """从 URL 或文本中提取视频 ID"""
    m = re.search(r"(?:v)?(\d{15,25})", raw)
    return "v" + m.group(1) if m else None


def parse_count(text: str) -> int:
    """解析可能带单位的数字: 1.2K -> 1200, 3.4M -> 3400000"""
    if not text:
        return 0
    text = text.strip().upper().replace(",", "").replace(" ", "")
    try:
        if "K" in text:
            return int(float(text.replace("K", "")) * 1000)
        if "M" in text:
            return int(float(text.replace("M", "")) * 1000000)
        return int(float(text))
    except (ValueError, TypeError):
        return 0


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
        records.append({
            "video_id": v["video_id"],
            "title": (v["title"][:500] if v["title"] else ""),
            "thumbnail_url": (v["thumbnail"][:1000] if v["thumbnail"] else ""),
            "video_url": (v["url"][:1000] if v["url"] else ""),
            "author": v.get("author", "")[:200],
            "duration": v.get("duration", "")[:50],
            "views": str(v.get("views", ""))[:50],
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
                        # 冲突，逐条 upsert
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
                                    log(f"单条写入失败 {rec['video_id']}: {inner.status_code} {inner.text[:100]}", "WARN")
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


def scrape_video_detail(client: httpx.Client, video_id: str) -> dict:
    """抓取单个视频详情页，获取额外元数据"""
    detail = {}
    url = urljoin(BASE_URL, "/" + video_id)
    soup = fetch_with_retry(client, url)
    if not soup:
        return detail

    # 尝试从详情页提取播放量和时长
    # monsnode 详情页结构可能包含更多信息
    for script in soup.find_all("script"):
        text = script.get_text(strip=True)
        if "views" in text.lower() or "count" in text.lower():
            # 尝试提取 JSON 数据
            pass

    # 提取描述
    desc_el = soup.find("meta", attrs={"name": "description"}) or soup.find("meta", attrs={"property": "og:description"})
    if desc_el:
        detail["description"] = desc_el.get("content", "")[:1000]

    return detail


def find_video_cards(soup: BeautifulSoup, page_url: str, section: str) -> list[dict]:
    """解析 monsnode 页面，提取视频卡片"""
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

        video_data = {
            "video_id": vid,
            "url": urljoin(BASE_URL, "/" + vid),
            "title": "",
            "thumbnail": "",
            "author": "",
            "duration": "",
            "views": 0,
            "source_section": section,
            "source_page": page_url,
        }

        # 封面图 + alt 标题
        img = card.find("img")
        if img:
            src = img.get("src", "")
            if src:
                video_data["thumbnail"] = urljoin(BASE_URL, src)
            alt = img.get("alt", "").strip()
            if alt:
                # alt 第一行是标题，后面可能是其他信息
                lines = [l.strip() for l in alt.split("\n") if l.strip()]
                video_data["title"] = lines[0][:500] if lines else ""

                # 尝试从 alt 文本中提取时长和播放量
                for line in lines[1:]:
                    # 时长格式: "2:30" 或 "1h23m"
                    dur_match = re.search(r'(\d+:\d+|\d+h\d+m|\d+min|\d+sec)', line, re.IGNORECASE)
                    if dur_match and not video_data["duration"]:
                        video_data["duration"] = dur_match.group(1)
                    # 播放量格式: "1.2K views" 等
                    views_match = re.search(r'([\d,.]+[KkMm]?\s*(?:views|回|再生|view))', line, re.IGNORECASE)
                    if views_match and not video_data["views"]:
                        num = re.search(r'[\d,.]+[KkMm]?', views_match.group(1))
                        if num:
                            video_data["views"] = parse_count(num.group())

        # 作者
        user_div = card.find("div", class_="user")
        if user_div:
            user_link = user_div.find("a")
            if user_link:
                user_span = user_link.find("span")
                if user_span:
                    video_data["author"] = user_span.get_text(strip=True)

        # up/down vote 计数
        vote_div = card.find("div", class_="vote")
        if vote_div:
            up_link = vote_div.find("a", class_="up")
            if up_link:
                up_text = safe_get_text(up_link.find("span"))
                up_count = re.search(r'(\d+)', up_text)
                if up_count:
                    video_data["upvotes"] = int(up_count.group(1))

        videos.append(video_data)

    return videos


# ========== 调试模式 ==========

def debug_site():
    """分析 monsnode 页面结构"""
    client = httpx.Client(http2=True)
    try:
        for path, label, _ in TARGET_SECTIONS:
            url = urljoin(BASE_URL, path)
            log(f"分析页面: {url}")
            soup = fetch_with_retry(client, url)
            if not soup:
                continue

            fname = f"debug_{label}.html"
            with open(fname, "w", encoding="utf-8") as f:
                f.write(soup.prettify())
            log(f"HTML 已保存到 {fname}")

            # 统计
            cards = soup.find_all("div", class_="listn")
            log(f"  视频卡片数: {len(cards)}")
            imgs = soup.find_all("img")
            log(f"  图片总数: {len(imgs)}")
            links = soup.find_all("a")
            log(f"  链接总数: {len(links)}")

            # CSS class 列表
            classes = set()
            for tag in soup.find_all(True):
                if tag.get("class"):
                    classes.update(tag["class"])
            log(f"  CSS classes (前30): {sorted(classes)[:30]}")

            # 检测分页
            pager = soup.find_all("a", href=re.compile(r"[?&]p(?:age)?=\d+"))
            log(f"  分页链接数: {len(pager)}")
            for p in pager[:5]:
                log(f"    分页: {p.get('href')}")

    finally:
        client.close()


# ========== 构建分页 URL ==========

def build_page_url(base_url: str, page: int) -> str:
    """构建分页 URL: monsnode 可能使用 ?p=N 或 ?page=N"""
    if "?" in base_url:
        return base_url + "&p=" + str(page)
    else:
        return base_url + "?p=" + str(page)


# ========== 主流程 ==========

def scrape_all() -> dict:
    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0,
        "pages_crawled": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "errors": [],
        "details_scraped": 0,
    }

    client = httpx.Client(http2=True, timeout=30)

    try:
        # 遍历每个 section
        for path, label, max_pages in TARGET_SECTIONS:
            section_url = urljoin(BASE_URL, path)
            all_section_videos = []

            # 分页抓取
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

                all_section_videos.extend(videos)

                if len(all_section_videos) >= MAX_VIDEOS_PER_SECTION:
                    log(f"[{label}] 已达单 section 上限 {MAX_VIDEOS_PER_SECTION}，停止翻页")
                    break

                time.sleep(REQUEST_DELAY)

            stats["sections_crawled"] += 1
            stats["videos_found"] += len(all_section_videos)
            log(f"[{label}] 共找到 {len(all_section_videos)} 个视频 ({stats['pages_crawled']} 页)")

            # 批量保存
            if all_section_videos:
                saved = save_videos(all_section_videos)
                stats["videos_saved"] += saved
                log(f"[{label}] 已保存 {saved} 条")

            # 选择性抓取部分视频详情页
            detail_count = max(1, int(len(all_section_videos) * DETAIL_PAGE_RATIO))
            for v in all_section_videos[:detail_count]:
                try:
                    extra = scrape_video_detail(client, v["video_id"])
                    if extra:
                        stats["details_scraped"] += 1
                except Exception:
                    pass
                time.sleep(0.3)

            time.sleep(REQUEST_DELAY)

        # 记录最后抓取时间到 Supabase
        _save_scrape_status(stats)

    except Exception as e:
        stats["errors"].append(str(e))
        log(f"主流程异常: {e}\n{traceback.format_exc()}", "ERROR")
    finally:
        client.close()

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    return stats


def _save_scrape_status(stats: dict):
    """记录爬虫运行状态到 Supabase (可选的状态表)"""
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
        pass  # 状态表可能不存在，忽略


# ========== 入口 ==========

def main():
    if "--debug" in sys.argv:
        print("=" * 50)
        print("调试模式: 分析 monsnode.com 页面结构")
        print("=" * 50)
        debug_site()
        return

    if "--test-detail" in sys.argv:
        # 测试单个详情页抓取
        test_id = sys.argv[sys.argv.index("--test-detail") + 1] if len(sys.argv) > sys.argv.index("--test-detail") + 1 else "v2025628151007881956"
        client = httpx.Client(http2=True)
        try:
            detail = scrape_video_detail(client, test_id)
            log(f"详情页结果: {json.dumps(detail, indent=2, ensure_ascii=False)}")
        finally:
            client.close()
        return

    if not SUPABASE_URL or not SUPABASE_KEY:
        log("请设置环境变量 SUPABASE_URL 和 SUPABASE_KEY", "ERROR")
        print("  $env:SUPABASE_URL = \"https://xxx.supabase.co\"")
        print("  $env:SUPABASE_KEY = \"your_service_role_key\"")
        sys.exit(1)

    print("=" * 55)
    log(f"monsnode 爬虫 v2 启动")
    print("=" * 55)

    stats = scrape_all()

    print("\n" + "=" * 55)
    print("  抓取完成!")
    print(f"  抓取 section 数: {stats['sections_crawled']}")
    print(f"  抓取页面数:     {stats['pages_crawled']}")
    print(f"  发现视频数:     {stats['videos_found']}")
    print(f"  保存视频数:     {stats['videos_saved']}")
    if stats.get("details_scraped"):
        print(f"  详情页抓取:     {stats['details_scraped']}")
    if stats["errors"]:
        print(f"  错误数:         {len(stats['errors'])}")
        for e in stats["errors"][:5]:
            print(f"    - {e[:120]}")
    print(f"  耗时:           {stats.get('finished_at', '?')}")
    print("=" * 55)


if __name__ == "__main__":
    main()

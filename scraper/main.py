"""
monsnode 爬虫 v5 — 全浏览器方案
  Playwright 负责所有 monsnode 请求 (利用浏览器 Cloudflare 通行证)
  twjn.php MP4 解析在浏览器中通过 JS fetch 并发执行
  Supabase 保存通过 httpx
  适用: 任何 IP (含 GitHub Actions 数据中心)
"""
import os, sys, time, asyncio, json
from datetime import datetime, timezone
from urllib.parse import urljoin
import httpx

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

MAX_VIDEOS_PER_SECTION = 300
BATCH_SIZE = 100
MP4_BROWSER_CONCURRENCY = 15  # 浏览器内并发 fetch 数 (一次 eval 的并发量)
MP4_BROWSER_BATCH = 50        # 每批处理多少个视频

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").strip()
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "").strip()


def log(msg: str, level: str = "INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


def build_page_url(base_url: str, page: int) -> str:
    sep = "&" if "?" in base_url else "?"
    return f"{base_url}{sep}p={page}"


# ========== 浏览器内 JS 函数 (发送给 page.evaluate 执行) ==========

EXTRACT_CARDS_JS = """
() => {
    const cards = document.querySelectorAll('div.listn');
    const results = [];
    for (const card of cards) {
        const id = card.getAttribute('id') || '';
        if (!id || !/^\\d+$/.test(id)) continue;
        const vid = 'v' + id;
        const a = card.querySelector('a');
        let href = '';
        let monsnodeId = '';
        if (a) {
            href = a.getAttribute('href') || '';
            const m = href.match(/redirect\\.php\\?v=(\\d+)/);
            if (m) monsnodeId = m[1];
        }
        const img = card.querySelector('img');
        const thumbnail = img ? (img.getAttribute('src') || '') : '';
        const title = img ? (img.getAttribute('alt') || '').split('\\n')[0].trim().substring(0, 500) : '';
        const userEl = card.querySelector('.user span, .user a');
        const author = userEl ? userEl.textContent.trim().substring(0, 200) : '';
        const viewEl = card.querySelector('.view, .views, .count, .like, .heart, .point');
        let views = '';
        if (viewEl) {
            const m = viewEl.textContent.match(/[\\d,]+/);
            if (m) views = m[0].replace(/,/g, '');
        }
        const durEl = card.querySelector('.time, .duration, .length, .dur');
        const durationLabel = durEl ? durEl.textContent.trim().substring(0, 20) : '';
        let rankNum = '';
        if (window.location.href.includes('ranking')) {
            const rankEl = card.querySelector('.rank, .number');
            if (rankEl) rankNum = rankEl.textContent.replace(/\\D/g, '');
        }
        results.push({
            video_id: vid,
            url: '/v' + id,
            monsnode_video_id: monsnodeId,
            title: title,
            thumbnail: thumbnail,
            author: author,
            duration: durationLabel,
            views: views,
            rank: rankNum
        });
    }
    return results;
}
"""

RESOLVE_MP4_JS = """
async (videoIds) => {
    const results = {};
    const fetchOne = async (id) => {
        try {
            const resp = await fetch('/twjn.php?v=' + id);
            const text = await resp.text();
            const match = text.match(/var\\s+u\\s*=\\s*atob\\('([^']+)'\\)/);
            if (match) {
                const mp4 = atob(match[1]);
                if (mp4.includes('video.twimg.com')) {
                    results[id] = mp4;
                }
            }
        } catch(e) {}
    };
    const chunks = [];
    for (let i = 0; i < videoIds.length; i += 50) {
        chunks.push(videoIds.slice(i, i + 50));
    }
    for (const chunk of chunks) {
        await Promise.all(chunk.map(fetchOne));
    }
    return results;
}
"""


# ========== Supabase 操作 ==========

def supabase_save(videos: list[dict]) -> int:
    """通过 RPC upsert_videos 批量 upsert"""
    if not videos:
        return 0
    now = datetime.now(timezone.utc).isoformat()
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
    }
    records = []
    for v in videos:
        mp4 = v.get("duration", "") or ""
        has_mp4 = bool(mp4 and mp4.startswith("http") and "video.twimg.com" in mp4)
        records.append({
            "video_id": v["video_id"],
            "title": (v["title"] or "")[:500],
            "thumbnail_url": (v["thumbnail"] or "")[:1000],
            "video_url": urljoin(BASE_URL, v.get("url", ""))[:1000],
            "author": (v.get("author") or "")[:200],
            "duration": mp4[:500] if has_mp4 else "",
            "views": (v.get("views") or "")[:50],
            "monsnode_video_id": (v.get("monsnode_video_id") or "")[:50],
            "source_page": (v.get("source_page") or "")[:500],
            "source_section": (v.get("source_section") or "")[:50],
            "scraped_at": now,
            "has_mp4": has_mp4,
            "needs_rescrape": not has_mp4,
            "mp4_checked_at": now,
        })

    saved = 0
    client = httpx.Client(timeout=60)
    rpc_url = SUPABASE_URL + "/rest/v1/rpc/upsert_videos"

    for i in range(0, len(records), BATCH_SIZE):
        batch = records[i:i + BATCH_SIZE]
        try:
            resp = client.post(rpc_url, headers=headers, json={"videos": batch})
            if resp.status_code in (200, 201, 204):
                saved += len(batch)
            else:
                # 逐条重试
                for rec in batch:
                    try:
                        r = client.post(rpc_url, headers=headers, json={"videos": [rec]})
                        if r.status_code in (200, 201, 204):
                            saved += 1
                    except Exception:
                        pass
        except Exception:
            for rec in batch:
                try:
                    r = client.post(rpc_url, headers=headers, json={"videos": [rec]})
                    if r.status_code in (200, 201, 204):
                        saved += 1
                except Exception:
                    pass
    client.close()
    return saved


# ========== 主流程 ==========

async def scrape_all():
    """全浏览器爬取: Playwright 页面 → JS 提取卡片 → JS 并发解析 MP4 → Supabase"""
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

    pw = await async_playwright().start()
    browser = await pw.chromium.launch(
        headless=True,
        args=[
            "--no-sandbox", "--disable-setuid-sandbox",
            "--disable-dev-shm-usage", "--disable-gpu",
            "--disable-blink-features=AutomationControlled",
            "--no-first-run", "--no-default-browser-check",
            "--mute-audio",
        ]
    )
    context = await browser.new_context(
        user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        viewport={"width": 1366, "height": 768},
        locale="ja-JP",
        timezone_id="Asia/Tokyo",
        geolocation={"latitude": 35.6895, "longitude": 139.6917},
    )

    try:
        for path, label, max_pages in TARGET_SECTIONS:
            section_url = urljoin(BASE_URL, path)
            all_videos = []
            t0 = time.time()
            log(f"[{label}] {section_url}")

            page = await context.new_page()
            try:
                for page_num in range(1, max_pages + 1):
                    url = section_url if page_num == 1 else build_page_url(section_url, page_num)
                    try:
                        await page.goto(url, wait_until="domcontentloaded", timeout=45000)
                        # 等待视频卡片加载
                        try:
                            await page.wait_for_selector("div.listn", timeout=20000)
                        except Exception:
                            # 可能被 Cloudflare 挑战
                            content = await page.content()
                            if "challenges.cloudflare.com" in content or "お待ちください" in content:
                                log(f"  等待 Cloudflare 验证...")
                                await asyncio.sleep(20)
                        await asyncio.sleep(1)

                        # 用 JS 提取卡片数据 (比 BS4 快)
                        cards = await page.evaluate(EXTRACT_CARDS_JS)
                        cards = [c for c in cards if isinstance(c, dict) and c.get("video_id")]

                        stats["pages_crawled"] += 1
                        log(f"  第{page_num}页: {len(cards)} 个视频 ({time.time()-t0:.0f}s)")

                        if not cards:
                            break

                        existing = {v["video_id"] for v in all_videos}
                        new = [c for c in cards if c["video_id"] not in existing]
                        if not new and page_num > 1:
                            break

                        # 补充字段
                        for c in new:
                            c["source_section"] = label
                            c["source_page"] = url

                        all_videos.extend(new)

                        if len(all_videos) >= MAX_VIDEOS_PER_SECTION:
                            break

                        await asyncio.sleep(1)

                    except Exception as e:
                        log(f"  第{page_num}页失败: {str(e)[:60]}", "WARN")
                        if page_num == 1:
                            stats["errors"].append(f"{label}: {str(e)[:80]}")
                        break
            finally:
                await page.close()

            stats["sections_crawled"] += 1
            stats["videos_found"] += len(all_videos)
            elapsed = time.time() - t0
            log(f"[{label}] 共 {len(all_videos)} 个视频 ({elapsed:.0f}s)")

            if not all_videos:
                continue

            # MP4 解析: 在浏览器中通过 JS fetch 并发调 twjn.php
            # (利用浏览器的 Cloudflare 通行证, 从任何 IP 都能调通)
            t1 = time.time()
            mp4_urls = {}
            mp4_page = await context.new_page()
            try:
                # 先打开 monsnode 任意页面获取通行证
                await mp4_page.goto(BASE_URL + "/", wait_until="domcontentloaded", timeout=30000)
                await asyncio.sleep(2)

                targets = []
                for v in all_videos:
                    mid = v.get("monsnode_video_id", "").strip()
                    if mid and mid.isdigit():
                        targets.append(mid)

                log(f"  twjn.php 解析 {len(targets)} 个 (浏览器内并发)...")

                # 分批在浏览器中执行 JS fetch
                for batch_start in range(0, len(targets), MP4_BROWSER_BATCH):
                    batch = targets[batch_start:batch_start + MP4_BROWSER_BATCH]
                    batch_results = await mp4_page.evaluate(RESOLVE_MP4_JS, batch)
                    if batch_results:
                        mp4_urls.update(batch_results)
                    done = min(batch_start + MP4_BROWSER_BATCH, len(targets))
                    log(f"    {done}/{len(targets)} → {len(mp4_urls)} MP4")
            finally:
                await mp4_page.close()

            stats["mp4_resolved"] += len(mp4_urls)
            log(f"[{label}] MP4 解析: {len(mp4_urls)}/{len(all_videos)} ({time.time()-t1:.0f}s)")

            # 合并 MP4 结果
            for v in all_videos:
                mid = v.get("monsnode_video_id", "").strip()
                if mid in mp4_urls:
                    v["duration"] = mp4_urls[mid]

            # 保存
            t2 = time.time()
            saved = supabase_save(all_videos)
            stats["videos_saved"] += saved
            log(f"[{label}] 保存 {saved} ({time.time()-t2:.0f}s)")

        # 自动修复残留视频
        log("\n自动修复残留视频...")
        async with httpx.AsyncClient(timeout=30, limits=httpx.Limits(max_connections=50)) as client:
            auto_fixed = await auto_rescrape(client, limit=100)
            stats["auto_rescrape_count"] = auto_fixed

    finally:
        await context.close()
        await browser.close()
        await pw.stop()

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    return stats


# ========== 自动修复 ==========

async def auto_rescrape(client: httpx.AsyncClient | None = None, limit: int = 100) -> int:
    """修复数据库中 needs_rescrape=true 的视频 (使用浏览器 twjn.php)"""
    supabase_headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
    }

    # 查询需要修复的
    resp = httpx.get(
        SUPABASE_URL + "/rest/v1/videos"
        "?select=video_id,monsnode_video_id"
        "&needs_rescrape=eq.true"
        "&monsnode_video_id=not.eq."  # monsnode_id 不为空
        f"&limit={limit}",
        headers=supabase_headers,
        timeout=20
    )
    if resp.status_code != 200:
        return 0

    candidates = resp.json()
    targets = []
    for c in candidates:
        mid = (c.get("monsnode_video_id") or "").strip()
        if mid and mid.isdigit():
            targets.append((c["video_id"], mid))

    if not targets:
        log("  没有可修复的视频")
        return 0

    log(f"  发现 {len(targets)} 个待修复视频")

    # 用浏览器解析 MP4
    from playwright.async_api import async_playwright
    pw = await async_playwright().start()
    browser = await pw.chromium.launch(headless=True, args=["--no-sandbox", "--disable-gpu"])
    context = await browser.new_context(
        user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        locale="ja-JP", timezone_id="Asia/Tokyo",
    )
    page = await context.new_page()

    resolved = 0
    try:
        await page.goto(BASE_URL + "/", wait_until="domcontentloaded", timeout=30000)
        await asyncio.sleep(2)

        mids = [mid for _, mid in targets]
        vid_map = {mid: vid for vid, mid in targets}

        for batch_start in range(0, len(mids), MP4_BROWSER_BATCH):
            batch = mids[batch_start:batch_start + MP4_BROWSER_BATCH]
            batch_results = await page.evaluate(RESOLVE_MP4_JS, batch)
            if not batch_results:
                continue

            for mid, mp4 in batch_results.items():
                vid = vid_map.get(mid)
                if vid:
                    now = datetime.now(timezone.utc).isoformat()
                    data = {
                        "duration": mp4[:500],
                        "has_mp4": True,
                        "needs_rescrape": False,
                        "mp4_checked_at": now,
                        "updated_at": now,
                    }
                    try:
                        await client.patch(
                            SUPABASE_URL + f"/rest/v1/videos?video_id=eq.{vid}",
                            headers={**supabase_headers, "Content-Type": "application/json"},
                            json=data, timeout=15
                        )
                        resolved += 1
                    except Exception:
                        pass
            done = min(batch_start + MP4_BROWSER_BATCH, len(mids))
            log(f"  {done}/{len(mids)} → 修复 {resolved}")

    finally:
        await page.close()
        await context.close()
        await browser.close()
        await pw.stop()

    log(f"  自动修复: {resolved}/{len(targets)}")
    return resolved


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--rescrape", action="store_true", help="仅修复已存在的无 MP4 视频")
    args = parser.parse_args()

    print("=" * 55)
    mode = "自动修复" if args.rescrape else "全浏览器爬取"
    log(f"monsnode 爬虫 v5 — {mode}")
    log(f"SUPABASE_URL={'已设置' if SUPABASE_URL else '❌ 未设置'}")
    log(f"SUPABASE_KEY={'已设置' if SUPABASE_KEY else '❌ 未设置'}")
    if not SUPABASE_URL or not SUPABASE_KEY:
        log("请设置 SUPABASE_URL 和 SUPABASE_KEY 环境变量", "ERROR")
        sys.exit(1)
    print("=" * 55)

    if args.rescrape:
        async def _run():
            async with httpx.AsyncClient(timeout=30, limits=httpx.Limits(max_connections=50)) as client:
                await auto_rescrape(client, limit=500)
        asyncio.run(_run())
    else:
        stats = asyncio.run(scrape_all())
        print("\n" + "=" * 55)
        print(f"  板块: {stats['sections_crawled']}  页面: {stats['pages_crawled']}")
        print(f"  发现: {stats['videos_found']}  保存: {stats['videos_saved']}")
        rate = stats['mp4_resolved'] / max(stats['videos_found'], 1) * 100
        print(f"  MP4: {stats['mp4_resolved']} ({rate:.0f}%)")
        if stats.get("auto_rescrape_count"):
            print(f"  自动修复: {stats['auto_rescrape_count']}")
        if stats["errors"]:
            print(f"  错误: {len(stats['errors'])}")
            for e in stats["errors"][:3]:
                print(f"    - {e[:120]}")
        print("=" * 55)


if __name__ == "__main__":
    main()

"""
monsnode 爬虫 v7 — 全自动闭环
  - Playwright 真实导航访问列表页面 (像真人浏览)
  - MP4 解析: 多 tab 并发真实导航到 twjn.php 页面 (不是 JS fetch)
  - 所有请求都是真实页面导航, Cloudflare 不会拦截
  - Supabase 保存通过 httpx
"""
import os, sys, time, asyncio, re, base64, json
from datetime import datetime, timezone
from urllib.parse import urljoin
import httpx

BASE_URL = "https://monsnode.com"

TARGET_SECTIONS = [
    # 排名页 (带 period 参数) — 翻页用 page=N
    ("/?ranking=1&period=24h", "24h", 3, "ranking"),
    ("/?ranking=1&period=3d", "3d", 2, "ranking"),
    ("/?ranking=1&period=7d", "7d", 2, "ranking"),
    ("/?ranking=1", "ranking", 3, "ranking"),
    # 普通板块 — 翻页用 p=N
    ("/trending", "trending", 3, "normal"),
    ("/", "home", 2, "normal"),
    ("/latest", "latest", 3, "normal"),
]

# MP4 解析优先级: trending/latest 视频更可能还在线上
MP4_PRIORITY = ["trending", "latest", "home", "24h", "3d", "7d", "ranking"]

MAX_VIDEOS_PER_SECTION = 150
BATCH_SIZE = 100
MP4_TAB_CONCURRENCY = 3  # 降低并发避免 GitHub Actions 内存超限导致取消

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").strip().strip("'\"")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "").strip().strip("'\"").replace("\n", "").replace("\r", "")


def log(msg: str, level: str = "INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


def build_page_url(base_url: str, page: int, mode: str = "normal") -> str:
    """构建翻页 URL
    mode="ranking": 使用 page=N 参数 (排名页)
    mode="normal":  使用 p=N 参数 (普通板块)
    """
    if mode == "ranking":
        # 排名页第1页不加 page 参数, 第2页起加 page=N
        if page <= 1:
            return base_url
        sep = "&" if "?" in base_url else "?"
        return f"{base_url}{sep}page={page}"
    else:
        # 普通板块翻页: 加 p=N
        sep = "&" if "?" in base_url else "?"
        return f"{base_url}{sep}p={page}"


# ========== 浏览器提取卡片的 JS ==========

EXTRACT_CARDS_JS = """
() => {
    const cards = document.querySelectorAll('div.listn');
    const results = [];
    for (const card of cards) {
        const id = card.getAttribute('id') || '';
        if (!id || !/^[0-9]+$/.test(id)) continue;
        const vid = 'v' + id;
        const a = card.querySelector('a');
        let href = '';
        let monsnodeId = '';
        if (a) {
            href = a.getAttribute('href') || '';
            const m = href.match(/redirect\\.php\\?v=([0-9]+)/);
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
            const m = viewEl.textContent.match(/[0-9,]+/);
            if (m) views = m[0].replace(/,/g, '');
        }
        const durEl = card.querySelector('.time, .duration, .length, .dur');
        const durationLabel = durEl ? durEl.textContent.trim().substring(0, 20) : '';
        let rankNum = '';
        if (window.location.href.indexOf('ranking') !== -1) {
            const rankEl = card.querySelector('.rank, .number');
            if (rankEl) rankNum = rankEl.textContent.replace(/[^0-9]/g, '');
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


# ========== Supabase ==========

def supabase_fetch_failed(limit: int = 100) -> list[dict]:
    """查询 needs_rescrape=true 且有 monsnode_video_id 的视频"""
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
    }
    client = httpx.Client(timeout=30)
    try:
        url = (
            SUPABASE_URL + "/rest/v1/videos"
            "?select=video_id,monsnode_video_id"
            "&needs_rescrape=is.true"
            "&monsnode_video_id=not.is.null"
            "&order=created_at.desc"
            "&limit=" + str(limit)
        )
        resp = client.get(url, headers=headers)
        if resp.status_code == 200:
            return resp.json()
        return []
    except Exception as e:
        log(f"查询失败视频异常: {e}", "WARN")
        return []
    finally:
        client.close()


def supabase_update_mp4(updates: dict[str, str | None]) -> int:
    """批量更新视频 MP4: {monsnode_video_id: mp4_url_or_None}"""
    if not updates:
        return 0
    now = datetime.now(timezone.utc).isoformat()
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
    }
    saved = 0
    client = httpx.Client(timeout=30)
    for mid, mp4 in updates.items():
        video_id = "v" + mid
        has_mp4 = bool(mp4 and "video.twimg.com" in mp4)
        patch = {
            "mp4_checked_at": now,
            "has_mp4": has_mp4,           # 始终显式设置, 避免旧值残留
            "needs_rescrape": not has_mp4,
        }
        if has_mp4:
            patch["duration"] = mp4  # 不截断, Twitter MP4 URL 可能超过 500 字符
        try:
            resp = client.patch(
                SUPABASE_URL + "/rest/v1/videos?video_id=eq." + video_id,
                headers=headers,
                json=patch,
            )
            if resp.status_code in (200, 204):
                saved += 1
        except Exception:
            pass
    client.close()
    return saved


def supabase_save(videos: list[dict]) -> int:
    if not videos:
        return 0
    now = datetime.now(timezone.utc).isoformat()
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
    }

    # 合并同 video_id 的记录：拼接 source_section，保留最佳元数据
    merged = {}
    for v in videos:
        vid = v["video_id"]
        if vid not in merged:
            merged[vid] = dict(v)  # 浅拷贝
        else:
            existing = merged[vid]
            # 拼接 source_section (去重用管道符)
            new_sec = (v.get("source_section") or "")
            old_sec = (existing.get("source_section") or "")
            all_secs = [s.strip() for s in old_sec.split("|") if s.strip()]
            if new_sec and new_sec not in all_secs:
                all_secs.append(new_sec)
            existing["source_section"] = "|".join(all_secs)
            # 保留更好的元数据
            if not existing.get("title") and v.get("title"):
                existing["title"] = v["title"]
            if not existing.get("author") and v.get("author"):
                existing["author"] = v["author"]
            if not existing.get("thumbnail") and v.get("thumbnail"):
                existing["thumbnail"] = v["thumbnail"]
            # 保留 MP4 (如果任一有)
            mp4_existing = existing.get("duration", "") or ""
            mp4_new = v.get("duration", "") or ""
            if (not mp4_existing or "video.twimg.com" not in mp4_existing) and mp4_new and "video.twimg.com" in mp4_new:
                existing["duration"] = mp4_new

    # 日志: 合并统计
    multi = sum(1 for v in merged.values() if "|" in (v.get("source_section") or ""))
    log(f"  合并后: {len(merged)} 条 (其中 {multi} 条跨多栏目)")
    if multi > 0:
        examples = [f"{vid}:{v['source_section']}" for vid, v in list(merged.items())[:3] if "|" in (v.get("source_section") or "")]
        log(f"  示例: {examples}")

    records = []
    for vid, v in merged.items():
        mp4 = v.get("duration", "") or ""
        has_mp4 = bool(mp4 and mp4.startswith("http") and "video.twimg.com" in mp4)
        records.append({
            "video_id": vid,
            "title": (v.get("title") or "")[:500],
            "thumbnail_url": (v.get("thumbnail") or "")[:1000],
            "video_url": urljoin(BASE_URL, v.get("url", ""))[:1000],
            "author": (v.get("author") or "")[:200],
            "duration": mp4 if has_mp4 else "",
            "views": (v.get("views") or "")[:50],
            "monsnode_video_id": (v.get("monsnode_video_id") or "")[:50],
            "source_page": (v.get("source_page") or "")[:500],
            "source_section": (v.get("source_section") or "")[:100],
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


def supabase_save_status(stats: dict):
    """记录爬虫运行状态到 scrape_status 表"""
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
    }
    record = {
        "last_run": datetime.now(timezone.utc).isoformat(),
        "videos_found": stats.get("videos_found", 0),
        "videos_saved": stats.get("videos_saved", 0),
        "pages_crawled": stats.get("pages_crawled", 0),
        "mp4_resolved": stats.get("mp4_resolved", 0),
        "errors": "\n".join(stats.get("errors", [])[:10]),
    }
    try:
        client = httpx.Client(timeout=15)
        resp = client.post(SUPABASE_URL + "/rest/v1/scrape_status", headers=headers, json=record)
        if resp.status_code in (200, 201, 204):
            log("爬虫状态已记录")
        else:
            log(f"状态记录失败: {resp.status_code}", "WARN")
        client.close()
    except Exception as e:
        log(f"状态记录异常: {e}", "WARN")


# ========== 主流程 ==========

async def resolve_mp4_batch(context, mids: list[str]) -> dict[str, str]:
    """通过真实浏览器导航到 twjn.php 页面获取 MP4 (多 tab 并发)"""
    results = {}
    sem = asyncio.Semaphore(MP4_TAB_CONCURRENCY)

    async def resolve_one(mid: str):
        async with sem:
            page = await context.new_page()
            try:
                resp = await page.goto(
                    f"{BASE_URL}/twjn.php?v={mid}",
                    wait_until="domcontentloaded",
                    timeout=15000
                )
                if resp and resp.status == 200:
                    content = await page.content()
                    m = re.search(r"var\s+u\s*=\s*atob\('([^']+)'\)", content)
                    if m:
                        mp4 = base64.b64decode(m.group(1)).decode('utf-8')
                        if 'video.twimg.com' in mp4:
                            return mid, mp4
                return mid, None
            except Exception:
                return mid, None
            finally:
                await page.close()

    tasks = [resolve_one(mid) for mid in mids]
    batch_results = await asyncio.gather(*tasks)
    for mid, mp4 in batch_results:
        if mp4:
            results[mid] = mp4
    return results


async def scrape_all():
    from playwright.async_api import async_playwright

    stats = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "sections_crawled": 0,
        "pages_crawled": 0,
        "videos_found": 0,
        "videos_saved": 0,
        "mp4_resolved": 0,
        "rescrape_candidates": 0,
        "rescrape_resolved": 0,
        "rescrape_updated": 0,
        "errors": [],
    }

    log("启动浏览器...")
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
    # 共享 context (所有 section 共用 cookie/缓存, Cloudflare 只需过一次)
    context = await browser.new_context(
        user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        viewport={"width": 1366, "height": 768},
        locale="ja-JP",
        timezone_id="Asia/Tokyo",
        geolocation={"latitude": 35.6895, "longitude": 139.6917},
    )
    log("浏览器已启动")

    # 用于聚合各 section 的并行结果
    section_results_lock = asyncio.Lock()

    async def scrape_one_section(path: str, label: str, max_pages: int, mode: str) -> list[dict]:
        """抓取单个栏目的所有页面, 返回视频列表"""
        section_url = urljoin(BASE_URL, path)
        section_videos = []
        t0 = time.time()
        log(f"[{label}] {section_url}")

        page = await context.new_page()
        try:
            for page_num in range(1, max_pages + 1):
                url = build_page_url(section_url, page_num, mode)
                page_ok = False
                cards = []
                for cf_retry in range(2):
                    try:
                        await page.goto(url, wait_until="domcontentloaded", timeout=20000)
                        try:
                            await page.wait_for_selector("div.listn", timeout=8000)
                        except Exception:
                            content = await page.content()
                            if "challenges.cloudflare.com" in content or "お待ちください" in content:
                                wait_sec = 3 + cf_retry * 3
                                log(f"  [{label}] Cloudflare 挑战 (第{cf_retry+1}次), 等待 {wait_sec}s...")
                                await asyncio.sleep(wait_sec)
                                continue
                        await asyncio.sleep(0.5)

                        raw = await page.evaluate(EXTRACT_CARDS_JS)
                        cards = [c for c in raw if isinstance(c, dict) and c.get("video_id")]
                        page_ok = True
                        break
                    except Exception as e:
                        if cf_retry < 1:
                            log(f"  [{label}] 加载异常, 重试...", "WARN")
                            await asyncio.sleep(1)
                        else:
                            log(f"  [{label}] 加载失败(已重试2次): {str(e)[:80]}", "ERROR")

                if not page_ok:
                    if page_num == 1:
                        async with section_results_lock:
                            stats["errors"].append(f"{label}: 第1页加载失败")
                    break

                async with section_results_lock:
                    stats["pages_crawled"] += 1
                log(f"  [{label}] 第{page_num}页: {len(cards)} 个视频 ({time.time()-t0:.0f}s)")

                if not cards:
                    if page_num == 1:
                        async with section_results_lock:
                            stats["errors"].append(f"{label}: 第1页无视频")
                    break

                existing = {v["video_id"] for v in section_videos}
                new = [c for c in cards if c["video_id"] not in existing]
                if not new and page_num > 1:
                    break

                for c in new:
                    c["source_section"] = label
                    c["source_page"] = url

                section_videos.extend(new)
                if len(section_videos) >= MAX_VIDEOS_PER_SECTION:
                    break

                await asyncio.sleep(1)

        finally:
            await page.close()

        elapsed = time.time() - t0
        async with section_results_lock:
            stats["sections_crawled"] += 1
            stats["videos_found"] += len(section_videos)
        log(f"[{label}] 共 {len(section_videos)} 个视频 ({elapsed:.0f}s)")
        return section_videos

    all_section_videos = []  # 跨板块收集所有视频用于最后的批量 MP4 解析

    try:
        # 阶段 1: 并行抓取所有栏目
        log(f"开始并行抓取 {len(TARGET_SECTIONS)} 个栏目...")
        tasks = [scrape_one_section(path, label, max_pages, mode)
                 for path, label, max_pages, mode in TARGET_SECTIONS]
        section_results = await asyncio.gather(*tasks, return_exceptions=True)
        for result in section_results:
            if isinstance(result, list):
                all_section_videos.extend(result)
            else:
                log(f"栏目抓取异常: {result}", "WARN")

        # 阶段 2: Python 端合并 + 保存 (同一视频跨多个栏目 → source_section 拼接)
        if all_section_videos:
            saved = supabase_save(all_section_videos)
            stats["videos_saved"] = saved
            log(f"\n[阶段2] 保存完成: {saved} 条")
        else:
            log("\n[阶段2] 无视频可保存")

        # 阶段 3: 解析 MP4 (按优先级排序: trending/latest 优先, 最大 60 个)
        all_targets = {}
        for v in all_section_videos:
            mid = v.get("monsnode_video_id", "").strip()
            if mid and mid.isdigit():
                all_targets[mid] = v

        if all_targets:
            # 按 source_section 优先级排序
            def _mp4_rank(item):
                mid, v = item
                sec = v.get("source_section", "")
                try:
                    return MP4_PRIORITY.index(sec)
                except ValueError:
                    return 99

            sorted_targets = sorted(all_targets.items(), key=_mp4_rank)
            mids = [mid for mid, _ in sorted_targets[:60]]
            log(f"\n[阶段3] MP4 解析: {len(mids)} 个视频 (多 tab 真实导航, 热门优先)...")
            t2 = time.time()

            all_mp4 = {}
            for batch_start in range(0, len(mids), MP4_TAB_CONCURRENCY * 3):
                batch = mids[batch_start:batch_start + MP4_TAB_CONCURRENCY * 3]
                batch_results = await resolve_mp4_batch(context, batch)
                all_mp4.update(batch_results)
                done = min(batch_start + MP4_TAB_CONCURRENCY * 3, len(mids))
                log(f"  {done}/{len(mids)} → {len(all_mp4)} MP4 ({time.time()-t2:.0f}s)")

            mp4_updates = {}
            for mid, mp4 in all_mp4.items():
                mp4_updates[mid] = mp4
                stats["mp4_resolved"] += 1
            if mp4_updates:
                supabase_update_mp4(mp4_updates)
            log(f"MP4 解析完成: {len(all_mp4)}/{len(mids)} ({time.time()-t2:.0f}s)")

        # 阶段 4: 自动回爬 — 修复旧视频中未解析到 MP4 的
        log("\n[阶段4] 查询数据库中未解析 MP4 的旧视频...")
        failed = supabase_fetch_failed(limit=200)
        stats["rescrape_candidates"] = len(failed)
        if failed:
            # 排除本轮刚解析过的 mid
            already_resolved = set(all_targets.keys()) & {v["monsnode_video_id"] for v in failed}
            to_rescrape = {v["monsnode_video_id"]: v for v in failed if v["monsnode_video_id"] not in already_resolved}
            log(f"  候选: {len(failed)}, 本轮已解析: {len(already_resolved)}, 需回爬: {len(to_rescrape)}")

            if to_rescrape:
                mids = list(to_rescrape.keys())
                t3 = time.time()
                all_rescraped_mp4 = {}
                for batch_start in range(0, len(mids), MP4_TAB_CONCURRENCY * 3):
                    batch = mids[batch_start:batch_start + MP4_TAB_CONCURRENCY * 3]
                    batch_results = await resolve_mp4_batch(context, batch)
                    all_rescraped_mp4.update(batch_results)
                    done = min(batch_start + MP4_TAB_CONCURRENCY * 3, len(mids))
                    log(f"  回爬 {done}/{len(mids)} → {len(all_rescraped_mp4)} MP4 ({time.time()-t3:.0f}s)")

                # 标记失败的 (无 MP4 的也更新, 避免下轮重复查询)
                all_updates = {}
                for mid in mids:
                    all_updates[mid] = all_rescraped_mp4.get(mid)

                updated = supabase_update_mp4(all_updates)
                stats["rescrape_resolved"] = len(all_rescraped_mp4)
                stats["rescrape_updated"] = updated
                log(f"  回爬完成: 更新 {updated} 条, 其中 {len(all_rescraped_mp4)} 个解析成功 ({time.time()-t3:.0f}s)")
        else:
            log("  无待回爬视频")

    finally:
        await context.close()
        await browser.close()
        await pw.stop()

    stats["finished_at"] = datetime.now(timezone.utc).isoformat()
    supabase_save_status(stats)
    return stats


def main():
    print("=" * 55)
    log(f"monsnode 爬虫 v8 — 真实浏览器导航 (并行栏目)")
    key_ok = SUPABASE_KEY and len(SUPABASE_KEY) > 100
    log(f"SUPABASE_URL={'已设置' if SUPABASE_URL else '❌'} ({len(SUPABASE_URL)} 字符)")
    log(f"SUPABASE_KEY={'已设置' if key_ok else '❌'} ({len(SUPABASE_KEY)} 字符)")
    if not SUPABASE_URL or not key_ok:
        log("请设置 SUPABASE_URL 和 SUPABASE_KEY 环境变量", "ERROR")
        sys.exit(1)
    print("=" * 55)

    stats = asyncio.run(scrape_all())
    mp4_rate = stats['mp4_resolved'] / max(stats['videos_found'], 1) * 100
    print("\n" + "=" * 55)
    print(f"  板块: {stats['sections_crawled']}  页面: {stats['pages_crawled']}")
    print(f"  发现: {stats['videos_found']}  MP4: {stats['mp4_resolved']} ({mp4_rate:.0f}%)")
    print(f"  保存: {stats['videos_saved']}")
    rc = stats.get('rescrape_candidates', 0)
    if rc:
        rr = stats.get('rescrape_resolved', 0)
        ru = stats.get('rescrape_updated', 0)
        print(f"  回爬: 候选 {rc} → 修复 {rr} → 更新 {ru}")
    if stats["errors"]:
        print(f"  错误 ({len(stats['errors'])}):")
        for e in stats["errors"][:5]:
            print(f"    - {e[:120]}")
    print("=" * 55)


if __name__ == "__main__":
    main()

"""
批量解析 monsnode redirect URL → Twitter tweet ID → fxtwitter MP4 直链
使用 Playwright 绕过 Cloudflare, curl_cffi 调用 fxtwitter API
"""
import os
import re
import sys
import time
import json
import asyncio
from datetime import datetime

SUPABASE_URL = 'https://fejspvbckgkbmfyoxiub.supabase.co'
SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZlanNwdmJja2drYm1meW94aXViIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA0ODczNzcsImV4cCI6MjA5NjA2MzM3N30.L1jV0XWpE69nQVgZWmAxjOGTALpfmD7xflcO2Yb5Z14'

BATCH_SIZE = 20
CONCURRENT_REDIRECTS = 3


def log(msg: str):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {msg}")


def fetch_videos_without_mp4() -> list[dict]:
    """从 Supabase 获取 duration 为 null 或不是 .mp4 的视频"""
    import httpx as hx
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
    }
    all_videos = []
    offset = 0
    client = hx.Client(timeout=30)
    try:
        while True:
            resp = client.get(
                f"{SUPABASE_URL}/rest/v1/videos?select=id,video_id,title,author,thumbnail_url,duration"
                f"&order=created_at.desc&limit=100&offset={offset}",
                headers=headers
            )
            if resp.status_code != 200:
                log(f"Supabase 查询失败: {resp.status_code} {resp.text[:100]}")
                break
            batch = resp.json()
            if not batch:
                break
            # 过滤: 只需要 duration 为 null 或不含 .mp4 的视频
            for v in batch:
                dur = v.get("duration") or ""
                if ".mp4" not in dur and "video.twimg.com" not in dur:
                    all_videos.append(v)
            offset += 100
            if len(batch) < 100:
                break
    finally:
        client.close()
    log(f"从 Supabase 获取了 {len(all_videos)} 个需要解析的视频 (共检查 {offset + len(batch) if 'batch' in dir() else offset} 条)")
    return all_videos


def resolve_redirects_playwright(videos: list[dict]) -> dict:
    """使用 Playwright 真实浏览器解析 monsnode redirect → Twitter URL"""
    from playwright.sync_api import sync_playwright

    results = {}  # video_id → tweet_id or None

    def _resolve_batch(batch: list[dict]):
        nonlocal results
        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=True,
                args=["--no-sandbox", "--disable-setuid-sandbox",
                      "--disable-dev-shm-usage", "--disable-gpu"]
            )
            try:
                for idx, v in enumerate(batch):
                    vid = v["video_id"]
                    num_id = vid.replace("v", "")
                    if not num_id.isdigit():
                        log(f"  跳过 {vid}: 无效ID")
                        continue
                    redirect_url = f"https://monsnode.com/redirect.php?v={num_id}&t=1"
                    page = None
                    try:
                        page = browser.new_page()
                        # wait_until="commit" 最快, 只需响应头返回
                        page.goto(redirect_url, wait_until="commit", timeout=15000)
                        # 短暂等待重定向链完成
                        page.wait_for_timeout(2000)
                        final_url = page.url
                        m = re.search(r"status/(\d+)", final_url)
                        if m:
                            results[vid] = m.group(1)
                            log(f"  [{idx+1}/{len(batch)}] {vid} → tweet {m.group(1)}")
                        else:
                            results[vid] = None
                            log(f"  [{idx+1}/{len(batch)}] {vid} → 未找到推文ID (final={final_url[:80]})")
                    except Exception as e:
                        results[vid] = None
                        log(f"  [{idx+1}/{len(batch)}] {vid} → 错误: {str(e)[:80]}")
                    finally:
                        if page:
                            page.close()
            finally:
                browser.close()

    # 分批处理
    for i in range(0, len(videos), BATCH_SIZE):
        batch = videos[i:i + BATCH_SIZE]
        log(f"Playwright 解析第 {i//BATCH_SIZE+1} 批 ({len(batch)} 个)...")
        _resolve_batch(batch)
        time.sleep(2)

    return results


def resolve_fxtwitter_mp4(tweet_ids: dict) -> dict:
    """通过 fxtwitter API 获取 MP4 直链 (使用 curl_cffi 绕过 Cloudflare)"""
    from curl_cffi import requests as cffi_requests

    mp4_results = {}  # video_id → mp4_url or None

    for vid, tweet_id in tweet_ids.items():
        if not tweet_id:
            mp4_results[vid] = None
            continue
        try:
            resp = cffi_requests.get(
                f"https://api.fxtwitter.com/status/{tweet_id}",
                impersonate="chrome124", timeout=15
            )
            if resp.status_code == 200:
                data = resp.json()
                media = (data.get("tweet", {}).get("media", {}) or {})
                videos = media.get("videos", [])
                if videos:
                    mp4_results[vid] = videos[-1].get("url", "")
                else:
                    mp4_results[vid] = None
            else:
                mp4_results[vid] = None
        except Exception:
            mp4_results[vid] = None

    resolved = sum(1 for v in mp4_results.values() if v)
    log(f"fxtwitter API: 解析了 {resolved}/{len(tweet_ids)} 个 MP4")
    return mp4_results


def update_supabase(mp4_results: dict):
    """批量更新 Supabase 中的 duration 字段为 MP4 URL"""
    import httpx as hx
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates",
    }
    now = datetime.now().isoformat()
    records = []
    for vid, mp4_url in mp4_results.items():
        if mp4_url:
            records.append({
                "video_id": vid,
                "duration": mp4_url[:500],
                "updated_at": now,
            })

    if not records:
        log("没有需要更新的记录")
        return 0

    client = hx.Client(timeout=30)
    saved = 0
    try:
        for i in range(0, len(records), 30):
            batch = records[i:i + 30]
            for attempt in range(3):
                try:
                    resp = client.post(
                        SUPABASE_URL + "/rest/v1/videos",
                        headers=headers,
                        json=batch
                    )
                    if resp.status_code in (200, 201):
                        saved += len(batch)
                        break
                    time.sleep(2)
                except Exception:
                    time.sleep(1)
    finally:
        client.close()
    log(f"更新了 {saved} 条记录到 Supabase")
    return saved


def main():
    log("=== 批量解析 monsnode → MP4 ===")

    # 1. 获取需要解析的视频
    videos = fetch_videos_without_mp4()
    if not videos:
        log("没有需要处理的视频")
        return

    # 2. Playwright 解析 redirect → tweet ID
    log(f"步骤1: 解析 {len(videos)} 个 redirect...")
    tweet_ids = resolve_redirects_playwright(videos)
    success = sum(1 for v in tweet_ids.values() if v)
    log(f"推文ID解析: {success}/{len(tweet_ids)} 成功")

    if success == 0:
        log("没有解析到任何推文ID, 退出")
        return

    # 3. fxtwitter API → MP4
    log("步骤2: 获取 MP4 直链...")
    mp4_results = resolve_fxtwitter_mp4(tweet_ids)

    # 4. 更新 Supabase
    log("步骤3: 更新数据库...")
    saved = update_supabase(mp4_results)
    log(f"=== 完成! 共更新 {saved} 条 MP4 URL ===")

    # 5. 输出统计
    total = len(mp4_results)
    mp4_ok = sum(1 for v in mp4_results.values() if v)
    tweet_ok = sum(1 for v in tweet_ids.values() if v)
    log(f"统计: 总{total}, 推文{tweet_ok}, MP4{mp4_ok}")


if __name__ == "__main__":
    main()

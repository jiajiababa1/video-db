"""
批量解析: monsnode redirect → Playwright → tweet ID → curl_cffi fxtwitter API → MP4 → Supabase
用法: python resolve_mp4.py
"""
import re
import sys
import time
import httpx as hx
from datetime import datetime
from curl_cffi import requests as cffi_requests
from playwright.sync_api import sync_playwright

SUPABASE_URL = 'https://fejspvbckgkbmfyoxiub.supabase.co'
SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZlanNwdmJja2drYm1meW94aXViIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA0ODczNzcsImV4cCI6MjA5NjA2MzM3N30.L1jV0XWpE69nQVgZWmAxjOGTALpfmD7xflcO2Yb5Z14'
BATCH_SIZE = 20

def log(msg: str):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)

def fetch_redirect_videos() -> list[dict]:
    """获取 duration 中有 redirect URL 但没有 MP4 的视频"""
    headers = {"apikey": SUPABASE_KEY, "Authorization": "Bearer " + SUPABASE_KEY}
    all_videos = []
    offset = 0
    client = hx.Client(timeout=30)
    try:
        while True:
            resp = client.get(
                f"{SUPABASE_URL}/rest/v1/videos?select=video_id,duration,title"
                f"&order=created_at.desc&limit=100&offset={offset}",
                headers=headers
            )
            if resp.status_code != 200:
                break
            batch = resp.json()
            if not batch:
                break
            for v in batch:
                dur = v.get("duration") or ""
                if "redirect.php" in dur and ".mp4" not in dur:
                    all_videos.append(v)
            offset += 100
            if len(batch) < 100:
                break
    finally:
        client.close()
    log(f"找到 {len(all_videos)} 个需要解析 redirect 的视频")
    return all_videos

def resolve_with_playwright(videos: list[dict]) -> dict:
    """Playwright 批量解析 redirect → tweet ID"""
    tweet_ids = {}
    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"]
        )
        try:
            for i in range(0, len(videos), BATCH_SIZE):
                batch = videos[i:i + BATCH_SIZE]
                page = None
                for idx, v in enumerate(batch):
                    vid = v['video_id']
                    redirect = v['duration']
                    try:
                        page = browser.new_page()
                        page.goto(redirect + "&t=1", wait_until="commit", timeout=15000)
                        page.wait_for_timeout(800)
                        m = re.search(r"status/(\d+)", page.url)
                        if m:
                            tweet_ids[vid] = m.group(1)
                        page.close()
                        page = None
                    except Exception as e:
                        pass
                    finally:
                        if page:
                            try: page.close()
                            except: pass
                            page = None
                    if (idx + 1) % 10 == 0 or idx == len(batch) - 1:
                        log(f"  进度: {i+idx+1}/{len(videos)} -- 已解析 {len(tweet_ids)} 个推文ID")
        finally:
            browser.close()
    log(f"Playwright 解析完成: {len(tweet_ids)}/{len(videos)} 个推文ID")
    return tweet_ids

def get_mp4_from_fxtwitter(tweet_ids: dict) -> dict:
    """curl_cffi 调用 fxtwitter API 获取 MP4"""
    mp4s = {}
    total = len(tweet_ids)
    for idx, (vid, tid) in enumerate(tweet_ids.items()):
        try:
            resp = cffi_requests.get(
                f"https://api.fxtwitter.com/status/{tid}",
                impersonate="chrome124", timeout=15
            )
            if resp.status_code == 200:
                data = resp.json()
                media = (data.get("tweet", {}).get("media", {}) or {})
                vids = media.get("videos", [])
                if vids:
                    mp4s[vid] = vids[-1].get("url", "")
            elif resp.status_code == 404:
                pass  # 推文不存在或已删除
        except Exception:
            pass
        if (idx + 1) % 10 == 0 or idx == total - 1:
            log(f"  fxtwitter: {idx+1}/{total} -- 已获取 {len(mp4s)} 个 MP4")
    return mp4s

def update_supabase(mp4s: dict) -> int:
    """PATCH 更新 Supabase"""
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json",
    }
    now = datetime.now().isoformat()
    updated = 0
    client = hx.Client(timeout=30)
    try:
        for idx, (vid, mp4_url) in enumerate(mp4s.items()):
            try:
                resp = client.patch(
                    f"{SUPABASE_URL}/rest/v1/videos?video_id=eq.{vid}",
                    headers=headers,
                    json={"duration": mp4_url[:500], "updated_at": now}
                )
                if resp.status_code in (200, 204):
                    updated += 1
            except Exception:
                pass
            if (idx + 1) % 20 == 0:
                log(f"  数据库更新: {idx+1}/{len(mp4s)}")
    finally:
        client.close()
    return updated

def main():
    log("=== 批量解析 monsnode → MP4 ===")

    # 1. 获取需要解析的视频
    videos = fetch_redirect_videos()
    if not videos:
        log("没有需要处理的视频!")
        return

    # 2. Playwright 解析 redirect → tweet ID
    log(f"步骤1: Playwright 解析 {len(videos)} 个 redirect...")
    tweet_ids = resolve_with_playwright(videos)

    if not tweet_ids:
        log("没有解析到任何推文ID, 退出")
        return

    # 3. fxtwitter API → MP4
    log(f"步骤2: fxtwitter API 获取 {len(tweet_ids)} 个 MP4...")
    mp4s = get_mp4_from_fxtwitter(tweet_ids)

    if not mp4s:
        log("没有获取到任何 MP4 URL")
        return

    # 4. 更新 Supabase
    log(f"步骤3: 更新 {len(mp4s)} 条记录...")
    updated = update_supabase(mp4s)
    log(f"=== 完成! {updated}/{len(mp4s)} 条 MP4 URL 已更新 ===")

if __name__ == "__main__":
    main()

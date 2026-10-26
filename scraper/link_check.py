#!/usr/bin/env python3
"""
断链巡检脚本 (#3)

用途: 抽查 videos 表里有 MP4 直链的视频，用 HEAD/RANGE 请求验证直链是否
依然有效；失效的标记 needs_rescrape=true，进入重爬队列。

用法:
    SUPABASE_URL=... SUPABASE_KEY=... python3 link_check.py [--sample 300] [--workers 10]
"""
import os, sys, re, time, argparse
import urllib.request, urllib.parse, json
from concurrent.futures import ThreadPoolExecutor, as_completed

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").strip().strip("'\"")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "").strip().strip("'\"")

def log(*a):
    print(*a, flush=True)

def sb_headers():
    return {"apikey": SUPABASE_KEY, "Authorization": "Bearer " + SUPABASE_KEY,
            "Content-Type": "application/json"}

def sb_get(path):
    req = urllib.request.Request(SUPABASE_URL + path, headers=sb_headers())
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())

def sb_patch(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(SUPABASE_URL + path, data=data, headers=sb_headers(), method="PATCH")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status

def check_url(url):
    """RANGE 取 1 字节验证，不下载整个文件"""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0",
            "Range": "bytes=0-1",
            "Referer": "https://x.com/",
        })
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status in (200, 206)
    except Exception:
        return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", type=int, default=300)
    ap.add_argument("--workers", type=int, default=10)
    args = ap.parse_args()
    if not SUPABASE_URL or not SUPABASE_KEY:
        log("❌ 需要 SUPABASE_URL / SUPABASE_KEY 环境变量")
        sys.exit(1)

    rows = sb_get(
        "/rest/v1/videos?select=video_id,mp4_url,duration"
        "&has_mp4=is.true&video_id=not.like.hx_*"
        f"&order=updated_at.asc&limit={args.sample}"
    )
    log(f"抽查: {len(rows)} 条")
    dead = 0
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {}
        for r in rows:
            url = r.get("mp4_url") or r.get("duration") or ""
            if "video.twimg.com" in url or ".mp4" in url:
                futs[ex.submit(check_url, url)] = r
        for fut in as_completed(futs):
            r = futs[fut]
            alive = fut.result()
            if not alive:
                try:
                    sb_patch(
                        f"/rest/v1/videos?video_id=eq.{urllib.parse.quote(r['video_id'], safe='')}",
                        {"needs_rescrape": True, "has_mp4": False,
                         "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                    )
                    dead += 1
                    log(f"  💀 失效已标记: {r['video_id'][:24]}")
                except Exception as e:
                    log(f"  标记失败: {e}")
            time.sleep(0.1)
    log(f"✅ 抽查完毕，失效 {dead} 条已进重爬队列")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
MP4 直链回填脚本 (#1 解析后端化)

用途: 把数据库里没有 MP4 直链的老视频，通过服务端直连 twjn.php 解析出
video.twimg.com 直链，写回 videos 表 (video_url + has_mp4=true)。

为什么放后端: 浏览器端受 CORS 限制，公共 CORS 代理全部失效；
服务端直连 monsnode.com 无此问题 (2026-10-12 实测可用)。

用法:
    SUPABASE_URL=... SUPABASE_KEY=... python3 mp4_backfill.py [--batch 200] [--workers 10]

环境变量:
    SUPABASE_URL / SUPABASE_KEY  (service_role 或有写权限的 key)
"""
import os, sys, re, base64, time, argparse
import urllib.request, urllib.parse, json
from concurrent.futures import ThreadPoolExecutor, as_completed

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").strip().strip("'\"")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "").strip().strip("'\"")

RE_ATOB = re.compile(r"atob\(\s*['\"]([^'\"]+)['\"]\s*\)")
RE_MP4 = re.compile(r"https?://[^\s\"'\\\\)<>]*video\.twimg\.com[^\s\"'\\\\)<>]*")

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

def extract_mp4(html):
    if not html:
        return None
    for m in RE_ATOB.finditer(html):
        try:
            u = base64.b64decode(m.group(1)).decode("utf-8", "ignore").strip()
            if "video.twimg.com" in u:
                return u.rstrip(".,*)]\"'")
        except Exception:
            pass
    m2 = RE_MP4.search(html)
    return m2.group(0).rstrip(".,*)]\"'") if m2 else None

def resolve_one(mid):
    """服务端直连 twjn.php 解析 MP4"""
    url = f"https://monsnode.com/twjn.php?v={mid}"
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
            "Referer": "https://monsnode.com/",
        })
        with urllib.request.urlopen(req, timeout=20) as r:
            html = r.read().decode("utf-8", "ignore")
        return extract_mp4(html)
    except Exception:
        return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", type=int, default=200, help="每轮处理数量")
    ap.add_argument("--workers", type=int, default=10, help="并发数")
    args = ap.parse_args()

    if not SUPABASE_URL or not SUPABASE_KEY:
        log("❌ 需要 SUPABASE_URL / SUPABASE_KEY 环境变量")
        sys.exit(1)

    # 查没有 MP4 但有 monsnode id 的视频
    rows = sb_get(
        "/rest/v1/videos?select=video_id,monsnode_video_id"
        "&or=(has_mp4.is.false,has_mp4.is.null)"
        "&monsnode_video_id=not.is.null"
        f"&order=created_at.desc&limit={args.batch}"
    )
    log(f"待回填: {len(rows)} 条")
    if not rows:
        return

    ok, fail = 0, 0
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(resolve_one, r["monsnode_video_id"]): r for r in rows}
        for fut in as_completed(futs):
            r = futs[fut]
            try:
                mp4 = fut.result()
            except Exception:
                mp4 = None
            if mp4:
                try:
                    sb_patch(
                        f"/rest/v1/videos?video_id=eq.{urllib.parse.quote(r['video_id'], safe='')}",
                        {"video_url": mp4, "has_mp4": True,
                         "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                    )
                    ok += 1
                except Exception:
                    fail += 1
            else:
                fail += 1
            time.sleep(0.2)
    log(f"✅ 回填成功 {ok} 条, 失败/无直链 {fail} 条")

if __name__ == "__main__":
    main()

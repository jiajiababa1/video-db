"""
text_backfill.py — 云端爬虫文案回填补丁 (配合 scraper/main.py 使用)
============================================================
背景: monsnode 列表页改版后 img alt 为空, 新入库视频 title="" (约42%),
导致站内搜索搜不到。AV4 不受影响 (标题正常)。

原理 (与站内 JS 版 backfillTextForVideo 同逻辑):
  twjn.php?v=<monsnode_id> → 解出真实推文 ID (注意: monsnode 列表 id ≠ 推文 id,
  只有 tweet_link 里的才是真的) → api.fxtwitter.com/status/<tweet_id> → 推文原文(title)
  + 作者(screen_name) → 回写 videos 表。成功顺手带 MP4 (twjn 同一页就有)。

用法 (二选一):
  A. 独立跑:  python text_backfill.py --limit 500
     (需要环境变量 SUPABASE_URL / SUPABASE_SERVICE_KEY)
  B. 接入 main.py: 在 resolve 循环里对 title 为空的行调 backfill_one(sb, row)

依赖: pip install requests supabase
"""
import os
import re
import sys
import time
import base64

import requests

FX_API = "https://api.fxtwitter.com/status/{}"
TWJN_URL = "https://monsnode.com/twjn.php?v={}"


def extract_tweet_id(html: str):
    """从 twjn 页面解真实推文 ID (明文 status/ 优先, atob 混淆其次)。"""
    if not html:
        return None
    m = re.search(r"status/(\d{12,25})", html)
    if m:
        return m.group(1)
    for b64 in re.findall(r"atob\(\s*['\"]([^'\"]{20,})['\"]\s*\)", html):
        try:
            d = base64.b64decode(b64).decode("utf-8", "ignore")
        except Exception:
            continue
        t = re.search(r"status/(\d{12,25})", d)
        if t:
            return t.group(1)
    return None


def extract_mp4(html: str):
    """与站内 extractTwjnMp4 同规则 (只取 video.twimg.com)。"""
    if not html:
        return None
    for b64 in re.findall(r"atob\(\s*['\"]([^'\"]{20,})['\"]\s*\)", html):
        try:
            d = base64.b64decode(b64).decode("utf-8", "ignore")
        except Exception:
            continue
        if "video.twimg.com" in d:
            return d.strip()
    m = re.search(r"https?://[^\s\"'\\\\)<>]*video\.twimg\.com[^\s\"'\\\\)<>]*", html)
    return m.group(0).replace("&amp;", "&") if m else None


def fetch_tweet_meta(tweet_id: str, timeout=15):
    """推文 ID → (title, author)。删推/锁推返回 (None, None)。"""
    if not tweet_id or not re.fullmatch(r"\d{12,25}", str(tweet_id)):
        return None, None
    try:
        r = requests.get(FX_API.format(tweet_id), timeout=timeout)
        if r.status_code != 200:
            return None, None
        tw = (r.json() or {}).get("tweet") or {}
        raw = ((tw.get("raw_text") or {}).get("text")) or tw.get("text") or ""
        title = re.sub(r"https?://t\.co/\S+", "", raw)
        title = re.sub(r"\s+", " ", title).strip()[:500]
        au = tw.get("author") or {}
        author = (au.get("screen_name") or au.get("name") or "").lstrip("@")[:200]
        if not title and not author:
            return None, None
        return title or None, author or None
    except Exception:
        return None, None


def backfill_one(sb, row, session=None):
    """单行回填。row 需含 video_id/monsnode_video_id/video_url/title/author/has_mp4。
    返回 'ok' / 'fail' / 'skip'。"""
    if (row.get("title") or "").strip():
        return "skip"
    s = session or requests.Session()
    s.headers.update({"User-Agent": "Mozilla/5.0"})
    tweet_id, mp4 = None, None
    mid = row.get("monsnode_video_id")
    if mid:
        try:
            h = s.get(TWJN_URL.format(mid), timeout=20).text
            mp4 = extract_mp4(h)
            tweet_id = extract_tweet_id(h)
        except Exception:
            pass
    if not tweet_id:
        m = re.search(r"status/(\d{12,25})", row.get("video_url") or "")
        tweet_id = m.group(1) if m else None
    title, author = fetch_tweet_meta(tweet_id) if tweet_id else (None, None)
    patch = {"updated_at": "now()"}
    if title:
        patch["title"] = title
    if author and (not (row.get("author") or "") or row.get("author") == "anon-user"):
        patch["author"] = author
    if mp4 and not row.get("has_mp4"):
        patch.update({"duration": mp4, "mp4_url": mp4,
                      "has_mp4": True, "needs_rescrape": False})
    if len(patch) <= 1:
        return "fail"
    # supabase-py: sb.table("videos").update(patch).eq("video_id", ...).execute()
    sb.table("videos").update(patch).eq(
        "video_id", row["video_id"]).execute()
    return "ok"


def main(limit=500, batch=50):
    from supabase import create_client
    sb = create_client(os.environ["SUPABASE_URL"],
                       os.environ["SUPABASE_SERVICE_KEY"])
    done = ok = fail = 0
    while done < limit:
        q = (sb.table("videos")
             .select("video_id,title,author,monsnode_video_id,video_url,duration,has_mp4")
             .or_("title.is.null,title.eq.")
             .order("id", desc=True).limit(batch).execute())
        rows = q.data or []
        if not rows:
            break
        s = requests.Session()
        for r in rows:
            if done >= limit:
                break
            try:
                st = backfill_one(sb, r, session=s)
            except Exception as e:
                print("ERR", r["video_id"], str(e)[:80])
                st = "fail"
            done += 1
            if st == "ok":
                ok += 1
            elif st == "fail":
                fail += 1
            print(f"[{done}] {r['video_id']} -> {st}")
            time.sleep(1.0)
        time.sleep(2.0)
    print(f"DONE ok={ok} fail={fail} total={done}")


if __name__ == "__main__":
    lim = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else 500
    main(limit=lim)

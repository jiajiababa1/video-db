#!/usr/bin/env python3
"""
按作者抓取 (GitHub Actions: author-scrape.yml, 站内 "作者抓" 云端版)。

薄包装, 全部重逻辑复用 scraper/main.py:
  1. crawl_author() 逐个搜选定的作者 (search.php, 自动翻页)
  2. sb_save() 走 upsert_videos RPC (空字段不覆盖, has_mp4 只升不降)
  3. 前 N 个带 monsnode id 的走 resolve_batch() + sb_write_results()
  4. sb_save_status() 写 scrape_status (站内轮询读最后一行拿数字)

用法:
  python -u scraper/author_scrape.py --authors "A,B" --max-pages 5 --resolve 20

环境变量: SUPABASE_URL / SUPABASE_KEY(service_role, 与 scraper.yml 同一套),
  AUTHOR_TIME_BUDGET(秒, 默认 1200), AUTHOR_RESOLVE_BUDGET(秒, 默认 300)。

退出码: 0=正常结束(即使 0 结果); 2=传输层全被拦/缺密钥。
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import main as M


def parse_args():
    ap = argparse.ArgumentParser(description="按作者抓取作品")
    ap.add_argument("--authors", required=True,
                    help="作者名, 逗号分隔, 最多 10 个")
    ap.add_argument("--max-pages", type=int, default=5,
                    help="每个作者最多翻页 (1-20)")
    ap.add_argument("--resolve", type=int, default=300,
                    help="MP4 解析条数上限 (0=跳过, 默认全解析)")
    return ap.parse_args()


def clean_authors(raw):
    out = []
    for a in (raw or "").split(","):
        a = a.strip()[:60]
        if a and a not in out:
            out.append(a)
    return out[:10]


def main():
    args = parse_args()
    authors = clean_authors(args.authors)
    if not authors:
        M.log("没有有效的作者名", "ERROR")
        return 2
    max_pages = max(1, min(20, args.max_pages or 5))
    resolve_n = max(0, args.resolve if args.resolve is not None else 300)
    budget = M._env_int("AUTHOR_TIME_BUDGET", 1500)
    resolve_budget = M._env_int("AUTHOR_RESOLVE_BUDGET", 600)

    M.DEEP_AUTHOR_PAGES = max_pages
    M.log(f"按作者抓取: {len(authors)} 个作者 {authors}, 每作者 {max_pages} 页, 解析 {resolve_n} 条")

    if not M.SUPABASE_URL or not M.SUPABASE_KEY or len(M.SUPABASE_KEY) < 100:
        M.log("请设置 SUPABASE_URL 和 SUPABASE_KEY 环境变量", "ERROR")
        return 2

    stats = {"videos_found": 0, "videos_saved": 0, "pages_crawled": 0,
             "mp4_resolved": 0, "errors": []}
    fetcher = M.Fetcher()
    try:
        fetcher.probe()
        if fetcher.blocked:
            M.log("[作者抓取] 传输层全部被 Cloudflare 拦截, 跳过", "ERROR")
            stats["errors"].append("transport blocked")
            return 2
        seen = set()
        deadline = time.time() + budget
        allv = []
        for au in authors:
            if time.time() >= deadline:
                M.log("时间预算用完, 停止", "WARN")
                break
            vids = M.crawl_author(fetcher, au, deadline, seen)
            for c in vids:
                if not c.get("author"):
                    c["author"] = au
            M.log(f"  @{au}: +{len(vids)} 新卡片")
            allv.extend(vids)
        stats["videos_found"] = len(allv)
        if allv:
            M.log(f"保存 {len(allv)} 条到数据库 ...")
            stats["videos_saved"] = M.sb_save(allv)
        todo = [(c.get("monsnode_video_id"), c.get("video_id"))
                for c in allv if c.get("monsnode_video_id")]
        todo = todo[:resolve_n]
        if todo:
            M.log(f"解析 MP4 ({len(todo)} 条) ...")
            results = M.resolve_batch(fetcher, todo, resolve_budget)
            hit, fail = M.sb_write_results(results)
            stats["mp4_resolved"] = hit
            M.log(f"MP4 成功 {hit}, 失败/待定 {fail}")
    except Exception as e:
        import traceback
        M.log(f"作者抓取异常: {e}", "ERROR")
        traceback.print_exc()
        stats["errors"].append(str(e)[:200])
        return 1
    finally:
        try:
            fetcher.close()
        except Exception:
            pass
        M.log(f"HTTP 统计: {fetcher._stats}")
        M.sb_save_status(stats)

    print("=" * 60)
    print(f"  AUTHOR_SCRAPE_RESULT found={stats['videos_found']} "
          f"saved={stats['videos_saved']} mp4={stats['mp4_resolved']}")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())

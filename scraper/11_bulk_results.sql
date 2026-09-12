-- ============================================================
-- 11_bulk_results.sql — MP4 解析结果批量写回 (幂等, 可安全重复执行)
-- 适用: Supabase → SQL Editor → 全选粘贴 → Run
--
-- 为什么需要:
--   爬虫每轮会解析成千上万条 twjn.php → MP4 直链。若逐条 PATCH 写回,
--   一次要发上万个 HTTP 请求, 很容易超时/被限速。这个 RPC 让爬虫把上千条
--   结果塞进一个 jsonb 数组, 一条 SQL 全部更新完。
--   爬虫找不到这个函数时会自动回退逐条写入, 所以不执行也能跑 (只是慢很多)。
--
-- 传参 p_results 形如:
--   [{"video_id":"v123","mp4_url":"https://video.twimg.com/....mp4"}, ...]
--   • 带 mp4_url (解析成功)      → 写入 mp4_url/duration, has_mp4=true,
--                                  needs_rescrape=false, retry_count=0
--   • 不带 mp4_url (解析失败/无效) → 只更新 mp4_checked_at, 让该条排到队尾稍后再试
-- ============================================================

DROP FUNCTION IF EXISTS public.apply_mp4_results(jsonb);
CREATE OR REPLACE FUNCTION public.apply_mp4_results(p_results jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE n integer;
BEGIN
  WITH data AS (
    SELECT (r->>'video_id')         AS video_id,
           NULLIF(r->>'mp4_url', '') AS mp4_url
    FROM jsonb_array_elements(COALESCE(p_results, '[]'::jsonb)) AS r
  ), upd AS (
    UPDATE public.videos v
    SET duration       = COALESCE(d.mp4_url, v.duration),
        mp4_url        = COALESCE(d.mp4_url, v.mp4_url),
        has_mp4        = CASE WHEN d.mp4_url IS NOT NULL THEN true  ELSE v.has_mp4 END,
        playable       = CASE WHEN d.mp4_url IS NOT NULL THEN true  ELSE v.playable END,
        needs_rescrape = CASE WHEN d.mp4_url IS NOT NULL THEN false ELSE v.needs_rescrape END,
        retry_count    = CASE WHEN d.mp4_url IS NOT NULL THEN 0     ELSE COALESCE(v.retry_count, 0) END,
        mp4_checked_at = NOW(),
        updated_at     = NOW()
    FROM data d
    WHERE v.video_id = d.video_id
    RETURNING 1
  )
  SELECT COUNT(*) INTO n FROM upd;
  RETURN n;
END; $$;

GRANT EXECUTE ON FUNCTION public.apply_mp4_results(jsonb) TO anon;
GRANT EXECUTE ON FUNCTION public.apply_mp4_results(jsonb) TO service_role;

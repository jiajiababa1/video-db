-- ═══════════════════════════════════════════
-- 🔧 04_scraper_fn.sql — 爬虫专用函数 (service_role调用)
-- ═══════════════════════════════════════════

-- upsert_videos
DROP FUNCTION IF EXISTS public.upsert_videos(jsonb);
CREATE OR REPLACE FUNCTION public.upsert_videos(videos jsonb) RETURNS void AS $$
DECLARE v jsonb;
BEGIN
  FOR v IN SELECT * FROM jsonb_array_elements(videos)
  LOOP
    INSERT INTO public.videos (video_id, title, thumbnail_url, video_url, author,
      duration, views, monsnode_video_id, source_page, source_section,
      vote_up, vote_down, scraped_at, updated_at, has_mp4, needs_rescrape, mp4_checked_at)
    VALUES (v->>'video_id', v->>'title', v->>'thumbnail_url', v->>'video_url', v->>'author',
      v->>'duration', v->>'views', v->>'monsnode_video_id', v->>'source_page', v->>'source_section',
      COALESCE((v->>'vote_up')::integer, 0), COALESCE((v->>'vote_down')::integer, 0),
      COALESCE((v->>'scraped_at')::timestamptz, NOW()), NOW(),
      COALESCE((v->>'has_mp4')::boolean, false), COALESCE((v->>'needs_rescrape')::boolean, true),
      COALESCE((v->>'mp4_checked_at')::timestamptz, NOW()))
    ON CONFLICT (video_id) DO UPDATE SET
      title = COALESCE(NULLIF(v->>'title', ''), videos.title),
      thumbnail_url = COALESCE(NULLIF(v->>'thumbnail_url', ''), videos.thumbnail_url),
      video_url = COALESCE(NULLIF(v->>'video_url', ''), videos.video_url),
      author = COALESCE(NULLIF(v->>'author', ''), videos.author),
      duration = CASE WHEN (v->>'has_mp4')::boolean AND NULLIF(v->>'duration','') IS NOT NULL THEN v->>'duration' ELSE videos.duration END,
      views = COALESCE(NULLIF(v->>'views', ''), videos.views),
      monsnode_video_id = COALESCE(NULLIF(v->>'monsnode_video_id', ''), videos.monsnode_video_id),
      source_page = COALESCE(NULLIF(v->>'source_page', ''), videos.source_page),
      source_section = CASE
        WHEN COALESCE(videos.source_section, '') = '' THEN COALESCE(NULLIF(v->>'source_section', ''), '')
        WHEN COALESCE(NULLIF(v->>'source_section', ''), '') = '' THEN videos.source_section
        WHEN videos.source_section = (v->>'source_section') THEN videos.source_section
        ELSE videos.source_section || '|' || COALESCE(v->>'source_section', '')
      END,
      scraped_at = COALESCE((v->>'scraped_at')::timestamptz, videos.scraped_at),
      updated_at = NOW(),
      has_mp4 = CASE WHEN (v->>'has_mp4')::boolean THEN true ELSE videos.has_mp4 END,
      needs_rescrape = CASE
        WHEN videos.has_mp4 THEN false
        WHEN (v->>'has_mp4')::boolean THEN false
        ELSE COALESCE((v->>'needs_rescrape')::boolean, true)
      END,
      mp4_checked_at = COALESCE((v->>'mp4_checked_at')::timestamptz, videos.mp4_checked_at);
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.upsert_videos(jsonb) TO anon;
GRANT EXECUTE ON FUNCTION public.upsert_videos(jsonb) TO service_role;

-- increment_retry
DROP FUNCTION IF EXISTS public.increment_retry(TEXT);
CREATE OR REPLACE FUNCTION public.increment_retry(vid TEXT) RETURNS void AS $$
BEGIN
  UPDATE public.videos SET retry_count = COALESCE(retry_count, 0) + 1, updated_at = NOW()
  WHERE video_id = vid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.increment_retry(TEXT) TO anon;

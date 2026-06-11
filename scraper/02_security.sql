-- ═══════════════════════════════════════════
-- 一键执行: 放开所有anon权限 + 修复爬虫覆盖逻辑
-- 复制全部到 Supabase SQL Editor → Run, 可重复执行
-- ═══════════════════════════════════════════

-- ============ 先清理所有旧策略(避免重复执行报错) ============
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT policyname, tablename FROM pg_policies WHERE schemaname = 'public') LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
    END LOOP;
END $$;

-- ============ videos ============
CREATE POLICY "anon_videos_select" ON public.videos FOR SELECT TO anon USING (true);
CREATE POLICY "anon_videos_insert" ON public.videos FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_videos_update" ON public.videos FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_videos_delete" ON public.videos FOR DELETE TO anon USING (true);

-- ============ user_accounts ============
CREATE POLICY "anon_users_select" ON public.user_accounts FOR SELECT TO anon USING (true);
CREATE POLICY "anon_users_insert" ON public.user_accounts FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_users_update" ON public.user_accounts FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_users_delete" ON public.user_accounts FOR DELETE TO anon USING (true);

-- ============ scrape_status ============
CREATE POLICY "anon_scrape_insert" ON public.scrape_status FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_scrape_select" ON public.scrape_status FOR SELECT TO anon USING (true);

-- ============ 其他表全部放开 ============
CREATE POLICY "anon_all_codes" ON public.activation_codes FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_all_logs" ON public.admin_log FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_all_msgs" ON public.messages FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_all_friends" ON public.friends FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_all_ann" ON public.announcements FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_all_cfg" ON public.system_config FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_all_bans" ON public.bans FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_all_cf" ON public.cloud_favorites FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_all_vips" ON public.user_vips FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_all_follows" ON public.user_follows FOR ALL TO anon USING (true) WITH CHECK (true);

-- ============ 修复 upsert_videos: 已解析视频不再被覆盖为待爬 ============
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

-- ============ increment_retry ============
CREATE OR REPLACE FUNCTION public.increment_retry(vid TEXT) RETURNS void AS $$
BEGIN
  UPDATE public.videos SET retry_count = COALESCE(retry_count, 0) + 1, updated_at = NOW()
  WHERE video_id = vid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.increment_retry(TEXT) TO anon;

-- ============ site_pages: 自定义页面(站主管理) ============
CREATE TABLE IF NOT EXISTS public.site_pages (
    slug TEXT PRIMARY KEY,
    title TEXT NOT NULL DEFAULT '',
    content TEXT DEFAULT '',
    created_by TEXT DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
DROP POLICY IF EXISTS "anon_all_pages" ON public.site_pages;
CREATE POLICY "anon_all_pages" ON public.site_pages FOR ALL TO anon USING (true) WITH CHECK (true);

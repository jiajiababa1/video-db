-- ═══════════════════════════════════════════
-- 一键执行: 放开所有anon权限 + 修复爬虫覆盖逻辑
-- 复制全部到 Supabase SQL Editor → Run
-- ═══════════════════════════════════════════

-- ============ videos: 允许anon读写删 ============
DROP POLICY IF EXISTS "anon_select_videos" ON public.videos;
DROP POLICY IF EXISTS "anon_insert_videos" ON public.videos;
DROP POLICY IF EXISTS "anon_update_videos" ON public.videos;
DROP POLICY IF EXISTS "anon_delete_videos" ON public.videos;
DROP POLICY IF EXISTS "service_write_videos" ON public.videos;
DROP POLICY IF EXISTS "允许 service_role 写入视频" ON public.videos;
DROP POLICY IF EXISTS "允许 service_role 更新视频" ON public.videos;
DROP POLICY IF EXISTS "允许 anon 通过 RPC 插入视频" ON public.videos;
DROP POLICY IF EXISTS "允许 anon 通过 RPC 更新视频" ON public.videos;
CREATE POLICY "anon_select_videos" ON public.videos FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_videos" ON public.videos FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_videos" ON public.videos FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_delete_videos" ON public.videos FOR DELETE TO anon USING (true);

-- ============ user_accounts: 允许anon读写删 ============
DROP POLICY IF EXISTS "anon_select_users" ON public.user_accounts;
DROP POLICY IF EXISTS "anon_insert_users" ON public.user_accounts;
DROP POLICY IF EXISTS "anon_update_users" ON public.user_accounts;
DROP POLICY IF EXISTS "anon_delete_users" ON public.user_accounts;
DROP POLICY IF EXISTS "anon_update_self" ON public.user_accounts;
DROP POLICY IF EXISTS "anon 可读写账号" ON public.user_accounts;
CREATE POLICY "anon_select_users" ON public.user_accounts FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_users" ON public.user_accounts FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_users" ON public.user_accounts FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_delete_users" ON public.user_accounts FOR DELETE TO anon USING (true);

-- ============ scrape_status: 允许anon写入 ============
DROP POLICY IF EXISTS "anon_insert_scrape" ON public.scrape_status;
DROP POLICY IF EXISTS "anon 写入状态" ON public.scrape_status;
DROP POLICY IF EXISTS "允许 service_role 写入状态" ON public.scrape_status;
DROP POLICY IF EXISTS "允许 anon 写入状态" ON public.scrape_status;
CREATE POLICY "anon_insert_scrape" ON public.scrape_status FOR INSERT TO anon WITH CHECK (true);

-- ============ 其他表: 全部放开anon ============
DROP POLICY IF EXISTS "anon_select_codes" ON public.activation_codes;
DROP POLICY IF EXISTS "anon_insert_codes" ON public.activation_codes;
DROP POLICY IF EXISTS "anon_update_codes" ON public.activation_codes;
DROP POLICY IF EXISTS "anon_delete_codes" ON public.activation_codes;
CREATE POLICY "anon_all_codes" ON public.activation_codes FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_logs" ON public.admin_log;
DROP POLICY IF EXISTS "anon_insert_logs" ON public.admin_log;
CREATE POLICY "anon_all_logs" ON public.admin_log FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_msgs" ON public.messages;
DROP POLICY IF EXISTS "anon_insert_msgs" ON public.messages;
DROP POLICY IF EXISTS "anon_update_msgs" ON public.messages;
CREATE POLICY "anon_all_msgs" ON public.messages FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_friends" ON public.friends;
DROP POLICY IF EXISTS "anon_insert_friends" ON public.friends;
DROP POLICY IF EXISTS "anon_update_friends" ON public.friends;
DROP POLICY IF EXISTS "anon_delete_friends" ON public.friends;
CREATE POLICY "anon_all_friends" ON public.friends FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_ann" ON public.announcements;
DROP POLICY IF EXISTS "anon_insert_ann" ON public.announcements;
DROP POLICY IF EXISTS "anon_update_ann" ON public.announcements;
DROP POLICY IF EXISTS "anon_delete_ann" ON public.announcements;
CREATE POLICY "anon_all_ann" ON public.announcements FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_cfg" ON public.system_config;
DROP POLICY IF EXISTS "anon_insert_cfg" ON public.system_config;
DROP POLICY IF EXISTS "anon_update_cfg" ON public.system_config;
CREATE POLICY "anon_all_cfg" ON public.system_config FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_bans" ON public.bans;
DROP POLICY IF EXISTS "anon_insert_bans" ON public.bans;
CREATE POLICY "anon_all_bans" ON public.bans FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_cf" ON public.cloud_favorites;
DROP POLICY IF EXISTS "anon_insert_cf" ON public.cloud_favorites;
DROP POLICY IF EXISTS "anon_delete_cf" ON public.cloud_favorites;
CREATE POLICY "anon_all_cf" ON public.cloud_favorites FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_vips" ON public.user_vips;
DROP POLICY IF EXISTS "anon_insert_vips" ON public.user_vips;
CREATE POLICY "anon_all_vips" ON public.user_vips FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_all_follows" ON public.user_follows;
CREATE POLICY "anon_all_follows" ON public.user_follows FOR ALL TO anon USING (true) WITH CHECK (true);

-- ============ 修复 upsert_videos: 不覆盖已解析视频 ============
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

-- ============ increment_retry ============
DROP FUNCTION IF EXISTS public.increment_retry(TEXT);
CREATE OR REPLACE FUNCTION public.increment_retry(vid TEXT) RETURNS void AS $$
BEGIN
  UPDATE public.videos SET retry_count = COALESCE(retry_count, 0) + 1, updated_at = NOW()
  WHERE video_id = vid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.increment_retry(TEXT) TO anon;

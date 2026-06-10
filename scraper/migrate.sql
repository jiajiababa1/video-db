-- 数据库迁移: 非破坏性修复
-- 只在 Supabase SQL Editor 中执行一次
-- 不会删除任何数据, 只添加字段和函数

-- ═══════════════════════════════════════════
-- 1. 添加新字段 (如果不存在)
-- ═══════════════════════════════════════════
ALTER TABLE videos ADD COLUMN IF NOT EXISTS monsnode_video_id TEXT DEFAULT '';
ALTER TABLE videos ADD COLUMN IF NOT EXISTS has_mp4 BOOLEAN DEFAULT false;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS needs_rescrape BOOLEAN DEFAULT false;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS mp4_checked_at TIMESTAMPTZ;

-- ═══════════════════════════════════════════
-- 2. 更新现有数据
-- ═══════════════════════════════════════════
UPDATE videos SET has_mp4 = true WHERE duration LIKE '%video.twimg.com%';
UPDATE videos SET needs_rescrape = true WHERE duration NOT LIKE '%video.twimg.com%' OR duration IS NULL OR duration = '';

-- ═══════════════════════════════════════════
-- 3. 索引
-- ═══════════════════════════════════════════
CREATE INDEX IF NOT EXISTS idx_videos_has_mp4 ON videos(has_mp4);
CREATE INDEX IF NOT EXISTS idx_videos_needs_rescrape ON videos(needs_rescrape);

-- ═══════════════════════════════════════════
-- 4. 核心: UPSERT 函数 (INSERT ON CONFLICT)
--    解决 merge-duplicates 只认主键 id 的问题
--    这个函数用 video_id 的 UNIQUE 约束做冲突检测
-- ═══════════════════════════════════════════
DROP FUNCTION IF EXISTS upsert_videos(jsonb);
CREATE OR REPLACE FUNCTION upsert_videos(videos jsonb) RETURNS void AS $$
DECLARE
  v jsonb;
BEGIN
  FOR v IN SELECT * FROM jsonb_array_elements(videos)
  LOOP
    INSERT INTO videos (
      video_id, title, thumbnail_url, video_url, author,
      duration, views, monsnode_video_id,
      source_page, source_section,
      scraped_at, updated_at,
      has_mp4, needs_rescrape, mp4_checked_at
    ) VALUES (
      v->>'video_id',
      v->>'title',
      v->>'thumbnail_url',
      v->>'video_url',
      v->>'author',
      v->>'duration',
      v->>'views',
      v->>'monsnode_video_id',
      v->>'source_page',
      v->>'source_section',
      COALESCE((v->>'scraped_at')::timestamptz, NOW()),
      NOW(),
      COALESCE((v->>'has_mp4')::boolean, false),
      COALESCE((v->>'needs_rescrape')::boolean, true),
      COALESCE((v->>'mp4_checked_at')::timestamptz, NOW())
    )
    ON CONFLICT (video_id) DO UPDATE SET
      title = COALESCE(NULLIF(v->>'title', ''), videos.title),
      thumbnail_url = COALESCE(NULLIF(v->>'thumbnail_url', ''), videos.thumbnail_url),
      video_url = COALESCE(NULLIF(v->>'video_url', ''), videos.video_url),
      author = COALESCE(NULLIF(v->>'author', ''), videos.author),
      duration = COALESCE(NULLIF(v->>'duration', ''), videos.duration),
      views = COALESCE(NULLIF(v->>'views', ''), videos.views),
      monsnode_video_id = COALESCE(NULLIF(v->>'monsnode_video_id', ''), videos.monsnode_video_id),
      source_page = COALESCE(NULLIF(v->>'source_page', ''), videos.source_page),
      -- 拼接 source_section 而不是覆盖（同一视频可属于多个栏目）
      source_section = CASE
          WHEN COALESCE(videos.source_section, '') = '' THEN COALESCE(NULLIF(v->>'source_section', ''), '')
          WHEN videos.source_section ILIKE '%|' || COALESCE(v->>'source_section', '') || '|%' THEN videos.source_section
          WHEN videos.source_section ILIKE COALESCE(v->>'source_section', '') || '|%' THEN videos.source_section
          WHEN videos.source_section ILIKE '%|' || COALESCE(v->>'source_section', '') THEN videos.source_section
          WHEN videos.source_section = COALESCE(v->>'source_section', '') THEN videos.source_section
          ELSE videos.source_section || '|' || COALESCE(v->>'source_section', '')
      END,
      scraped_at = COALESCE((v->>'scraped_at')::timestamptz, videos.scraped_at),
      updated_at = NOW(),
      has_mp4 = COALESCE((v->>'has_mp4')::boolean, videos.has_mp4),
      needs_rescrape = COALESCE((v->>'needs_rescrape')::boolean, videos.needs_rescrape),
      mp4_checked_at = COALESCE((v->>'mp4_checked_at')::timestamptz, videos.mp4_checked_at);
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 授权
GRANT EXECUTE ON FUNCTION upsert_videos(jsonb) TO anon;
GRANT EXECUTE ON FUNCTION upsert_videos(jsonb) TO service_role;

-- ═══════════════════════════════════════════
-- 5. 批量标记重爬函数
-- ═══════════════════════════════════════════
DROP FUNCTION IF EXISTS mark_rescrape(TEXT[]);
CREATE OR REPLACE FUNCTION mark_rescrape(video_ids TEXT[]) RETURNS void AS $$
BEGIN
  UPDATE videos SET needs_rescrape = true, updated_at = NOW()
  WHERE video_id = ANY(video_ids);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION mark_rescrape(TEXT[]) TO anon;

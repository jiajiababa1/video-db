-- 数据库迁移: 添加视频可播放性检测和重爬标记字段
-- 在 Supabase SQL Editor 中执行

-- 1. 添加新字段 (如果不存在)
ALTER TABLE videos ADD COLUMN IF NOT EXISTS monsnode_video_id TEXT DEFAULT '';
ALTER TABLE videos ADD COLUMN IF NOT EXISTS has_mp4 BOOLEAN DEFAULT false;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS needs_rescrape BOOLEAN DEFAULT false;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS mp4_checked_at TIMESTAMPTZ;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS playable BOOLEAN DEFAULT false;

-- 2. 根据现有数据更新 has_mp4 字段
UPDATE videos SET has_mp4 = true WHERE duration LIKE '%video.twimg.com%';
UPDATE videos SET needs_rescrape = true WHERE duration NOT LIKE '%video.twimg.com%' OR duration IS NULL OR duration = '';

-- 3. 创建索引
CREATE INDEX IF NOT EXISTS idx_videos_has_mp4 ON videos(has_mp4);
CREATE INDEX IF NOT EXISTS idx_videos_needs_rescrape ON videos(needs_rescrape);
CREATE INDEX IF NOT EXISTS idx_videos_playable ON videos(playable);

-- 4. 创建 RPC 函数: 批量标记需要重爬
CREATE OR REPLACE FUNCTION mark_rescrape(video_ids TEXT[]) RETURNS void AS $$
BEGIN
  UPDATE videos SET needs_rescrape = true, updated_at = NOW()
  WHERE video_id = ANY(video_ids);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. 授权 anon 角色调用
GRANT EXECUTE ON FUNCTION mark_rescrape(TEXT[]) TO anon;

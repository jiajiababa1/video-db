-- Supabase 数据库建表 SQL
-- 在 Supabase SQL Editor 中执行此文件

-- 1. 视频主表
CREATE TABLE IF NOT EXISTS videos (
    id          BIGSERIAL PRIMARY KEY,
    video_id    TEXT UNIQUE NOT NULL,          -- monsnode 视频ID (如 v1506575871309589251)
    title       TEXT DEFAULT '',               -- 视频标题
    thumbnail_url TEXT DEFAULT '',             -- 封面图片 URL
    video_url   TEXT DEFAULT '',               -- monsnode 视频页面链接
    author      TEXT DEFAULT '',               -- 作者
    duration    TEXT DEFAULT '',               -- 时长
    views       TEXT DEFAULT '',               -- 播放量
    source_page TEXT DEFAULT '',               -- 从哪个页面抓到的
    created_at  TIMESTAMPTZ DEFAULT NOW(),     -- 首次入库时间
    updated_at  TIMESTAMPTZ DEFAULT NOW()      -- 最后更新时间
);

-- 2. 索引
CREATE INDEX IF NOT EXISTS idx_videos_video_id ON videos(video_id);
CREATE INDEX IF NOT EXISTS idx_videos_created_at ON videos(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_videos_updated_at ON videos(updated_at DESC);

-- 3. 全文搜索索引（用于前端搜索，先启用扩展）
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_videos_title_trgm ON videos USING gin (title gin_trgm_ops);

-- 4. 自动更新 updated_at 的触发器
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

DROP TRIGGER IF EXISTS update_videos_updated_at ON videos;
CREATE TRIGGER update_videos_updated_at
    BEFORE UPDATE ON videos
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- 5. 启用 Row Level Security (RLS)
ALTER TABLE videos ENABLE ROW LEVEL SECURITY;

-- 6. 允许匿名读取 (前端无需登录即可读取)
CREATE POLICY "允许匿名读取"
    ON videos FOR SELECT
    USING (true);

-- 7. 仅允许 service_role 写入 (爬虫使用 service_role key)
CREATE POLICY "允许 service_role 写入"
    ON videos FOR INSERT
    WITH CHECK (true);

CREATE POLICY "允许 service_role 更新"
    ON videos FOR UPDATE
    USING (true)
    WITH CHECK (true);

-- Supabase 数据库建表 SQL v2
-- 在 Supabase SQL Editor 中执行此文件

-- 1. 视频主表
CREATE TABLE IF NOT EXISTS videos (
    id             BIGSERIAL PRIMARY KEY,
    video_id       TEXT UNIQUE NOT NULL,          -- monsnode 视频ID (如 v1506575871309589251)
    title          TEXT DEFAULT '',               -- 视频标题
    thumbnail_url  TEXT DEFAULT '',               -- 封面图片 URL
    video_url      TEXT DEFAULT '',               -- monsnode 视频页面链接
    author         TEXT DEFAULT '',               -- 作者
    duration       TEXT DEFAULT '',               -- redirect URL (monsnode无时长, 复用存redirect.php链接)
    views          TEXT DEFAULT '',               -- 播放量 (monsnode列表页无此数据)
    source_page    TEXT DEFAULT '',               -- 从哪个页面抓到的
    source_section TEXT DEFAULT '',               -- 从哪个栏目抓到 (trending/home/latest)
    scraped_at     TIMESTAMPTZ DEFAULT NOW(),     -- 最后一次抓取时间
    created_at     TIMESTAMPTZ DEFAULT NOW(),     -- 首次入库时间
    updated_at     TIMESTAMPTZ DEFAULT NOW()      -- 最后更新时间
);

-- 2. 爬虫状态表 (记录每次运行结果)
CREATE TABLE IF NOT EXISTS scrape_status (
    id             BIGSERIAL PRIMARY KEY,
    last_run       TIMESTAMPTZ DEFAULT NOW(),
    videos_found   INTEGER DEFAULT 0,
    videos_saved   INTEGER DEFAULT 0,
    pages_crawled  INTEGER DEFAULT 0,
    errors         TEXT DEFAULT '',
    created_at     TIMESTAMPTZ DEFAULT NOW()
);

-- 3. 索引
CREATE INDEX IF NOT EXISTS idx_videos_video_id ON videos(video_id);
CREATE INDEX IF NOT EXISTS idx_videos_created_at ON videos(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_videos_updated_at ON videos(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_videos_source_section ON videos(source_section);
CREATE INDEX IF NOT EXISTS idx_videos_author ON videos(author);

-- 4. 全文搜索索引（用于前端搜索）
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_videos_title_trgm ON videos USING gin (title gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_videos_author_trgm ON videos USING gin (author gin_trgm_ops);

-- 5. 自动更新 updated_at 的触发器
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

-- 6. 启用 Row Level Security (RLS)
ALTER TABLE videos ENABLE ROW LEVEL SECURITY;
ALTER TABLE scrape_status ENABLE ROW LEVEL SECURITY;

-- 7. 允许匿名读取
CREATE POLICY "允许匿名读取视频"
    ON videos FOR SELECT
    USING (true);

CREATE POLICY "允许匿名读取状态"
    ON scrape_status FOR SELECT
    USING (true);

-- 8. service_role 写入策略
CREATE POLICY "允许 service_role 写入视频"
    ON videos FOR INSERT
    WITH CHECK (true);

CREATE POLICY "允许 service_role 更新视频"
    ON videos FOR UPDATE
    USING (true)
    WITH CHECK (true);

CREATE POLICY "允许 service_role 写入状态"
    ON scrape_status FOR INSERT
    WITH CHECK (true);

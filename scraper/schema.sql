-- Supabase 鏁版嵁搴撳缓琛?SQL
-- 鍦?Supabase SQL Editor 涓墽琛屾鏂囦欢

-- 1. 瑙嗛涓昏〃
CREATE TABLE IF NOT EXISTS videos (
    id          BIGSERIAL PRIMARY KEY,
    video_id    TEXT UNIQUE NOT NULL,          -- monsnode 瑙嗛ID (濡?v1506575871309589251)
    title       TEXT DEFAULT '',               -- 瑙嗛鏍囬
    thumbnail_url TEXT DEFAULT '',             -- 灏侀潰鍥剧墖 URL
    video_url   TEXT DEFAULT '',               -- monsnode 瑙嗛椤甸潰閾炬帴
    author      TEXT DEFAULT '',               -- 浣滆€?    duration    TEXT DEFAULT '',               -- 鏃堕暱
    views       TEXT DEFAULT '',               -- 鎾斁閲?    source_page TEXT DEFAULT '',               -- 浠庡摢涓〉闈㈡姄鍒扮殑
    created_at  TIMESTAMPTZ DEFAULT NOW(),     -- 棣栨鍏ュ簱鏃堕棿
    updated_at  TIMESTAMPTZ DEFAULT NOW()      -- 鏈€鍚庢洿鏂版椂闂?);

-- 2. 绱㈠紩
CREATE INDEX IF NOT EXISTS idx_videos_video_id ON videos(video_id);
CREATE INDEX IF NOT EXISTS idx_videos_created_at ON videos(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_videos_updated_at ON videos(updated_at DESC);

-- 3. 鍏ㄦ枃鎼滅储绱㈠紩锛堢敤浜庡墠绔悳绱紝鍏堝惎鐢ㄦ墿灞曪級
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_videos_title_trgm ON videos USING gin (title gin_trgm_ops);

-- 4. 鑷姩鏇存柊 updated_at 鐨勮Е鍙戝櫒
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

-- 5. 鍚敤 Row Level Security (RLS)
ALTER TABLE videos ENABLE ROW LEVEL SECURITY;

-- 6. 鍏佽鍖垮悕璇诲彇 (鍓嶇鏃犻渶鐧诲綍鍗冲彲璇诲彇)
CREATE POLICY "鍏佽鍖垮悕璇诲彇"
    ON videos FOR SELECT
    USING (true);

-- 7. 浠呭厑璁?service_role 鍐欏叆 (鐖櫕浣跨敤 service_role key)
CREATE POLICY "鍏佽 service_role 鍐欏叆"
    ON videos FOR INSERT
    WITH CHECK (true);

CREATE POLICY "鍏佽 service_role 鏇存柊"
    ON videos FOR UPDATE
    USING (true)
    WITH CHECK (true);

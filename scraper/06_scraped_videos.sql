-- scraped_videos: 内置浏览器抓取的视频链接
-- 复制到 Supabase SQL Editor → Run

CREATE TABLE IF NOT EXISTS public.scraped_videos (
    id BIGSERIAL PRIMARY KEY,
    url TEXT DEFAULT '',
    type TEXT DEFAULT 'mp4',
    title TEXT DEFAULT '',
    source_page TEXT DEFAULT '',
    found_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.scraped_videos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_scraped" ON public.scraped_videos;
CREATE POLICY "anon_all_scraped" ON public.scraped_videos FOR ALL TO anon USING (true) WITH CHECK (true);

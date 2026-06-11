-- site_pages: 自定义页面(站主创建/编辑/删除)
-- 复制到 Supabase SQL Editor → Run

CREATE TABLE IF NOT EXISTS public.site_pages (
    slug TEXT PRIMARY KEY,
    title TEXT NOT NULL DEFAULT '',
    content TEXT DEFAULT '',
    created_by TEXT DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.site_pages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_pages" ON public.site_pages;
CREATE POLICY "anon_all_pages" ON public.site_pages FOR ALL TO anon USING (true) WITH CHECK (true);

-- ═══════════════════════════════════════════
-- 📦 01_tables.sql — 所有数据表+索引
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.videos (
    id BIGSERIAL PRIMARY KEY, video_id TEXT UNIQUE NOT NULL, title TEXT DEFAULT '', thumbnail_url TEXT DEFAULT '',
    video_url TEXT DEFAULT '', author TEXT DEFAULT '', duration TEXT DEFAULT '', views TEXT DEFAULT '',
    source_page TEXT DEFAULT '', source_section TEXT DEFAULT '', scraped_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(), updated_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS monsnode_video_id TEXT DEFAULT '';
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS has_mp4 BOOLEAN DEFAULT false;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS needs_rescrape BOOLEAN DEFAULT false;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS mp4_checked_at TIMESTAMPTZ;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS retry_count INTEGER DEFAULT 0;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS vote_up INTEGER DEFAULT 0;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS vote_down INTEGER DEFAULT 0;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS removed BOOLEAN DEFAULT false;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS mp4_url TEXT DEFAULT '';
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS vip_early BOOLEAN DEFAULT false;

CREATE TABLE IF NOT EXISTS public.scrape_status (
    id BIGSERIAL PRIMARY KEY, last_run TIMESTAMPTZ DEFAULT NOW(), videos_found INTEGER DEFAULT 0,
    videos_saved INTEGER DEFAULT 0, pages_crawled INTEGER DEFAULT 0, errors TEXT DEFAULT '',
    mp4_resolved INTEGER DEFAULT 0, created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.user_accounts (
    id SERIAL PRIMARY KEY, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL,
    device_id TEXT DEFAULT '', display_name TEXT DEFAULT '', bio TEXT DEFAULT '',
    vip_level TEXT NOT NULL DEFAULT 'free', is_admin BOOLEAN DEFAULT false,
    verified BOOLEAN DEFAULT false, banned BOOLEAN DEFAULT false, ban_reason TEXT DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW(), last_login TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.user_vips (
    id SERIAL PRIMARY KEY, device_id TEXT UNIQUE NOT NULL, vip_level TEXT NOT NULL DEFAULT 'free',
    is_admin BOOLEAN DEFAULT false, activated_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ, created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.activation_codes (
    id SERIAL PRIMARY KEY, code TEXT UNIQUE NOT NULL, vip_level TEXT NOT NULL,
    max_uses INTEGER DEFAULT 1, used_count INTEGER DEFAULT 0, created_by TEXT DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW(), expires_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.friends (
    user1 TEXT NOT NULL, user2 TEXT NOT NULL, status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW(), PRIMARY KEY (user1, user2)
);

CREATE TABLE IF NOT EXISTS public.messages (
    id SERIAL PRIMARY KEY, from_user TEXT NOT NULL, to_user TEXT NOT NULL,
    content TEXT NOT NULL, is_read BOOLEAN DEFAULT false, created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.announcements (
    id SERIAL PRIMARY KEY, title TEXT NOT NULL, content TEXT NOT NULL,
    created_by TEXT NOT NULL, is_active BOOLEAN DEFAULT true, created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.admin_log (
    id SERIAL PRIMARY KEY, admin_user TEXT NOT NULL, action TEXT NOT NULL,
    target TEXT DEFAULT '', detail TEXT DEFAULT '', created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.bans (
    id SERIAL PRIMARY KEY, username TEXT NOT NULL, reason TEXT DEFAULT '',
    banned_by TEXT NOT NULL, banned_at TIMESTAMPTZ DEFAULT NOW(), unbanned_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.system_config (
    key TEXT PRIMARY KEY, value TEXT DEFAULT '', updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.cloud_favorites (
    id SERIAL PRIMARY KEY, device_id TEXT NOT NULL, video_id TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(), UNIQUE(device_id, video_id)
);

CREATE TABLE IF NOT EXISTS public.user_follows (
    follower TEXT NOT NULL, following TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(), PRIMARY KEY (follower, following)
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_videos_video_id ON videos(video_id);
CREATE INDEX IF NOT EXISTS idx_videos_created_at ON videos(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_videos_author ON videos(author);
CREATE INDEX IF NOT EXISTS idx_videos_has_mp4 ON videos(has_mp4);
CREATE INDEX IF NOT EXISTS idx_videos_needs_rescrape ON videos(needs_rescrape);
CREATE INDEX IF NOT EXISTS idx_user_vips_device ON user_vips(device_id);
CREATE INDEX IF NOT EXISTS idx_activation_codes_code ON activation_codes(code);
CREATE INDEX IF NOT EXISTS idx_accounts_username ON user_accounts(username);
CREATE INDEX IF NOT EXISTS idx_friends_u1 ON friends(user1);
CREATE INDEX IF NOT EXISTS idx_friends_u2 ON friends(user2);
CREATE INDEX IF NOT EXISTS idx_msg_users ON messages(from_user, to_user);
CREATE INDEX IF NOT EXISTS idx_cf_device ON cloud_favorites(device_id);

-- 回填
UPDATE public.videos SET has_mp4 = true WHERE duration LIKE '%video.twimg.com%' AND NOT has_mp4;
UPDATE public.videos SET needs_rescrape = true WHERE (duration NOT LIKE '%video.twimg.com%' OR duration IS NULL OR duration = '') AND NOT needs_rescrape;
UPDATE public.videos SET mp4_url = duration WHERE duration LIKE '%video.twimg.com%' AND (mp4_url IS NULL OR mp4_url = '');

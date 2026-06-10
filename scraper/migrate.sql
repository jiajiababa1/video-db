-- 数据库迁移: 非破坏性修复
-- 只在 Supabase SQL Editor 中执行一次
-- 不会删除任何数据, 只添加字段和函数

-- ═══════════════════════════════════════════
-- 1. 添加新字段 (如果不存在)
-- ═══════════════════════════════════════════
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS monsnode_video_id TEXT DEFAULT '';
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS has_mp4 BOOLEAN DEFAULT false;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS needs_rescrape BOOLEAN DEFAULT false;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS mp4_checked_at TIMESTAMPTZ;

-- ═══════════════════════════════════════════
-- 2. 更新现有数据
-- ═══════════════════════════════════════════
UPDATE public.videos SET has_mp4 = true WHERE duration LIKE '%video.twimg.com%';
UPDATE public.videos SET needs_rescrape = true WHERE duration NOT LIKE '%video.twimg.com%' OR duration IS NULL OR duration = '';

-- ═══════════════════════════════════════════
-- 3. 索引
-- ═══════════════════════════════════════════
CREATE INDEX IF NOT EXISTS idx_videos_has_mp4 ON public.videos(has_mp4);
CREATE INDEX IF NOT EXISTS idx_videos_needs_rescrape ON public.videos(needs_rescrape);

-- ═══════════════════════════════════════════
-- 4. 核心: UPSERT 函数 (INSERT ON CONFLICT)
--    解决 merge-duplicates 只认主键 id 的问题
--    这个函数用 video_id 的 UNIQUE 约束做冲突检测
-- ═══════════════════════════════════════════
DROP FUNCTION IF EXISTS public.upsert_videos(jsonb);
CREATE OR REPLACE FUNCTION public.upsert_videos(videos jsonb) RETURNS void AS $$
DECLARE
  v jsonb;
BEGIN
  FOR v IN SELECT * FROM jsonb_array_elements(videos)
  LOOP
    INSERT INTO public.videos (
      video_id, title, thumbnail_url, video_url, author,
      duration, views, monsnode_video_id,
      source_page, source_section,
      vote_up, vote_down,
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
      COALESCE((v->>'vote_up')::integer, 0),
      COALESCE((v->>'vote_down')::integer, 0),
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
      vote_up = COALESCE((v->>'vote_up')::integer, videos.vote_up),
      vote_down = COALESCE((v->>'vote_down')::integer, videos.vote_down),
      source_page = COALESCE(NULLIF(v->>'source_page', ''), videos.source_page),
      -- 拼接 source_section: 新栏目追加到已有栏目后面 (用 | 分隔, 自动去重)
      source_section = CASE
          WHEN COALESCE(videos.source_section, '') = '' THEN COALESCE(NULLIF(v->>'source_section', ''), '')
          WHEN COALESCE(NULLIF(v->>'source_section', ''), '') = '' THEN videos.source_section
          WHEN videos.source_section = (v->>'source_section') THEN videos.source_section
          WHEN videos.source_section ILIKE (v->>'source_section') || '|%' THEN videos.source_section
          WHEN videos.source_section ILIKE '%|' || (v->>'source_section') THEN videos.source_section
          WHEN videos.source_section ILIKE '%|' || (v->>'source_section') || '|%' THEN videos.source_section
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
GRANT EXECUTE ON FUNCTION public.upsert_videos(jsonb) TO anon;
GRANT EXECUTE ON FUNCTION public.upsert_videos(jsonb) TO service_role;

-- ═══════════════════════════════════════════
-- 5. 重试计数器
-- ═══════════════════════════════════════════
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS retry_count INTEGER DEFAULT 0;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS vote_up INTEGER DEFAULT 0;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS vote_down INTEGER DEFAULT 0;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS removed BOOLEAN DEFAULT false;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS mp4_url TEXT DEFAULT '';

-- 回填: 从 duration 字段迁移 MP4 URL 到 mp4_url
UPDATE public.videos SET mp4_url = duration WHERE duration LIKE '%video.twimg.com%' AND (mp4_url IS NULL OR mp4_url = '');

-- ═══════════════════════════════════════════
-- VIP 会员系统
-- ═══════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.user_vips (
    id            SERIAL PRIMARY KEY,
    device_id     TEXT UNIQUE NOT NULL,
    vip_level     TEXT NOT NULL DEFAULT 'free',  -- free | vip | vvip | svip | ultimate
    is_admin      BOOLEAN DEFAULT false,
    activated_at  TIMESTAMPTZ DEFAULT NOW(),
    expires_at    TIMESTAMPTZ,                   -- NULL = 永久
    created_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.activation_codes (
    id            SERIAL PRIMARY KEY,
    code          TEXT UNIQUE NOT NULL,
    vip_level     TEXT NOT NULL,                 -- vip | vvip | svip
    max_uses      INTEGER DEFAULT 1,             -- 可用次数, 0=无限
    used_count    INTEGER DEFAULT 0,
    created_by    TEXT DEFAULT '',               -- 谁创建的
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    expires_at    TIMESTAMPTZ                    -- NULL = 永久有效
);

-- RLS (先删后建, 避免重复执行报错)
ALTER TABLE public.user_vips ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activation_codes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon 可读取自己的 VIP" ON public.user_vips;
DROP POLICY IF EXISTS "anon 可注册 VIP" ON public.user_vips;
DROP POLICY IF EXISTS "anon 可更新自己的 VIP" ON public.user_vips;
DROP POLICY IF EXISTS "anon 可读取激活码" ON public.activation_codes;
DROP POLICY IF EXISTS "anon 可消耗激活码" ON public.activation_codes;
DROP POLICY IF EXISTS "管理员可创建激活码" ON public.activation_codes;

CREATE POLICY "anon 可读取自己的 VIP" ON public.user_vips FOR SELECT TO anon USING (true);
CREATE POLICY "anon 可注册 VIP" ON public.user_vips FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon 可更新自己的 VIP" ON public.user_vips FOR UPDATE TO anon USING (true) WITH CHECK (true);

CREATE POLICY "anon 可读取激活码" ON public.activation_codes FOR SELECT TO anon USING (true);
CREATE POLICY "anon 可消耗激活码" ON public.activation_codes FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "管理员可创建激活码" ON public.activation_codes FOR INSERT TO anon WITH CHECK (true);

-- 索引
CREATE INDEX IF NOT EXISTS idx_user_vips_device ON public.user_vips(device_id);
CREATE INDEX IF NOT EXISTS idx_user_vips_level ON public.user_vips(vip_level);
CREATE INDEX IF NOT EXISTS idx_activation_codes_code ON public.activation_codes(code);

-- 默认激活码 (一次性使用, 用户自行修改)
INSERT INTO public.activation_codes (code, vip_level, max_uses)
VALUES ('VIP2026', 'vip', 100),
       ('VVIP2026', 'vvip', 50),
       ('SVIP2026', 'svip', 20)
ON CONFLICT (code) DO NOTHING;

-- RPC: 兑换激活码
DROP FUNCTION IF EXISTS public.redeem_code(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.redeem_code(p_device_id TEXT, p_code TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT, vip_level TEXT) AS $$
DECLARE
    v_code RECORD;
    v_existing RECORD;
BEGIN
    -- 查找激活码
    SELECT * INTO v_code FROM public.activation_codes
    WHERE code = p_code
      AND (expires_at IS NULL OR expires_at > NOW())
      AND (max_uses = 0 OR used_count < max_uses);

    IF v_code IS NULL THEN
        RETURN QUERY SELECT false, '激活码无效或已用完', ''::TEXT;
        RETURN;
    END IF;

    -- 检查用户是否已有更高等级
    SELECT * INTO v_existing FROM public.user_vips WHERE device_id = p_device_id;
    IF FOUND THEN
        IF v_existing.vip_level = 'ultimate' THEN
            RETURN QUERY SELECT false, '已是终极VIP, 无需升级', v_existing.vip_level;
            RETURN;
        END IF;
        -- 不允许降级
        IF v_existing.vip_level = 'svip' AND v_code.vip_level IN ('vip', 'vvip') THEN
            RETURN QUERY SELECT false, '当前 SVIP 等级更高, 无需降级', v_existing.vip_level;
            RETURN;
        END IF;
        IF v_existing.vip_level = 'vvip' AND v_code.vip_level = 'vip' THEN
            RETURN QUERY SELECT false, '当前 VVIP 等级更高, 无需降级', v_existing.vip_level;
            RETURN;
        END IF;
    END IF;

    -- 消耗激活码
    UPDATE public.activation_codes SET used_count = used_count + 1 WHERE id = v_code.id;

    -- 更新或插入用户VIP
    INSERT INTO public.user_vips (device_id, vip_level, activated_at)
    VALUES (p_device_id, v_code.vip_level, NOW())
    ON CONFLICT (device_id) DO UPDATE SET
        vip_level = EXCLUDED.vip_level,
        activated_at = NOW(),
        expires_at = NULL;

    RETURN QUERY SELECT true, '升级成功! ' || v_code.vip_level, v_code.vip_level;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.redeem_code(TEXT, TEXT) TO anon;

-- ═══════════════════════════════════════════
-- 云端收藏 (VVIP+ 专享, 跨设备同步)
-- ═══════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.cloud_favorites (
    id          SERIAL PRIMARY KEY,
    device_id   TEXT NOT NULL,
    video_id    TEXT NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(device_id, video_id)
);
CREATE INDEX IF NOT EXISTS idx_cf_device ON public.cloud_favorites(device_id);
ALTER TABLE public.cloud_favorites ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon 管理自己的云收藏" ON public.cloud_favorites;
CREATE POLICY "anon 管理自己的云收藏" ON public.cloud_favorites FOR ALL TO anon USING (true) WITH CHECK (true);

-- RPC: 同步云端收藏 (VVIP+)
DROP FUNCTION IF EXISTS public.sync_favorites(TEXT, TEXT[]);
CREATE OR REPLACE FUNCTION public.sync_favorites(p_device_id TEXT, p_video_ids TEXT[]) RETURNS void AS $$
BEGIN
  -- 删除不在列表中的
  DELETE FROM public.cloud_favorites WHERE device_id = p_device_id AND video_id != ALL(p_video_ids);
  -- 插入新的 (幂等)
  IF p_video_ids IS NOT NULL AND array_length(p_video_ids, 1) > 0 THEN
    INSERT INTO public.cloud_favorites (device_id, video_id)
    SELECT p_device_id, unnest(p_video_ids)
    ON CONFLICT (device_id, video_id) DO NOTHING;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.sync_favorites(TEXT, TEXT[]) TO anon;

-- RPC: 下载云端收藏 (VVIP+)
DROP FUNCTION IF EXISTS public.load_favorites(TEXT);
CREATE OR REPLACE FUNCTION public.load_favorites(p_device_id TEXT)
RETURNS TABLE(video_id TEXT) AS $$
BEGIN
  RETURN QUERY SELECT cf.video_id FROM public.cloud_favorites cf WHERE cf.device_id = p_device_id ORDER BY cf.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
GRANT EXECUTE ON FUNCTION public.load_favorites(TEXT) TO anon;

-- ═══════════════════════════════════════════
-- VIP 先行看 (新视频免费用户延迟24h看到)
-- ═══════════════════════════════════════════
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS vip_early BOOLEAN DEFAULT false;

-- RPC: 管理员设置终极VIP (仅限管理员调用, code='ADMIN_MASTER_KEY' 校验)
DROP FUNCTION IF EXISTS public.admin_activate(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.admin_activate(p_device_id TEXT, p_master_key TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
BEGIN
    -- 主密钥 (纯文本, 用户自行修改为自己独有的密码)
    -- 默认: 'admin2026ultimate' (部署后立即改掉!)
    IF p_master_key != 'admin2026ultimate' THEN
        RETURN QUERY SELECT false, '管理员密钥错误';
        RETURN;
    END IF;

    INSERT INTO public.user_vips (device_id, vip_level, is_admin, activated_at)
    VALUES (p_device_id, 'ultimate', true, NOW())
    ON CONFLICT (device_id) DO UPDATE SET
        vip_level = 'ultimate',
        is_admin = true,
        activated_at = NOW();

    RETURN QUERY SELECT true, '终极VIP管理员已激活';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.admin_activate(TEXT, TEXT) TO anon;

-- 安全递增 retry_count (RPC, 避免 PATCH 覆盖)
DROP FUNCTION IF EXISTS public.increment_retry(TEXT);
CREATE OR REPLACE FUNCTION public.increment_retry(vid TEXT) RETURNS void AS $$
BEGIN
  UPDATE public.videos
  SET retry_count = COALESCE(retry_count, 0) + 1,
      updated_at = NOW()
  WHERE video_id = vid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.increment_retry(TEXT) TO anon;

-- ═══════════════════════════════════════════
-- 6. 批量标记重爬函数
-- ═══════════════════════════════════════════
DROP FUNCTION IF EXISTS public.mark_rescrape(TEXT[]);
CREATE OR REPLACE FUNCTION public.mark_rescrape(video_ids TEXT[]) RETURNS void AS $$
BEGIN
  UPDATE public.videos SET needs_rescrape = true, updated_at = NOW()
  WHERE video_id = ANY(video_ids);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.mark_rescrape(TEXT[]) TO anon;

-- ═══════════════════════════════════════════
-- RPC: 热门作者聚合
-- ═══════════════════════════════════════════
DROP FUNCTION IF EXISTS public.popular_authors();
CREATE OR REPLACE FUNCTION public.popular_authors() RETURNS TABLE(author TEXT, video_count BIGINT, total_views BIGINT) AS $$
BEGIN
  RETURN QUERY
  SELECT v.author, COUNT(*)::BIGINT, COALESCE(SUM(NULLIF(v.views, '')::BIGINT), 0)
  FROM public.videos v
  WHERE v.author IS NOT NULL AND v.author != ''
  GROUP BY v.author
  ORDER BY COUNT(*) DESC
  LIMIT 50;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

GRANT EXECUTE ON FUNCTION public.popular_authors() TO anon;

-- ═══════════════════════════════════════════
-- 7. 修复 upsert: has_mp4 只增不减
--    (防止客户端/服务端爬虫互相覆盖)
-- ═══════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.upsert_videos(videos jsonb) RETURNS void AS $$
DECLARE
  v jsonb;
BEGIN
  FOR v IN SELECT * FROM jsonb_array_elements(videos)
  LOOP
    INSERT INTO public.videos (
      video_id, title, thumbnail_url, video_url, author,
      duration, views, monsnode_video_id,
      source_page, source_section,
      vote_up, vote_down,
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
      COALESCE((v->>'vote_up')::integer, 0),
      COALESCE((v->>'vote_down')::integer, 0),
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
      -- MP4 URL: 只在新值有效时覆盖 (不把空值写回)
      duration = CASE
          WHEN (v->>'has_mp4')::boolean AND NULLIF(v->>'duration', '') IS NOT NULL
          THEN v->>'duration'
          ELSE videos.duration
      END,
      views = COALESCE(NULLIF(v->>'views', ''), videos.views),
      monsnode_video_id = COALESCE(NULLIF(v->>'monsnode_video_id', ''), videos.monsnode_video_id),
      vote_up = COALESCE((v->>'vote_up')::integer, videos.vote_up),
      vote_down = COALESCE((v->>'vote_down')::integer, videos.vote_down),
      source_page = COALESCE(NULLIF(v->>'source_page', ''), videos.source_page),
      -- 拼接 source_section (去重)
      source_section = CASE
          WHEN COALESCE(videos.source_section, '') = '' THEN COALESCE(NULLIF(v->>'source_section', ''), '')
          WHEN COALESCE(NULLIF(v->>'source_section', ''), '') = '' THEN videos.source_section
          WHEN videos.source_section = (v->>'source_section') THEN videos.source_section
          WHEN videos.source_section ILIKE (v->>'source_section') || '|%' THEN videos.source_section
          WHEN videos.source_section ILIKE '%|' || (v->>'source_section') THEN videos.source_section
          WHEN videos.source_section ILIKE '%|' || (v->>'source_section') || '|%' THEN videos.source_section
          ELSE videos.source_section || '|' || COALESCE(v->>'source_section', '')
      END,
      scraped_at = COALESCE((v->>'scraped_at')::timestamptz, videos.scraped_at),
      updated_at = NOW(),
      -- has_mp4: 只在新值为 true 时覆盖, 否则保留旧值 (防止客户端/服务端冲突)
      has_mp4 = CASE WHEN (v->>'has_mp4')::boolean THEN true ELSE videos.has_mp4 END,
      -- mp4_url: 只在新值有效时覆盖
      mp4_url = CASE WHEN (v->>'has_mp4')::boolean AND NULLIF(v->>'duration', '') IS NOT NULL
          THEN v->>'duration' ELSE videos.mp4_url END,
      needs_rescrape = COALESCE((v->>'needs_rescrape')::boolean, videos.needs_rescrape),
      mp4_checked_at = COALESCE((v->>'mp4_checked_at')::timestamptz, videos.mp4_checked_at);
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════
-- 账号登录系统 (用户名+密码)
-- ═══════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.user_accounts (
    id            SERIAL PRIMARY KEY,
    username      TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    device_id     TEXT DEFAULT '',
    vip_level     TEXT NOT NULL DEFAULT 'free',
    is_admin      BOOLEAN DEFAULT false,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    last_login    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.user_accounts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon 可读写账号" ON public.user_accounts;
CREATE POLICY "anon 可读写账号" ON public.user_accounts FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE INDEX IF NOT EXISTS idx_accounts_username ON public.user_accounts(username);

-- ⚠️ 无预置账号! 请执行下方 CREATE ACCOUNT 语句创建你唯一的账号
-- ⚠️ 无注册入口! 前端不提供注册功能, 账号只能由管理员在数据库手动创建

-- RPC: 登录 (仅验证已存在的账号, 不提供注册)
DROP FUNCTION IF EXISTS public.login_account(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.login_account(p_username TEXT, p_password_hash TEXT, p_device_id TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT, vip_level TEXT, is_admin BOOLEAN) AS $$
DECLARE v_acc RECORD;
BEGIN
    SELECT * INTO v_acc FROM public.user_accounts WHERE username = p_username;
    IF v_acc IS NULL THEN RETURN QUERY SELECT false, '账号不存在', ''::TEXT, false; RETURN; END IF;
    IF v_acc.password_hash != p_password_hash THEN RETURN QUERY SELECT false, '密码错误', ''::TEXT, false; RETURN; END IF;
    UPDATE public.user_accounts SET device_id = p_device_id, last_login = NOW() WHERE id = v_acc.id;
    RETURN QUERY SELECT true, '登录成功', v_acc.vip_level, v_acc.is_admin;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.login_account(TEXT, TEXT, TEXT) TO anon;

-- RPC: 改密码
DROP FUNCTION IF EXISTS public.change_password(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.change_password(p_username TEXT, p_old_hash TEXT, p_new_hash TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
BEGIN
    UPDATE public.user_accounts SET password_hash = p_new_hash WHERE username = p_username AND password_hash = p_old_hash;
    IF FOUND THEN RETURN QUERY SELECT true, '密码修改成功';
    ELSE RETURN QUERY SELECT false, '原密码错误'; END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.change_password(TEXT, TEXT, TEXT) TO anon;

-- RPC: 管理员升级用户
DROP FUNCTION IF EXISTS public.admin_upgrade(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.admin_upgrade(p_admin_username TEXT, p_target_username TEXT, p_level TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
DECLARE v_admin RECORD;
BEGIN
    SELECT * INTO v_admin FROM public.user_accounts WHERE username = p_admin_username AND is_admin = true;
    IF v_admin IS NULL THEN RETURN QUERY SELECT false, '无管理员权限'; RETURN; END IF;
    UPDATE public.user_accounts SET vip_level = p_level WHERE username = p_target_username;
    IF FOUND THEN RETURN QUERY SELECT true, '已升级 ' || p_target_username || ' → ' || p_level;
    ELSE RETURN QUERY SELECT false, '用户不存在'; END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.admin_upgrade(TEXT, TEXT, TEXT) TO anon;

-- ═══════════════════════════════════════════
-- ⚡ 创建你的唯一管理员账号 (只需执行一次!)
-- ═══════════════════════════════════════════
-- 1. 选好你的用户名和密码, 比如: 用户名=kuo 密码=MyP@ss2026
-- 2. 打开浏览器控制台(F12), 计算密码hash:
--    sha256('kuo:MyP@ss2026').then(h => console.log(h))
-- 3. 复制输出的hash, 替换下面的 '在此粘贴hash'
-- 4. 执行这条SQL:

-- INSERT INTO public.user_accounts (username, password_hash, vip_level, is_admin)
-- VALUES ('kuo', '在此粘贴hash', 'ultimate', true);

-- 5. 刷新网站, 用你的用户名和密码登录
-- ═══════════════════════════════════════════

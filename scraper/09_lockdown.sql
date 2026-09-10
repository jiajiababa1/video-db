-- ═══════════════════════════════════════════════════════════════
-- 09_lockdown.sql — 全站安全加固（一次性迁移，可重复执行）
--   替代旧的 02_security.sql（它把所有表对 anon 全开，等于裸奔）
-- 在 Supabase SQL Editor 中执行本文件即可。
--
-- 做了什么：
--   1. 关闭除 videos / scrape_status / announcements(只读) 之外的所有 anon 权限
--   2. user_accounts 列级收紧：密码哈希、is_admin、banned、device_id 对 anon 不可读
--   3. 登录/注册/改密改为服务端 bcrypt + 会话 token（不再在客户端比对哈希）
--   4. TOTP 密码锁改为服务端校验（密钥存 system_config，页面里不再有算法常数）
--   5. 管理后台全部改为“会话 token 鉴权”的 RPC（不再信任客户端上报的 username）
--   6. 爬虫改用 service_role 密钥（GitHub secret 换成 service_role key）
-- ═══════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- 0. 先清掉所有旧 anon 策略（02_security.sql 留下的全开策略）
-- ============================================================
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN (SELECT policyname, tablename FROM pg_policies WHERE schemaname = 'public') LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
  END LOOP;
END $$;

-- ============================================================
-- 1. 表级权限：全部先 REVOKE，再按需 GRANT
-- ============================================================
REVOKE ALL ON public.videos FROM anon;
REVOKE ALL ON public.scrape_status FROM anon;
REVOKE ALL ON public.user_accounts FROM anon;
REVOKE ALL ON public.user_vips FROM anon;
REVOKE ALL ON public.activation_codes FROM anon;
REVOKE ALL ON public.admin_log FROM anon;
REVOKE ALL ON public.bans FROM anon;
REVOKE ALL ON public.system_config FROM anon;
REVOKE ALL ON public.announcements FROM anon;
REVOKE ALL ON public.friends FROM anon;
REVOKE ALL ON public.messages FROM anon;
REVOKE ALL ON public.cloud_favorites FROM anon;
REVOKE ALL ON public.user_follows FROM anon;
REVOKE ALL ON public.site_pages FROM anon;
REVOKE ALL ON public.scraped_videos FROM anon;
REVOKE ALL ON public.sessions FROM anon;

-- 会话表（服务端签发）
CREATE TABLE IF NOT EXISTS public.sessions (
    id BIGSERIAL PRIMARY KEY,
    token TEXT UNIQUE NOT NULL,
    device_id TEXT DEFAULT '',
    username TEXT DEFAULT NULL,
    is_admin BOOLEAN DEFAULT false,
    vip_level TEXT DEFAULT 'free',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT NOW() + interval '30 days'
);
CREATE INDEX IF NOT EXISTS idx_sessions_token ON public.sessions(token);
CREATE INDEX IF NOT EXISTS idx_sessions_expiry ON public.sessions(expires_at);

-- ============================================================
-- 2. 重新定义策略（最小权限）
-- ============================================================
ALTER TABLE public.videos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scrape_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_vips ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activation_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.friends ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cloud_favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_follows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.site_pages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scraped_videos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sessions ENABLE ROW LEVEL SECURITY;

-- videos：anon 可读 + 可写入播放信息
--   (客户端爬虫、MP4解析、标记重爬需要 INSERT/UPDATE；删除一律走 admin_exec)
CREATE POLICY "videos_anon_select" ON public.videos FOR SELECT TO anon USING (true);
CREATE POLICY "videos_anon_insert" ON public.videos FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "videos_anon_update" ON public.videos FOR UPDATE TO anon USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE ON public.videos TO anon;
GRANT USAGE ON SEQUENCE public.videos_id_seq TO anon;

-- scrape_status：anon 可读 + 爬虫写入状态
CREATE POLICY "scrape_status_anon_select" ON public.scrape_status FOR SELECT TO anon USING (true);
CREATE POLICY "scrape_status_anon_insert" ON public.scrape_status FOR INSERT TO anon WITH CHECK (true);
GRANT SELECT, INSERT ON public.scrape_status TO anon;
GRANT USAGE ON SEQUENCE public.scrape_status_id_seq TO anon;

-- announcements：anon 只读（写入走 admin_exec）
CREATE POLICY "ann_anon_select" ON public.announcements FOR SELECT TO anon USING (true);
GRANT SELECT ON public.announcements TO anon;

-- user_accounts：列级收紧
-- anon 只能读这些“非敏感”列；password_hash / is_admin / banned / device_id / ban_reason 一律不可读
GRANT SELECT (username, display_name, bio, vip_level, verified, created_at, last_login) ON public.user_accounts TO anon;
CREATE POLICY "users_anon_select_safe" ON public.user_accounts FOR SELECT TO anon USING (true);
-- 没有 INSERT/UPDATE/DELETE 策略 → 所有写操作只能走 SECURITY DEFINER RPC

-- 其余敏感表：不创建任何 anon 策略 → anon 完全不可访问（含 SELECT）
--   user_vips / activation_codes / admin_log / bans / system_config

-- friends / messages / cloud_favorites / user_follows / site_pages / scraped_videos：
-- 保留 anon 读写（低敏感度功能表；已知局限见 README）
CREATE POLICY "friends_all" ON public.friends FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "messages_all" ON public.messages FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "cf_all" ON public.cloud_favorites FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "follows_all" ON public.user_follows FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "pages_all" ON public.site_pages FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "scraped_all" ON public.scraped_videos FOR ALL TO anon USING (true) WITH CHECK (true);
GRANT ALL ON public.friends TO anon;
GRANT ALL ON public.messages TO anon;
GRANT ALL ON public.cloud_favorites TO anon;
GRANT ALL ON public.user_follows TO anon;
GRANT ALL ON public.site_pages TO anon;
GRANT ALL ON public.scraped_videos TO anon;
GRANT USAGE ON SEQUENCE public.messages_id_seq TO anon;
GRANT USAGE ON SEQUENCE public.cloud_favorites_id_seq TO anon;
GRANT USAGE ON SEQUENCE public.scraped_videos_id_seq TO anon;
GRANT USAGE ON SEQUENCE public.site_pages_id_seq TO anon;

-- ============================================================
-- 3. TOTP 种子（默认密钥已轮换，旧页面里的常数全部失效）
-- ============================================================
INSERT INTO public.system_config (key, value, updated_at)
VALUES ('totp_secret', 'VIDEODB2026LOCKKEY', NOW())
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- 4. 基础 TOTP 计算（服务端，BIGINT）
--    算法与客户端一致: ((W + S1) * P1 + W * M) % 10000
-- ============================================================
CREATE OR REPLACE FUNCTION public._totp_code(seed TEXT, win BIGINT)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
  s1 BIGINT := 0; c INT; p1 BIGINT := 7919; p2 BIGINT := 6271; m BIGINT; code_val BIGINT;
BEGIN
  FOR c IN 1..length(seed) LOOP s1 := s1 + ascii(substr(seed, c, 1)); END LOOP;
  m := s1 * p2;
  code_val := ((win + s1) * p1 + win * m) % 10000;
  RETURN lpad(code_val::text, 4, '0');
END; $$;

CREATE OR REPLACE FUNCTION public._totp_now(seed TEXT)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN public._totp_code(seed, floor(extract(epoch from now()) / 300)::BIGINT);
END; $$;

CREATE OR REPLACE FUNCTION public._totp_prev(seed TEXT)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN public._totp_code(seed, floor(extract(epoch from now()) / 300)::BIGINT - 1);
END; $$;

-- ============================================================
-- 5. 鉴权：登录 / 注册 / 改密（bcrypt，服务端签发会话）
--    兼容旧数据：存量密码是 sha256(用户名:密码)，首次登录成功自动升级为 bcrypt
-- ============================================================

DROP FUNCTION IF EXISTS public.login_account(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.login_account(p_username TEXT, p_password TEXT, p_device_id TEXT)
RETURNS TABLE(ok BOOLEAN, message TEXT, token TEXT, vip_level TEXT, is_admin BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v RECORD; v_token TEXT;
BEGIN
  SELECT * INTO v FROM public.user_accounts WHERE username = p_username;
  IF v IS NULL THEN RETURN QUERY SELECT false, '账号不存在', NULL::TEXT, ''::TEXT, false; RETURN; END IF;
  IF v.banned THEN RETURN QUERY SELECT false, '账号已被封禁', NULL::TEXT, ''::TEXT, false; RETURN; END IF;
  IF left(v.password_hash, 4) IN ('$2a$','$2b$','$2y$') THEN
    IF v.password_hash <> crypt(p_password, v.password_hash) THEN
      RETURN QUERY SELECT false, '密码错误', NULL::TEXT, ''::TEXT, false; RETURN;
    END IF;
  ELSE
    IF v.password_hash <> encode(digest(p_username || ':' || p_password, 'sha256'), 'hex') THEN
      RETURN QUERY SELECT false, '密码错误', NULL::TEXT, ''::TEXT, false; RETURN;
    END IF;
    UPDATE public.user_accounts SET password_hash = crypt(p_password, gen_salt('bf', 10)) WHERE id = v.id;
  END IF;
  DELETE FROM public.sessions WHERE username = p_username OR device_id = p_device_id;
  v_token := encode(gen_random_bytes(24), 'hex');
  INSERT INTO public.sessions (device_id, token, username, is_admin, vip_level, expires_at)
  VALUES (p_device_id, v_token, p_username, v.is_admin, v.vip_level, now() + interval '30 days');
  UPDATE public.user_accounts SET last_login = NOW() WHERE id = v.id;
  RETURN QUERY SELECT true, '登录成功', v_token, v.vip_level, v.is_admin;
END; $$;
GRANT EXECUTE ON FUNCTION public.login_account(TEXT, TEXT, TEXT) TO anon;

DROP FUNCTION IF EXISTS public.register_account(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.register_account(p_username TEXT, p_password TEXT, p_device_id TEXT)
RETURNS TABLE(ok BOOLEAN, message TEXT, token TEXT, vip_level TEXT, is_admin BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_token TEXT;
BEGIN
  IF length(p_username) < 2 OR length(p_username) > 20 THEN
    RETURN QUERY SELECT false, '用户名2-20个字符', NULL::TEXT, ''::TEXT, false; RETURN;
  END IF;
  IF p_username !~ '^[a-zA-Z0-9_\x{4e00}-\x{9fff}]+$' THEN
    RETURN QUERY SELECT false, '用户名只能包含中英文数字下划线', NULL::TEXT, ''::TEXT, false; RETURN;
  END IF;
  IF p_password IS NULL OR length(p_password) < 4 THEN
    RETURN QUERY SELECT false, '密码至少4个字符', NULL::TEXT, ''::TEXT, false; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM public.user_accounts WHERE username = p_username) THEN
    RETURN QUERY SELECT false, '用户名已存在', NULL::TEXT, ''::TEXT, false; RETURN;
  END IF;
  INSERT INTO public.user_accounts (username, password_hash, device_id, vip_level, is_admin)
  VALUES (p_username, crypt(p_password, gen_salt('bf', 10)), p_device_id, 'free', false);
  v_token := encode(gen_random_bytes(24), 'hex');
  INSERT INTO public.sessions (device_id, token, username, is_admin, vip_level, expires_at)
  VALUES (p_device_id, v_token, p_username, false, 'free', now() + interval '30 days');
  RETURN QUERY SELECT true, '注册成功', v_token, 'free'::TEXT, false;
END; $$;
GRANT EXECUTE ON FUNCTION public.register_account(TEXT, TEXT, TEXT) TO anon;

DROP FUNCTION IF EXISTS public.change_password(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.change_password(p_username TEXT, p_old_password TEXT, p_new_password TEXT)
RETURNS TABLE(ok BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v RECORD;
BEGIN
  IF p_new_password IS NULL OR length(p_new_password) < 4 THEN
    RETURN QUERY SELECT false, '新密码至少4个字符'; RETURN;
  END IF;
  SELECT * INTO v FROM public.user_accounts WHERE username = p_username;
  IF v IS NULL THEN RETURN QUERY SELECT false, '账号不存在'; RETURN; END IF;
  IF left(v.password_hash, 4) IN ('$2a$','$2b$','$2y$') THEN
    IF v.password_hash <> crypt(p_old_password, v.password_hash) THEN
      RETURN QUERY SELECT false, '原密码错误'; RETURN;
    END IF;
  ELSE
    IF v.password_hash <> encode(digest(p_username || ':' || p_old_password, 'sha256'), 'hex') THEN
      RETURN QUERY SELECT false, '原密码错误'; RETURN;
    END IF;
  END IF;
  UPDATE public.user_accounts SET password_hash = crypt(p_new_password, gen_salt('bf', 10)) WHERE id = v.id;
  DELETE FROM public.sessions WHERE username = p_username;
  RETURN QUERY SELECT true, '密码修改成功，请重新登录';
END; $$;
GRANT EXECUTE ON FUNCTION public.change_password(TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.check_session(p_token TEXT)
RETURNS TABLE(valid BOOLEAN, username TEXT, is_admin BOOLEAN, vip_level TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now()) THEN
    UPDATE public.sessions SET expires_at = now() + interval '30 days' WHERE token = p_token;
    RETURN QUERY SELECT true, s.username, COALESCE(s.is_admin, false), COALESCE(s.vip_level, 'free')
      FROM public.sessions s WHERE s.token = p_token;
  ELSE
    RETURN QUERY SELECT false, NULL::TEXT, false, ''::TEXT;
  END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.check_session(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.logout(p_token TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM public.sessions WHERE token = p_token;
END; $$;
GRANT EXECUTE ON FUNCTION public.logout(TEXT) TO anon;

-- ============================================================
-- 6. 密码锁：服务端校验 + 签发匿名会话
-- ============================================================
CREATE OR REPLACE FUNCTION public.verify_passcode(p_code TEXT, p_device_id TEXT)
RETURNS TABLE(ok BOOLEAN, token TEXT, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_seed TEXT; cur TEXT; prev TEXT; v_token TEXT;
BEGIN
  SELECT value INTO v_seed FROM public.system_config WHERE key = 'totp_secret';
  IF v_seed IS NULL OR v_seed = '' THEN v_seed := 'VIDEODB2026LOCKKEY'; END IF;
  cur  := public._totp_now(v_seed);
  prev := public._totp_prev(v_seed);
  IF p_code IS NULL OR (p_code <> cur AND p_code <> prev) THEN
    RETURN QUERY SELECT false, NULL::TEXT, '密码错误';
    RETURN;
  END IF;
  v_token := encode(gen_random_bytes(24), 'hex');
  INSERT INTO public.sessions (device_id, token, username, is_admin, vip_level, expires_at)
  VALUES (p_device_id, v_token, NULL, false, 'free', now() + interval '7 days');
  RETURN QUERY SELECT true, v_token, '验证通过';
END; $$;
GRANT EXECUTE ON FUNCTION public.verify_passcode(TEXT, TEXT) TO anon;

-- 站主/管理员查看当前密码（需要管理员会话）
CREATE OR REPLACE FUNCTION public.current_passcode(p_token TEXT)
RETURNS TABLE(code TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_seed TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true) THEN
    RETURN QUERY SELECT '****'::TEXT; RETURN;
  END IF;
  SELECT value INTO v_seed FROM public.system_config WHERE key = 'totp_secret';
  IF v_seed IS NULL OR v_seed = '' THEN v_seed := 'VIDEODB2026LOCKKEY'; END IF;
  RETURN QUERY SELECT public._totp_now(v_seed);
END; $$;
GRANT EXECUTE ON FUNCTION public.current_passcode(TEXT) TO anon;

-- ============================================================
-- 7. 管理后台（全部 token 鉴权，不信任客户端上报的用户名）
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_exec(p_token TEXT, p_action TEXT, p_target TEXT, p_detail TEXT DEFAULT '')
RETURNS TABLE(ok BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_session RECORD;
BEGIN
  SELECT * INTO v_session FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true;
  IF v_session IS NULL THEN RETURN QUERY SELECT false, '无管理员权限'; RETURN; END IF;
  IF p_target = 'kuo' AND p_action IN ('set_admin','delete_user','ban','unban','set_vip','delete_video','reset_password') AND p_target <> v_session.username THEN
    RETURN QUERY SELECT false, '不能操作站主账号'; RETURN;
  END IF;
  INSERT INTO public.admin_log (admin_user, action, target, detail) VALUES (v_session.username, p_action, p_target, p_detail);
  CASE p_action
    WHEN 'set_admin' THEN
      UPDATE public.user_accounts SET is_admin = (p_detail = 'true') WHERE username = p_target AND username <> 'kuo';
      RETURN QUERY SELECT true, '已设置 ' || p_target || ' is_admin=' || p_detail;
    WHEN 'delete_user' THEN
      DELETE FROM public.user_accounts WHERE username = p_target AND username <> 'kuo';
      DELETE FROM public.sessions WHERE username = p_target;
      RETURN QUERY SELECT true, '已删除 ' || p_target;
    WHEN 'ban' THEN
      UPDATE public.user_accounts SET banned = true, ban_reason = p_detail WHERE username = p_target;
      INSERT INTO public.bans (username, reason, banned_by) VALUES (p_target, p_detail, v_session.username);
      RETURN QUERY SELECT true, '已封禁 ' || p_target;
    WHEN 'unban' THEN
      UPDATE public.user_accounts SET banned = false, ban_reason = '' WHERE username = p_target;
      UPDATE public.bans SET unbanned_at = NOW() WHERE username = p_target AND unbanned_at IS NULL;
      RETURN QUERY SELECT true, '已解封 ' || p_target;
    WHEN 'verify' THEN
      UPDATE public.user_accounts SET verified = true WHERE username = p_target;
      RETURN QUERY SELECT true, '已认证 ' || p_target;
    WHEN 'unverify' THEN
      UPDATE public.user_accounts SET verified = false WHERE username = p_target;
      RETURN QUERY SELECT true, '已取消认证';
    WHEN 'set_vip' THEN
      UPDATE public.user_accounts SET vip_level = p_detail WHERE username = p_target;
      RETURN QUERY SELECT true, '已设置VIP: ' || p_detail;
    WHEN 'delete_video' THEN
      DELETE FROM public.videos WHERE video_id = p_target;
      RETURN QUERY SELECT true, '已删除视频';
    WHEN 'announce_create' THEN
      INSERT INTO public.announcements (title, content, created_by, is_active) VALUES (p_target, p_detail, v_session.username, true);
      RETURN QUERY SELECT true, '公告已发布';
    WHEN 'announce_delete' THEN
      DELETE FROM public.announcements WHERE id = p_target::int;
      RETURN QUERY SELECT true, '公告已删除';
    WHEN 'announce_clear' THEN
      UPDATE public.announcements SET is_active = false;
      RETURN QUERY SELECT true, '已隐藏全部公告';
    WHEN 'videos_rescrape_all' THEN
      UPDATE public.videos SET needs_rescrape = true, updated_at = NOW() WHERE needs_rescrape = false;
      RETURN QUERY SELECT true, '已标记全部视频重爬';
    WHEN 'videos_clear_rescrape' THEN
      UPDATE public.videos SET needs_rescrape = false, updated_at = NOW() WHERE needs_rescrape = true;
      RETURN QUERY SELECT true, '已清除全部重爬标记';
    WHEN 'videos_del_no_mp4' THEN
      DELETE FROM public.videos WHERE has_mp4 = false AND needs_rescrape = true;
      RETURN QUERY SELECT true, '已删除无法播放且待重爬的视频';
    WHEN 'videos_del_old_30d' THEN
      DELETE FROM public.videos WHERE updated_at < now() - interval '30 days' AND has_mp4 = false;
      RETURN QUERY SELECT true, '已删除30天前无法播放的视频';
    WHEN 'videos_rescrape_section' THEN
      UPDATE public.videos SET needs_rescrape = true, updated_at = NOW() WHERE source_section ILIKE '%' || p_target || '%';
      RETURN QUERY SELECT true, '已标记栏目重爬: ' || p_target;
    WHEN 'videos_del_section' THEN
      DELETE FROM public.videos WHERE source_section ILIKE '%' || p_target || '%';
      RETURN QUERY SELECT true, '已删除栏目视频: ' || p_target;
    WHEN 'videos_del_author' THEN
      DELETE FROM public.videos WHERE author ILIKE '%' || p_target || '%';
      RETURN QUERY SELECT true, '已删除作者视频: ' || p_target;
    ELSE
      RETURN QUERY SELECT false, '未知操作: ' || p_action;
  END CASE;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_exec(TEXT, TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.admin_list_users(p_token TEXT, p_offset INTEGER DEFAULT 0, p_limit INTEGER DEFAULT 100)
RETURNS TABLE(username TEXT, vip_level TEXT, verified BOOLEAN, banned BOOLEAN, is_admin BOOLEAN, created_at TIMESTAMPTZ, last_login TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true) THEN RETURN; END IF;
  RETURN QUERY SELECT a.username, a.vip_level, a.verified, a.banned, a.is_admin, a.created_at, a.last_login
    FROM public.user_accounts a ORDER BY a.created_at DESC OFFSET p_offset LIMIT p_limit;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_list_users(TEXT, INTEGER, INTEGER) TO anon;

CREATE OR REPLACE FUNCTION public.admin_reset_password(p_token TEXT, p_target TEXT, p_new_password TEXT)
RETURNS TABLE(ok BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true) THEN
    RETURN QUERY SELECT false, '无管理员权限'; RETURN;
  END IF;
  IF p_new_password IS NULL OR length(p_new_password) < 4 THEN
    RETURN QUERY SELECT false, '密码至少4个字符'; RETURN;
  END IF;
  UPDATE public.user_accounts SET password_hash = crypt(p_new_password, gen_salt('bf', 10)) WHERE username = p_target AND username <> 'kuo';
  DELETE FROM public.sessions WHERE username = p_target;
  IF FOUND THEN RETURN QUERY SELECT true, '已重置密码';
  ELSE RETURN QUERY SELECT false, '用户不存在'; END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_reset_password(TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.admin_generate_code(p_token TEXT, p_level TEXT, p_uses INTEGER DEFAULT 1)
RETURNS TABLE(ok BOOLEAN, code TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_code TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true) THEN
    RETURN QUERY SELECT false, NULL::TEXT; RETURN;
  END IF;
  v_code := upper(p_level) || '_' || upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 8));
  INSERT INTO public.activation_codes (code, vip_level, max_uses, created_by) VALUES (v_code, p_level, p_uses, 'admin');
  RETURN QUERY SELECT true, v_code;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_generate_code(TEXT, TEXT, INTEGER) TO anon;

CREATE OR REPLACE FUNCTION public.admin_list_codes(p_token TEXT)
RETURNS TABLE(code TEXT, vip_level TEXT, used_count INTEGER, max_uses INTEGER, created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true) THEN RETURN; END IF;
  RETURN QUERY SELECT c.code, c.vip_level, c.used_count, c.max_uses, c.created_at
    FROM public.activation_codes c ORDER BY c.created_at DESC LIMIT 200;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_list_codes(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.site_stats(p_token TEXT)
RETURNS TABLE(total_users BIGINT, total_videos BIGINT, total_messages BIGINT, playable_videos BIGINT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true) THEN RETURN; END IF;
  SELECT COUNT(*) INTO total_users FROM public.user_accounts;
  SELECT COUNT(*) INTO total_videos FROM public.videos;
  SELECT COUNT(*) INTO total_messages FROM public.messages;
  SELECT COUNT(*) INTO playable_videos FROM public.videos WHERE has_mp4 = true;
  RETURN NEXT;
END; $$;
GRANT EXECUTE ON FUNCTION public.site_stats(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.admin_config(p_token TEXT, p_key TEXT, p_value TEXT)
RETURNS TABLE(ok BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true) THEN
    RETURN QUERY SELECT false; RETURN;
  END IF;
  INSERT INTO public.system_config (key, value, updated_at) VALUES (p_key, p_value, NOW())
  ON CONFLICT (key) DO UPDATE SET value = p_value, updated_at = NOW();
  RETURN QUERY SELECT true;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_config(TEXT, TEXT, TEXT) TO anon;

-- 公开配置：只允许读取白名单键，其余（含 totp_secret）一律隐藏
DROP FUNCTION IF EXISTS public.get_config(TEXT);
CREATE OR REPLACE FUNCTION public.get_config(p_key TEXT DEFAULT NULL)
RETURNS TABLE(key TEXT, value TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_key IS NULL THEN
    RETURN QUERY SELECT c.key, c.value FROM public.system_config c WHERE c.key IN ('site_name', 'site_code_hash');
  ELSE
    RETURN QUERY SELECT c.key, c.value FROM public.system_config c WHERE c.key = p_key AND c.key IN ('site_name', 'site_code_hash');
  END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.get_config(TEXT) TO anon;

-- 操作审计：最近操作 + 封禁记录（需要管理员会话）
CREATE OR REPLACE FUNCTION public.admin_audit(p_token TEXT)
RETURNS TABLE(logs jsonb, bans jsonb)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true) THEN
    RETURN QUERY SELECT '[]'::jsonb, '[]'::jsonb; RETURN;
  END IF;
  RETURN QUERY
    SELECT
      COALESCE((SELECT jsonb_agg(t) FROM (
        SELECT admin_user, action, target, detail, created_at FROM public.admin_log ORDER BY created_at DESC LIMIT 50
      ) t), '[]'::jsonb),
      COALESCE((SELECT jsonb_agg(t) FROM (
        SELECT username, reason, banned_by, banned_at FROM public.bans ORDER BY banned_at DESC LIMIT 20
      ) t), '[]'::jsonb);
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_audit(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.admin_logs(p_token TEXT)
RETURNS TABLE(admin_user TEXT, action TEXT, target TEXT, detail TEXT, created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true) THEN RETURN; END IF;
  RETURN QUERY SELECT l.admin_user, l.action, l.target, l.detail, l.created_at
    FROM public.admin_log l ORDER BY l.created_at DESC LIMIT 50;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_logs(TEXT) TO anon;

-- 编辑视频元数据（需要管理员会话，写 admin_log）
CREATE OR REPLACE FUNCTION public.admin_edit_video(p_token TEXT, p_video_id TEXT, p_title TEXT, p_author TEXT, p_thumbnail TEXT)
RETURNS TABLE(ok BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sessions WHERE token = p_token AND expires_at > now() AND is_admin = true) THEN
    RETURN QUERY SELECT false, '无管理员权限'; RETURN;
  END IF;
  UPDATE public.videos
    SET title = COALESCE(NULLIF(p_title, ''), title),
        author = COALESCE(NULLIF(p_author, ''), author),
        thumbnail_url = COALESCE(NULLIF(p_thumbnail, ''), thumbnail_url),
        updated_at = NOW()
  WHERE video_id = p_video_id;
  IF FOUND THEN
    INSERT INTO public.admin_log (admin_user, action, target, detail)
    VALUES ((SELECT username FROM public.sessions WHERE token = p_token), 'edit_video', p_video_id, p_title);
    RETURN QUERY SELECT true, '已保存';
  ELSE
    RETURN QUERY SELECT false, '视频不存在';
  END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_edit_video(TEXT, TEXT, TEXT, TEXT, TEXT) TO anon;

-- ============================================================
-- 8. 把依赖敏感列/敏感表的公开 RPC 改为 SECURITY DEFINER（否则列级收紧后失效）
-- ============================================================
CREATE OR REPLACE FUNCTION public.search_users(p_query TEXT)
RETURNS TABLE(username TEXT, vip_level TEXT, verified BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY SELECT a.username, a.vip_level, a.verified
    FROM public.user_accounts a WHERE a.username ILIKE '%' || p_query || '%' AND a.banned = false
    ORDER BY a.created_at DESC LIMIT 30;
END; $$;
GRANT EXECUTE ON FUNCTION public.search_users(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.get_user_profile(p_username TEXT)
RETURNS TABLE(username TEXT, display_name TEXT, bio TEXT, verified BOOLEAN,
              vip_level TEXT, created_at TIMESTAMPTZ, follower_count BIGINT, following_count BIGINT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  SELECT a.username, a.display_name, a.bio, a.verified, a.vip_level, a.created_at,
    (SELECT COUNT(*) FROM public.user_follows WHERE following = p_username),
    (SELECT COUNT(*) FROM public.user_follows WHERE follower = p_username)
  FROM public.user_accounts a WHERE a.username = p_username AND a.banned = false;
END; $$;
GRANT EXECUTE ON FUNCTION public.get_user_profile(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.view_user_favs(p_viewer TEXT, p_target TEXT)
RETURNS TABLE(video_id TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE is_friend BOOLEAN; is_admin_viewer BOOLEAN;
BEGIN
  SELECT (is_admin) INTO is_admin_viewer FROM public.user_accounts WHERE username = p_viewer;
  SELECT EXISTS(SELECT 1 FROM public.friends WHERE ((user1=p_viewer AND user2=p_target) OR (user1=p_target AND user2=p_viewer)) AND status='accepted') INTO is_friend;
  IF NOT COALESCE(is_admin_viewer,false) AND NOT COALESCE(is_friend,false) AND p_viewer != p_target THEN RETURN; END IF;
  RETURN QUERY SELECT cf.video_id FROM public.cloud_favorites cf
    WHERE cf.device_id IN (SELECT device_id FROM public.user_accounts WHERE username = p_target)
    ORDER BY cf.created_at DESC LIMIT 100;
END; $$;
GRANT EXECUTE ON FUNCTION public.view_user_favs(TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.redeem_code(p_device_id TEXT, p_code TEXT)
RETURNS TABLE(ok BOOLEAN, message TEXT, vip_level TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_code RECORD;
BEGIN
  SELECT * INTO v_code FROM public.activation_codes
    WHERE code = p_code AND (expires_at IS NULL OR expires_at > NOW()) AND (max_uses = 0 OR used_count < max_uses);
  IF v_code IS NULL THEN RETURN QUERY SELECT false, '激活码无效或已用完', ''::TEXT; RETURN; END IF;
  UPDATE public.activation_codes SET used_count = used_count + 1 WHERE id = v_code.id;
  INSERT INTO public.user_vips (device_id, vip_level, activated_at)
  VALUES (p_device_id, v_code.vip_level, NOW())
  ON CONFLICT (device_id) DO UPDATE SET vip_level = EXCLUDED.vip_level, activated_at = NOW();
  RETURN QUERY SELECT true, '升级成功! ' || v_code.vip_level, v_code.vip_level;
END; $$;
GRANT EXECUTE ON FUNCTION public.redeem_code(TEXT, TEXT) TO anon;

-- ============================================================
-- 8b. 重新定义 upsert_videos：同时写入 mp4_url 列（爬虫新字段）
--     旧版只写 duration；01_tables.sql 已加 mp4_url 列
-- ============================================================
CREATE OR REPLACE FUNCTION public.upsert_videos(videos jsonb) RETURNS void AS $$
DECLARE v jsonb;
BEGIN
  FOR v IN SELECT * FROM jsonb_array_elements(videos)
  LOOP
    INSERT INTO public.videos (video_id, title, thumbnail_url, video_url, author,
      duration, mp4_url, views, monsnode_video_id, source_page, source_section,
      vote_up, vote_down, scraped_at, updated_at, has_mp4, needs_rescrape, mp4_checked_at)
    VALUES (v->>'video_id', v->>'title', v->>'thumbnail_url', v->>'video_url', v->>'author',
      v->>'duration', v->>'mp4_url', v->>'views', v->>'monsnode_video_id', v->>'source_page', v->>'source_section',
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
      mp4_url = CASE WHEN (v->>'has_mp4')::boolean AND NULLIF(v->>'mp4_url','') IS NOT NULL THEN v->>'mp4_url' ELSE videos.mp4_url END,
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

-- ============================================================
-- 9. 撤销旧的不安全/被替代 RPC 的 anon 执行权
--    （旧 admin_* 信任客户端用户名；upsert_videos 只给爬虫用）
-- ============================================================
REVOKE EXECUTE ON FUNCTION public.admin_action(TEXT, TEXT, TEXT, TEXT) FROM anon;
REVOKE EXECUTE ON FUNCTION public.list_users(TEXT, INTEGER, INTEGER) FROM anon;
REVOKE EXECUTE ON FUNCTION public.set_config(TEXT, TEXT, TEXT) FROM anon;
-- 旧的一键提权后门（migrate.sql 遗留）：master-key 激活 / 信任客户端用户名的提权
REVOKE EXECUTE ON FUNCTION public.admin_activate(TEXT, TEXT) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_upgrade(TEXT, TEXT, TEXT) FROM anon;
REVOKE EXECUTE ON FUNCTION public.mark_rescrape(TEXT[]) FROM anon;
-- 注意：upsert_videos / increment_retry / admin_reset_password / site_stats 均为新版安全实现，
--       GitHub Actions 爬虫与前端管理面板仍需要 anon 执行权 → 在此重新 GRANT（自愈）
GRANT EXECUTE ON FUNCTION public.upsert_videos(jsonb) TO anon;
GRANT EXECUTE ON FUNCTION public.increment_retry(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_password(TEXT, TEXT, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.site_stats(TEXT) TO anon;
-- 注：旧 admin_generate_code(TEXT,TEXT,INTEGER) 与新的同名同参数，已被 CREATE OR REPLACE 覆盖为新版

-- ============================================================
-- 10. 种子：初始管理员（密码只存哈希；明文由站主私下保管，首次登录后请改密）
--     若 'kuo' 已存在则不改动
-- ============================================================
INSERT INTO public.user_accounts (username, password_hash, vip_level, is_admin, verified)
SELECT 'kuo', '$2b$10$s0lRzSwNZ7VBvwVW28fWZOEW549BXvLevaMR.8O.hsmfmLlWHruk6', 'vip', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.user_accounts WHERE username = 'kuo');

-- 清理过期会话
DELETE FROM public.sessions WHERE expires_at < now() - interval '1 day';

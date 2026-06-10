-- ═══════════════════════════════════════════
-- 所有 RPC + GRANT — 复制此文件到 Supabase SQL Editor 点 Run
-- ═══════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.login_account(p_username TEXT, p_password_hash TEXT, p_device_id TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT, vip_level TEXT, is_admin BOOLEAN)
LANGUAGE plpgsql AS $$ DECLARE v_acc RECORD;
BEGIN
  SELECT * INTO v_acc FROM public.user_accounts WHERE username = p_username;
  IF v_acc IS NULL THEN RETURN QUERY SELECT false, '账号不存在', ''::TEXT, false; RETURN; END IF;
  IF v_acc.banned THEN RETURN QUERY SELECT false, '账号已被封禁', ''::TEXT, false; RETURN; END IF;
  IF v_acc.password_hash != p_password_hash THEN RETURN QUERY SELECT false, '密码错误', ''::TEXT, false; RETURN; END IF;
  UPDATE public.user_accounts SET device_id = p_device_id, last_login = NOW() WHERE id = v_acc.id;
  RETURN QUERY SELECT true, '登录成功', v_acc.vip_level, v_acc.is_admin;
END; $$;
GRANT EXECUTE ON FUNCTION public.login_account(TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.register_account(p_username TEXT, p_password_hash TEXT, p_device_id TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT, vip_level TEXT, is_admin BOOLEAN)
LANGUAGE plpgsql AS $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.user_accounts WHERE username = p_username) THEN
    RETURN QUERY SELECT false, '用户名已存在', ''::TEXT, false; RETURN;
  END IF;
  INSERT INTO public.user_accounts (username, password_hash, device_id, vip_level, is_admin)
  VALUES (p_username, p_password_hash, p_device_id, 'free', false);
  RETURN QUERY SELECT true, '注册成功', 'free'::TEXT, false;
END; $$;
GRANT EXECUTE ON FUNCTION public.register_account(TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.change_password(p_username TEXT, p_old_hash TEXT, p_new_hash TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT)
LANGUAGE plpgsql AS $$ BEGIN
  UPDATE public.user_accounts SET password_hash = p_new_hash
  WHERE username = p_username AND password_hash = p_old_hash;
  IF FOUND THEN RETURN QUERY SELECT true, '密码修改成功';
  ELSE RETURN QUERY SELECT false, '原密码错误'; END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.change_password(TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.admin_action(p_admin TEXT, p_action TEXT, p_target TEXT, p_detail TEXT DEFAULT '')
RETURNS TABLE(success BOOLEAN, message TEXT)
LANGUAGE plpgsql AS $$ DECLARE v_admin RECORD; v_target RECORD;
BEGIN
  SELECT * INTO v_admin FROM public.user_accounts WHERE username = p_admin AND is_admin = true AND banned = false;
  IF v_admin IS NULL THEN RETURN QUERY SELECT false, '无管理员权限'; RETURN; END IF;
  SELECT * INTO v_target FROM public.user_accounts WHERE username = p_target;
  IF v_target IS NOT NULL AND v_target.is_admin = true AND p_action IN ('ban','unban','set_vip','unverify') THEN
    RETURN QUERY SELECT false, '不能操作管理员账号'; RETURN;
  END IF;
  INSERT INTO public.admin_log (admin_user, action, target, detail) VALUES (p_admin, p_action, p_target, p_detail);
  IF p_action = 'ban' THEN
    UPDATE public.user_accounts SET banned = true, ban_reason = p_detail WHERE username = p_target AND is_admin = false;
    INSERT INTO public.bans (username, reason, banned_by) VALUES (p_target, p_detail, p_admin);
    RETURN QUERY SELECT true, '已封禁 ' || p_target;
  ELSIF p_action = 'unban' THEN
    UPDATE public.user_accounts SET banned = false, ban_reason = '' WHERE username = p_target;
    UPDATE public.bans SET unbanned_at = NOW() WHERE username = p_target AND unbanned_at IS NULL;
    RETURN QUERY SELECT true, '已解封 ' || p_target;
  ELSIF p_action = 'verify' THEN
    UPDATE public.user_accounts SET verified = true WHERE username = p_target;
    RETURN QUERY SELECT true, '已认证 ' || p_target;
  ELSIF p_action = 'unverify' THEN
    UPDATE public.user_accounts SET verified = false WHERE username = p_target AND is_admin = false;
    RETURN QUERY SELECT true, '已取消认证';
  ELSIF p_action = 'set_vip' THEN
    UPDATE public.user_accounts SET vip_level = p_detail WHERE username = p_target AND is_admin = false;
    RETURN QUERY SELECT true, '已设置VIP: ' || p_detail;
  ELSIF p_action = 'delete_video' THEN
    DELETE FROM public.videos WHERE video_id = p_target;
    RETURN QUERY SELECT true, '已删除';
  ELSE
    RETURN QUERY SELECT false, '未知操作';
  END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_action(TEXT, TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.admin_generate_code(p_admin TEXT, p_level TEXT, p_uses INTEGER DEFAULT 1)
RETURNS TABLE(success BOOLEAN, code TEXT)
LANGUAGE plpgsql AS $$ DECLARE v_admin RECORD; v_code TEXT;
BEGIN
  SELECT * INTO v_admin FROM public.user_accounts WHERE username = p_admin AND is_admin = true;
  IF v_admin IS NULL THEN RETURN QUERY SELECT false, '无管理员权限'::TEXT; RETURN; END IF;
  v_code := upper(p_level) || '_' || upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 8));
  INSERT INTO public.activation_codes (code, vip_level, max_uses, created_by) VALUES (v_code, p_level, p_uses, p_admin);
  RETURN QUERY SELECT true, v_code;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_generate_code(TEXT, TEXT, INTEGER) TO anon;

CREATE OR REPLACE FUNCTION public.list_users(p_admin TEXT, p_offset INTEGER DEFAULT 0, p_limit INTEGER DEFAULT 50)
RETURNS TABLE(username TEXT, vip_level TEXT, verified BOOLEAN, banned BOOLEAN, created_at TIMESTAMPTZ, last_login TIMESTAMPTZ)
LANGUAGE plpgsql AS $$ DECLARE v_admin RECORD;
BEGIN
  SELECT * INTO v_admin FROM public.user_accounts WHERE username = p_admin AND is_admin = true;
  IF v_admin IS NULL THEN RETURN; END IF;
  RETURN QUERY SELECT a.username, a.vip_level, a.verified, a.banned, a.created_at, a.last_login
  FROM public.user_accounts a ORDER BY a.created_at DESC OFFSET p_offset LIMIT p_limit;
END; $$;
GRANT EXECUTE ON FUNCTION public.list_users(TEXT, INTEGER, INTEGER) TO anon;

CREATE OR REPLACE FUNCTION public.add_friend(p_from TEXT, p_to TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT)
LANGUAGE plpgsql AS $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.friends WHERE user1 = p_from AND user2 = p_to) THEN
    RETURN QUERY SELECT false, '已发送过请求';
  ELSE
    INSERT INTO public.friends (user1, user2) VALUES (p_from, p_to);
    RETURN QUERY SELECT true, '好友请求已发送';
  END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.add_friend(TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.handle_friend(p_user TEXT, p_from TEXT, p_action TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT)
LANGUAGE plpgsql AS $$ BEGIN
  IF p_action = 'accept' THEN
    UPDATE public.friends SET status = 'accepted' WHERE user1 = p_from AND user2 = p_user;
    RETURN QUERY SELECT true, '已接受';
  ELSE
    DELETE FROM public.friends WHERE user1 = p_from AND user2 = p_user;
    RETURN QUERY SELECT true, '已拒绝';
  END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.handle_friend(TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.get_friend_requests(p_user TEXT)
RETURNS TABLE(from_user TEXT)
LANGUAGE plpgsql AS $$ BEGIN
  RETURN QUERY SELECT f.user1 FROM public.friends f WHERE f.user2 = p_user AND f.status = 'pending';
END; $$;
GRANT EXECUTE ON FUNCTION public.get_friend_requests(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.send_message(p_from TEXT, p_to TEXT, p_content TEXT)
RETURNS TABLE(success BOOLEAN)
LANGUAGE plpgsql AS $$ BEGIN
  INSERT INTO public.messages (from_user, to_user, content) VALUES (p_from, p_to, p_content);
  RETURN QUERY SELECT true;
END; $$;
GRANT EXECUTE ON FUNCTION public.send_message(TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.get_messages(p_user TEXT, p_with TEXT, p_limit INTEGER DEFAULT 50)
RETURNS TABLE(id INTEGER, from_user TEXT, to_user TEXT, content TEXT, is_read BOOLEAN, created_at TIMESTAMPTZ)
LANGUAGE plpgsql AS $$ BEGIN
  UPDATE public.messages SET is_read = true WHERE to_user = p_user AND from_user = p_with AND NOT is_read;
  RETURN QUERY SELECT m.id, m.from_user, m.to_user, m.content, m.is_read, m.created_at
  FROM public.messages m
  WHERE (m.from_user = p_user AND m.to_user = p_with) OR (m.from_user = p_with AND m.to_user = p_user)
  ORDER BY m.created_at DESC LIMIT p_limit;
END; $$;
GRANT EXECUTE ON FUNCTION public.get_messages(TEXT, TEXT, INTEGER) TO anon;

CREATE OR REPLACE FUNCTION public.unread_count(p_user TEXT)
RETURNS TABLE(cnt BIGINT)
LANGUAGE plpgsql AS $$ BEGIN
  RETURN QUERY SELECT COUNT(*)::BIGINT FROM public.messages WHERE to_user = p_user AND NOT is_read;
END; $$;
GRANT EXECUTE ON FUNCTION public.unread_count(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.search_users(p_query TEXT)
RETURNS TABLE(username TEXT, vip_level TEXT, verified BOOLEAN)
LANGUAGE plpgsql AS $$ BEGIN
  RETURN QUERY SELECT a.username, a.vip_level, a.verified
  FROM public.user_accounts a WHERE a.username ILIKE '%' || p_query || '%' AND a.banned = false
  ORDER BY a.created_at DESC LIMIT 30;
END; $$;
GRANT EXECUTE ON FUNCTION public.search_users(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.get_user_profile(p_username TEXT)
RETURNS TABLE(username TEXT, display_name TEXT, bio TEXT, verified BOOLEAN,
              vip_level TEXT, created_at TIMESTAMPTZ, follower_count BIGINT, following_count BIGINT)
LANGUAGE plpgsql AS $$ BEGIN
  RETURN QUERY
  SELECT a.username, a.display_name, a.bio, a.verified, a.vip_level, a.created_at,
    (SELECT COUNT(*) FROM public.user_follows WHERE following = p_username),
    (SELECT COUNT(*) FROM public.user_follows WHERE follower = p_username)
  FROM public.user_accounts a WHERE a.username = p_username AND a.banned = false;
END; $$;
GRANT EXECUTE ON FUNCTION public.get_user_profile(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.view_user_favs(p_viewer TEXT, p_target TEXT)
RETURNS TABLE(video_id TEXT)
LANGUAGE plpgsql AS $$ DECLARE is_friend BOOLEAN; is_admin_viewer BOOLEAN;
BEGIN
  SELECT (is_admin) INTO is_admin_viewer FROM public.user_accounts WHERE username = p_viewer;
  SELECT EXISTS(SELECT 1 FROM public.friends WHERE ((user1=p_viewer AND user2=p_target) OR (user1=p_target AND user2=p_viewer)) AND status='accepted') INTO is_friend;
  IF NOT is_admin_viewer AND NOT is_friend AND p_viewer != p_target THEN RETURN; END IF;
  RETURN QUERY SELECT cf.video_id FROM public.cloud_favorites cf
  WHERE cf.device_id IN (SELECT device_id FROM public.user_accounts WHERE username = p_target)
  ORDER BY cf.created_at DESC LIMIT 100;
END; $$;
GRANT EXECUTE ON FUNCTION public.view_user_favs(TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.admin_reset_password(p_admin TEXT, p_target TEXT, p_new_hash TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT)
LANGUAGE plpgsql AS $$ DECLARE v_admin RECORD;
BEGIN
  SELECT * INTO v_admin FROM public.user_accounts WHERE username = p_admin AND is_admin = true AND banned = false;
  IF v_admin IS NULL THEN RETURN QUERY SELECT false, '无管理员权限'; RETURN; END IF;
  UPDATE public.user_accounts SET password_hash = p_new_hash WHERE username = p_target AND is_admin = false;
  IF FOUND THEN RETURN QUERY SELECT true, '已重置密码';
  ELSE RETURN QUERY SELECT false, '用户不存在'; END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_reset_password(TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.site_stats(p_admin TEXT)
RETURNS TABLE(total_users BIGINT, total_videos BIGINT, total_messages BIGINT, playable_videos BIGINT)
LANGUAGE plpgsql AS $$ DECLARE v_admin RECORD;
BEGIN
  SELECT * INTO v_admin FROM public.user_accounts WHERE username = p_admin AND is_admin = true;
  IF v_admin IS NULL THEN RETURN; END IF;
  SELECT COUNT(*) INTO total_users FROM public.user_accounts;
  SELECT COUNT(*) INTO total_videos FROM public.videos;
  SELECT COUNT(*) INTO total_messages FROM public.messages;
  SELECT COUNT(*) INTO playable_videos FROM public.videos WHERE has_mp4 = true;
  RETURN NEXT;
END; $$;
GRANT EXECUTE ON FUNCTION public.site_stats(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.get_config(p_key TEXT DEFAULT NULL)
RETURNS TABLE(key TEXT, value TEXT)
LANGUAGE plpgsql AS $$ BEGIN
  IF p_key IS NULL THEN
    RETURN QUERY SELECT c.key, c.value FROM public.system_config c;
  ELSE
    RETURN QUERY SELECT c.key, c.value FROM public.system_config c WHERE c.key = p_key;
  END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.get_config(TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.set_config(p_admin TEXT, p_key TEXT, p_value TEXT)
RETURNS TABLE(success BOOLEAN)
LANGUAGE plpgsql AS $$ DECLARE v_admin RECORD;
BEGIN
  SELECT * INTO v_admin FROM public.user_accounts WHERE username = p_admin AND is_admin = true;
  IF v_admin IS NULL THEN RETURN; END IF;
  INSERT INTO public.system_config (key, value, updated_at) VALUES (p_key, p_value, NOW())
  ON CONFLICT (key) DO UPDATE SET value = p_value, updated_at = NOW();
  RETURN QUERY SELECT true;
END; $$;
GRANT EXECUTE ON FUNCTION public.set_config(TEXT, TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION public.popular_authors()
RETURNS TABLE(author TEXT, video_count BIGINT, total_views BIGINT)
LANGUAGE plpgsql AS $$ BEGIN
  RETURN QUERY SELECT v.author, COUNT(*)::BIGINT, COALESCE(SUM(NULLIF(v.views, '')::BIGINT), 0)
  FROM public.videos v WHERE v.author IS NOT NULL AND v.author != ''
  GROUP BY v.author ORDER BY COUNT(*) DESC LIMIT 50;
END; $$;
GRANT EXECUTE ON FUNCTION public.popular_authors() TO anon;

CREATE OR REPLACE FUNCTION public.redeem_code(p_device_id TEXT, p_code TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT, vip_level TEXT)
LANGUAGE plpgsql AS $$ DECLARE v_code RECORD;
BEGIN
  SELECT * INTO v_code FROM public.activation_codes
  WHERE code = p_code AND (expires_at IS NULL OR expires_at > NOW())
    AND (max_uses = 0 OR used_count < max_uses);
  IF v_code IS NULL THEN RETURN QUERY SELECT false, '激活码无效或已用完', ''::TEXT; RETURN; END IF;
  UPDATE public.activation_codes SET used_count = used_count + 1 WHERE id = v_code.id;
  INSERT INTO public.user_vips (device_id, vip_level, activated_at)
  VALUES (p_device_id, v_code.vip_level, NOW())
  ON CONFLICT (device_id) DO UPDATE SET vip_level = EXCLUDED.vip_level, activated_at = NOW();
  RETURN QUERY SELECT true, '升级成功! ' || v_code.vip_level, v_code.vip_level;
END; $$;
GRANT EXECUTE ON FUNCTION public.redeem_code(TEXT, TEXT) TO anon;

-- ═══════════════════════════════════════════
-- 好友 + 私信 + 系统配置 + 管理员功能
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.friends (
    user1 TEXT NOT NULL, user2 TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user1, user2)
);
ALTER TABLE public.friends ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon 管理好友" ON public.friends;
CREATE POLICY "anon 管理好友" ON public.friends FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE TABLE IF NOT EXISTS public.messages (
    id SERIAL PRIMARY KEY,
    from_user TEXT NOT NULL, to_user TEXT NOT NULL,
    content TEXT NOT NULL, is_read BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon 管理私信" ON public.messages;
CREATE POLICY "anon 管理私信" ON public.messages FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE INDEX IF NOT EXISTS idx_msg_users ON public.messages(from_user, to_user);
CREATE INDEX IF NOT EXISTS idx_msg_time ON public.messages(created_at DESC);

CREATE TABLE IF NOT EXISTS public.system_config (
    key TEXT PRIMARY KEY, value TEXT DEFAULT '',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.system_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon 管理配置" ON public.system_config;
CREATE POLICY "anon 管理配置" ON public.system_config FOR ALL TO anon USING (true) WITH CHECK (true);
INSERT INTO public.system_config (key, value) VALUES ('site_name', 'VideoDB') ON CONFLICT (key) DO NOTHING;
INSERT INTO public.system_config (key, value) VALUES ('announce_text', '') ON CONFLICT (key) DO NOTHING;

-- RPC: 添加好友
DROP FUNCTION IF EXISTS public.add_friend(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.add_friend(p_from TEXT, p_to TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.friends WHERE user1=p_from AND user2=p_to) THEN
    RETURN QUERY SELECT false, '已发送过请求';
  ELSE
    INSERT INTO public.friends (user1, user2) VALUES (p_from, p_to);
    RETURN QUERY SELECT true, '好友请求已发送';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.add_friend(TEXT, TEXT) TO anon;

-- RPC: 处理好友请求
DROP FUNCTION IF EXISTS public.handle_friend(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.handle_friend(p_user TEXT, p_from TEXT, p_action TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
BEGIN
  IF p_action = 'accept' THEN
    UPDATE public.friends SET status='accepted' WHERE user1=p_from AND user2=p_user;
    RETURN QUERY SELECT true, '已接受';
  ELSE
    DELETE FROM public.friends WHERE user1=p_from AND user2=p_user;
    RETURN QUERY SELECT true, '已拒绝';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.handle_friend(TEXT, TEXT, TEXT) TO anon;

-- RPC: 好友列表
DROP FUNCTION IF EXISTS public.get_friends(TEXT);
CREATE OR REPLACE FUNCTION public.get_friends(p_user TEXT)
RETURNS TABLE(friend_username TEXT) AS $$
BEGIN
  RETURN QUERY SELECT f.user2 FROM public.friends f WHERE f.user1=p_user AND f.status='accepted'
  UNION SELECT f.user1 FROM public.friends f WHERE f.user2=p_user AND f.status='accepted';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
GRANT EXECUTE ON FUNCTION public.get_friends(TEXT) TO anon;

-- RPC: 好友请求列表
DROP FUNCTION IF EXISTS public.get_friend_requests(TEXT);
CREATE OR REPLACE FUNCTION public.get_friend_requests(p_user TEXT)
RETURNS TABLE(from_user TEXT) AS $$
BEGIN
  RETURN QUERY SELECT f.user1 FROM public.friends f WHERE f.user2=p_user AND f.status='pending';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
GRANT EXECUTE ON FUNCTION public.get_friend_requests(TEXT) TO anon;

-- RPC: 发私信
DROP FUNCTION IF EXISTS public.send_message(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.send_message(p_from TEXT, p_to TEXT, p_content TEXT)
RETURNS TABLE(success BOOLEAN) AS $$
BEGIN
  INSERT INTO public.messages (from_user, to_user, content) VALUES (p_from, p_to, p_content);
  RETURN QUERY SELECT true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.send_message(TEXT, TEXT, TEXT) TO anon;

-- RPC: 获取私信
DROP FUNCTION IF EXISTS public.get_messages(TEXT, TEXT, INTEGER);
CREATE OR REPLACE FUNCTION public.get_messages(p_user TEXT, p_with TEXT, p_limit INTEGER DEFAULT 50)
RETURNS TABLE(id INTEGER, from_user TEXT, to_user TEXT, content TEXT, is_read BOOLEAN, created_at TIMESTAMPTZ) AS $$
BEGIN
  UPDATE public.messages SET is_read=true WHERE to_user=p_user AND from_user=p_with AND NOT is_read;
  RETURN QUERY SELECT m.id,m.from_user,m.to_user,m.content,m.is_read,m.created_at
  FROM public.messages m WHERE (m.from_user=p_user AND m.to_user=p_with) OR (m.from_user=p_with AND m.to_user=p_user)
  ORDER BY m.created_at DESC LIMIT p_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.get_messages(TEXT, TEXT, INTEGER) TO anon;

-- RPC: 未读私信数
DROP FUNCTION IF EXISTS public.unread_count(TEXT);
CREATE OR REPLACE FUNCTION public.unread_count(p_user TEXT)
RETURNS TABLE(cnt BIGINT) AS $$
BEGIN RETURN QUERY SELECT COUNT(*)::BIGINT FROM public.messages WHERE to_user=p_user AND NOT is_read; END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
GRANT EXECUTE ON FUNCTION public.unread_count(TEXT) TO anon;

-- RPC: 查看用户收藏
DROP FUNCTION IF EXISTS public.view_user_favs(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.view_user_favs(p_viewer TEXT, p_target TEXT)
RETURNS TABLE(video_id TEXT) AS $$
DECLARE is_friend BOOLEAN; is_admin_viewer BOOLEAN;
BEGIN
  SELECT (is_admin) INTO is_admin_viewer FROM public.user_accounts WHERE username=p_viewer;
  SELECT EXISTS(SELECT 1 FROM public.friends WHERE ((user1=p_viewer AND user2=p_target) OR (user1=p_target AND user2=p_viewer)) AND status='accepted') INTO is_friend;
  IF NOT is_admin_viewer AND NOT is_friend AND p_viewer != p_target THEN RETURN; END IF;
  RETURN QUERY SELECT cf.video_id FROM public.cloud_favorites cf WHERE cf.device_id IN (SELECT device_id FROM public.user_accounts WHERE username=p_target) ORDER BY cf.created_at DESC LIMIT 100;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
GRANT EXECUTE ON FUNCTION public.view_user_favs(TEXT, TEXT) TO anon;

-- RPC: 改密码
DROP FUNCTION IF EXISTS public.change_password(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.change_password(p_username TEXT, p_old_hash TEXT, p_new_hash TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
BEGIN
  UPDATE public.user_accounts SET password_hash=p_new_hash WHERE username=p_username AND password_hash=p_old_hash;
  IF FOUND THEN RETURN QUERY SELECT true, '密码修改成功';
  ELSE RETURN QUERY SELECT false, '原密码错误'; END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.change_password(TEXT, TEXT, TEXT) TO anon;

-- RPC: 管理员重置别人密码
DROP FUNCTION IF EXISTS public.admin_reset_password(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.admin_reset_password(p_admin TEXT, p_target TEXT, p_new_hash TEXT)
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
DECLARE v_admin RECORD;
BEGIN
  SELECT * INTO v_admin FROM public.user_accounts WHERE username=p_admin AND is_admin=true AND banned=false;
  IF v_admin IS NULL THEN RETURN QUERY SELECT false, '无管理员权限'; RETURN; END IF;
  UPDATE public.user_accounts SET password_hash=p_new_hash WHERE username=p_target AND is_admin=false;
  IF FOUND THEN RETURN QUERY SELECT true, '已重置密码';
  ELSE RETURN QUERY SELECT false, '用户不存在'; END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.admin_reset_password(TEXT, TEXT, TEXT) TO anon;

-- RPC: 搜索用户
DROP FUNCTION IF EXISTS public.search_users(TEXT);
CREATE OR REPLACE FUNCTION public.search_users(p_query TEXT)
RETURNS TABLE(username TEXT, vip_level TEXT, verified BOOLEAN) AS $$
BEGIN
  RETURN QUERY SELECT a.username, a.vip_level, a.verified
  FROM public.user_accounts a WHERE a.username ILIKE '%'||p_query||'%' AND a.banned=false ORDER BY a.created_at DESC LIMIT 30;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
GRANT EXECUTE ON FUNCTION public.search_users(TEXT) TO anon;

-- RPC: 管理员获取全站配置
DROP FUNCTION IF EXISTS public.get_config(TEXT);
CREATE OR REPLACE FUNCTION public.get_config(p_key TEXT DEFAULT NULL)
RETURNS TABLE(key TEXT, value TEXT) AS $$
BEGIN
  IF p_key IS NULL THEN
    RETURN QUERY SELECT c.key, c.value FROM public.system_config c;
  ELSE
    RETURN QUERY SELECT c.key, c.value FROM public.system_config c WHERE c.key=p_key;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
GRANT EXECUTE ON FUNCTION public.get_config(TEXT) TO anon;

-- RPC: 管理员设置配置
DROP FUNCTION IF EXISTS public.set_config(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.set_config(p_admin TEXT, p_key TEXT, p_value TEXT)
RETURNS TABLE(success BOOLEAN) AS $$
DECLARE v_admin RECORD;
BEGIN
  SELECT * INTO v_admin FROM public.user_accounts WHERE username=p_admin AND is_admin=true;
  IF v_admin IS NULL THEN RETURN; END IF;
  INSERT INTO public.system_config (key, value, updated_at) VALUES (p_key, p_value, NOW())
  ON CONFLICT (key) DO UPDATE SET value=p_value, updated_at=NOW();
  RETURN QUERY SELECT true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.set_config(TEXT, TEXT, TEXT) TO anon;

-- RPC: 全站统计 (管理员)
DROP FUNCTION IF EXISTS public.site_stats(TEXT);
CREATE OR REPLACE FUNCTION public.site_stats(p_admin TEXT)
RETURNS TABLE(total_users BIGINT, total_videos BIGINT, total_messages BIGINT, playable_videos BIGINT) AS $$
DECLARE v_admin RECORD;
BEGIN
  SELECT * INTO v_admin FROM public.user_accounts WHERE username=p_admin AND is_admin=true;
  IF v_admin IS NULL THEN RETURN; END IF;
  SELECT COUNT(*) INTO total_users FROM public.user_accounts;
  SELECT COUNT(*) INTO total_videos FROM public.videos;
  SELECT COUNT(*) INTO total_messages FROM public.messages;
  SELECT COUNT(*) INTO playable_videos FROM public.videos WHERE has_mp4=true;
  RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.site_stats(TEXT) TO anon;

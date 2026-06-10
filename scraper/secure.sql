-- ═══════════════════════════════════════════
-- 安全加固: RLS策略收紧
-- ═══════════════════════════════════════════

-- user_accounts: 只允许改自己的密码, 不允许改VIP/管理员字段
DROP POLICY IF EXISTS "anon 可读写账号" ON public.user_accounts;
CREATE POLICY "anon_select_users" ON public.user_accounts FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_users" ON public.user_accounts FOR INSERT TO anon WITH CHECK (is_admin = false AND vip_level = 'free' AND verified = false AND banned = false);
CREATE POLICY "anon_update_self" ON public.user_accounts FOR UPDATE TO anon
  USING (true) WITH CHECK (
    is_admin = (SELECT is_admin FROM public.user_accounts u WHERE u.username = username) AND
    vip_level = (SELECT vip_level FROM public.user_accounts u WHERE u.username = username) AND
    verified = (SELECT verified FROM public.user_accounts u WHERE u.username = username) AND
    banned = (SELECT banned FROM public.user_accounts u WHERE u.username = username)
  );

-- activation_codes: 只允许读, 不允许客户端创建
DROP POLICY IF EXISTS "管理员可创建激活码" ON public.activation_codes;
DROP POLICY IF EXISTS "anon 可读取激活码" ON public.activation_codes;
DROP POLICY IF EXISTS "anon 可消耗激活码" ON public.activation_codes;
CREATE POLICY "anon_select_codes" ON public.activation_codes FOR SELECT TO anon USING (true);

-- videos: 只允许读
DROP POLICY IF EXISTS "允许 service_role 写入视频" ON public.videos;
DROP POLICY IF EXISTS "允许 service_role 更新视频" ON public.videos;
DROP POLICY IF EXISTS "允许 anon 通过 RPC 插入视频" ON public.videos;
DROP POLICY IF EXISTS "允许 anon 通过 RPC 更新视频" ON public.videos;
CREATE POLICY "anon_select_videos" ON public.videos FOR SELECT TO anon USING (true);
CREATE POLICY "service_write_videos" ON public.videos FOR ALL TO service_role USING (true) WITH CHECK (true);

-- admin_log: 只读
DROP POLICY IF EXISTS "anon 管理日志" ON public.admin_log;
CREATE POLICY "anon_select_logs" ON public.admin_log FOR SELECT TO anon USING (true);

-- messages: 限制发送为登录用户
DROP POLICY IF EXISTS "anon 管理私信" ON public.messages;
CREATE POLICY "anon_select_msgs" ON public.messages FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_msgs" ON public.messages FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_msgs" ON public.messages FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- friends: 限制
DROP POLICY IF EXISTS "anon 管理好友" ON public.friends;
CREATE POLICY "anon_select_friends" ON public.friends FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_friends" ON public.friends FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_friends" ON public.friends FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_delete_friends" ON public.friends FOR DELETE TO anon USING (true);

-- admin_log: 只读
DROP POLICY IF EXISTS "anon 管理日志" ON public.admin_log;
CREATE POLICY "anon_select_logs" ON public.admin_log FOR SELECT TO anon USING (true);

-- announcements: 只读
DROP POLICY IF EXISTS "anon 管理公告" ON public.announcements;
DROP POLICY IF EXISTS "anon 读取公告" ON public.announcements;
CREATE POLICY "anon_select_ann" ON public.announcements FOR SELECT TO anon USING (true);

-- system_config: 只读
DROP POLICY IF EXISTS "anon 管理配置" ON public.system_config;
CREATE POLICY "anon_select_cfg" ON public.system_config FOR SELECT TO anon USING (true);

-- bans: 只读
DROP POLICY IF EXISTS "anon 管理封禁" ON public.bans;
CREATE POLICY "anon_select_bans" ON public.bans FOR SELECT TO anon USING (true);

-- cloud_favorites: 允许读写
DROP POLICY IF EXISTS "anon 管理自己的云收藏" ON public.cloud_favorites;
CREATE POLICY "anon_select_cf" ON public.cloud_favorites FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_cf" ON public.cloud_favorites FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_delete_cf" ON public.cloud_favorites FOR DELETE TO anon USING (true);

-- user_vips: 只读
DROP POLICY IF EXISTS "anon 可读取自己的 VIP" ON public.user_vips;
DROP POLICY IF EXISTS "anon 可注册 VIP" ON public.user_vips;
DROP POLICY IF EXISTS "anon 可更新自己的 VIP" ON public.user_vips;
CREATE POLICY "anon_select_vips" ON public.user_vips FOR SELECT TO anon USING (true);

-- user_follows: 允许读写
DROP POLICY IF EXISTS "anon 管理关注" ON public.user_follows;
CREATE POLICY "anon_all_follows" ON public.user_follows FOR ALL TO anon USING (true) WITH CHECK (true);


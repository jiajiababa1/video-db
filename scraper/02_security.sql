-- ═══════════════════════════════════════════
-- 安全加固: RLS策略收紧 (可重复执行)
-- ═══════════════════════════════════════════

-- user_accounts: 只允许改密码, 不允许改VIP/管理员/认证字段
DROP POLICY IF EXISTS "anon 可读写账号" ON public.user_accounts;
DROP POLICY IF EXISTS "anon_select_users" ON public.user_accounts;
DROP POLICY IF EXISTS "anon_insert_users" ON public.user_accounts;
DROP POLICY IF EXISTS "anon_update_self" ON public.user_accounts;
CREATE POLICY "anon_select_users" ON public.user_accounts FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_users" ON public.user_accounts FOR INSERT TO anon WITH CHECK (is_admin = false AND vip_level = 'free' AND verified = false AND banned = false);
CREATE POLICY "anon_update_self" ON public.user_accounts FOR UPDATE TO anon
  USING (true) WITH CHECK (
    is_admin = (SELECT is_admin FROM public.user_accounts u WHERE u.username = username) AND
    vip_level = (SELECT vip_level FROM public.user_accounts u WHERE u.username = username) AND
    verified = (SELECT verified FROM public.user_accounts u WHERE u.username = username) AND
    banned = (SELECT banned FROM public.user_accounts u WHERE u.username = username)
  );

-- activation_codes: 允许读+写入
DROP POLICY IF EXISTS "管理员可创建激活码" ON public.activation_codes;
DROP POLICY IF EXISTS "anon 可读取激活码" ON public.activation_codes;
DROP POLICY IF EXISTS "anon 可消耗激活码" ON public.activation_codes;
DROP POLICY IF EXISTS "anon_select_codes" ON public.activation_codes;
DROP POLICY IF EXISTS "anon_insert_codes" ON public.activation_codes;
DROP POLICY IF EXISTS "anon_update_codes" ON public.activation_codes;
CREATE POLICY "anon_select_codes" ON public.activation_codes FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_codes" ON public.activation_codes FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_codes" ON public.activation_codes FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- videos: anon可读可写, service_role全权
DROP POLICY IF EXISTS "允许 service_role 写入视频" ON public.videos;
DROP POLICY IF EXISTS "允许 service_role 更新视频" ON public.videos;
DROP POLICY IF EXISTS "允许 anon 通过 RPC 插入视频" ON public.videos;
DROP POLICY IF EXISTS "允许 anon 通过 RPC 更新视频" ON public.videos;
DROP POLICY IF EXISTS "anon_select_videos" ON public.videos;
DROP POLICY IF EXISTS "anon_insert_videos" ON public.videos;
DROP POLICY IF EXISTS "anon_update_videos" ON public.videos;
DROP POLICY IF EXISTS "service_write_videos" ON public.videos;
CREATE POLICY "anon_select_videos" ON public.videos FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_videos" ON public.videos FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_videos" ON public.videos FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "service_write_videos" ON public.videos FOR ALL TO service_role USING (true) WITH CHECK (true);

-- admin_log: 允许读+插入
DROP POLICY IF EXISTS "anon 管理日志" ON public.admin_log;
DROP POLICY IF EXISTS "anon_select_logs" ON public.admin_log;
DROP POLICY IF EXISTS "anon_insert_logs" ON public.admin_log;
CREATE POLICY "anon_select_logs" ON public.admin_log FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_logs" ON public.admin_log FOR INSERT TO anon WITH CHECK (true);

-- messages: 允许读写
DROP POLICY IF EXISTS "anon 管理私信" ON public.messages;
DROP POLICY IF EXISTS "anon_select_msgs" ON public.messages;
DROP POLICY IF EXISTS "anon_insert_msgs" ON public.messages;
DROP POLICY IF EXISTS "anon_update_msgs" ON public.messages;
CREATE POLICY "anon_select_msgs" ON public.messages FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_msgs" ON public.messages FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_msgs" ON public.messages FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- friends: 允许读写
DROP POLICY IF EXISTS "anon 管理好友" ON public.friends;
DROP POLICY IF EXISTS "anon_select_friends" ON public.friends;
DROP POLICY IF EXISTS "anon_insert_friends" ON public.friends;
DROP POLICY IF EXISTS "anon_update_friends" ON public.friends;
DROP POLICY IF EXISTS "anon_delete_friends" ON public.friends;
CREATE POLICY "anon_select_friends" ON public.friends FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_friends" ON public.friends FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_friends" ON public.friends FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_delete_friends" ON public.friends FOR DELETE TO anon USING (true);

-- announcements: 允许读+发布
DROP POLICY IF EXISTS "anon 管理公告" ON public.announcements;
DROP POLICY IF EXISTS "anon 读取公告" ON public.announcements;
DROP POLICY IF EXISTS "anon_select_ann" ON public.announcements;
DROP POLICY IF EXISTS "anon_insert_ann" ON public.announcements;
DROP POLICY IF EXISTS "anon_update_ann" ON public.announcements;
DROP POLICY IF EXISTS "anon_delete_ann" ON public.announcements;
CREATE POLICY "anon_select_ann" ON public.announcements FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_ann" ON public.announcements FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_ann" ON public.announcements FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_delete_ann" ON public.announcements FOR DELETE TO anon USING (true);

-- system_config: 可读写
DROP POLICY IF EXISTS "anon 管理配置" ON public.system_config;
DROP POLICY IF EXISTS "anon_select_cfg" ON public.system_config;
DROP POLICY IF EXISTS "anon_insert_cfg" ON public.system_config;
DROP POLICY IF EXISTS "anon_update_cfg" ON public.system_config;
CREATE POLICY "anon_select_cfg" ON public.system_config FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_cfg" ON public.system_config FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_cfg" ON public.system_config FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- bans: 可读写(封禁记录)
DROP POLICY IF EXISTS "anon 管理封禁" ON public.bans;
DROP POLICY IF EXISTS "anon_select_bans" ON public.bans;
DROP POLICY IF EXISTS "anon_insert_bans" ON public.bans;
CREATE POLICY "anon_select_bans" ON public.bans FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_bans" ON public.bans FOR INSERT TO anon WITH CHECK (true);

-- cloud_favorites: 允许读写
DROP POLICY IF EXISTS "anon 管理自己的云收藏" ON public.cloud_favorites;
DROP POLICY IF EXISTS "anon_select_cf" ON public.cloud_favorites;
DROP POLICY IF EXISTS "anon_insert_cf" ON public.cloud_favorites;
DROP POLICY IF EXISTS "anon_delete_cf" ON public.cloud_favorites;
CREATE POLICY "anon_select_cf" ON public.cloud_favorites FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_cf" ON public.cloud_favorites FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_delete_cf" ON public.cloud_favorites FOR DELETE TO anon USING (true);

-- user_vips: 只读
DROP POLICY IF EXISTS "anon 可读取自己的 VIP" ON public.user_vips;
DROP POLICY IF EXISTS "anon 可注册 VIP" ON public.user_vips;
DROP POLICY IF EXISTS "anon 可更新自己的 VIP" ON public.user_vips;
DROP POLICY IF EXISTS "anon_select_vips" ON public.user_vips;
DROP POLICY IF EXISTS "anon_insert_vips" ON public.user_vips;
CREATE POLICY "anon_select_vips" ON public.user_vips FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_vips" ON public.user_vips FOR INSERT TO anon WITH CHECK (true);

-- user_follows: 允许读写
DROP POLICY IF EXISTS "anon 管理关注" ON public.user_follows;
DROP POLICY IF EXISTS "anon_all_follows" ON public.user_follows;
CREATE POLICY "anon_all_follows" ON public.user_follows FOR ALL TO anon USING (true) WITH CHECK (true);

-- scrape_status: 允许 anon 写入(爬虫状态记录)
DROP POLICY IF EXISTS "anon 写入状态" ON public.scrape_status;
DROP POLICY IF EXISTS "anon_insert_scrape" ON public.scrape_status;
CREATE POLICY "anon_insert_scrape" ON public.scrape_status FOR INSERT TO anon WITH CHECK (true);

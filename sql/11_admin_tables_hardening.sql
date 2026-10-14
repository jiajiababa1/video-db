-- ============================================================
-- 11_admin_tables_hardening.sql
-- 收紧 bans / announcements / site_pages：匿名与普通用户只读，写入走管理员 RPC
--
-- 背景：这三张表之前对 anon 全开增删改查（bans 甚至是 FOR ALL），
--   前端直接 REST 写入只靠客户端 _isAdmin 判断，curl 即可绕过。
--   RLS 看不到 x-login-token 自定义头，所以写入必须收归 SECURITY DEFINER RPC，
--   在服务端用 sessions + user_accounts 地面真相验身份（沿用 09 模式）。
--
-- 前置：09_owner_hardening.sql 已执行（依赖 sessions / user_accounts / admin_log）
-- 执行后前端需同步改走新 RPC（见文件尾注释），否则管理功能会报权限不足。
-- ============================================================

-- ================= 1. bans：匿名只读 =================
-- 封禁/解封走 admin_exec(ban/unban)，09 已加固，前端已在用，无需新 RPC。
DROP POLICY IF EXISTS rls_all_bans ON public.bans;
DROP POLICY IF EXISTS bans_read ON public.bans;
CREATE POLICY bans_read ON public.bans
  FOR SELECT TO anon, authenticated USING (true);
-- 无 INSERT/UPDATE/DELETE 策略 = 默认拒绝。被封用户再也不能自己 DELETE 解封。

-- ================= 2. announcements：匿名只读 =================
DROP POLICY IF EXISTS announcements_g_ins ON public.announcements;
DROP POLICY IF EXISTS announcements_g_upd ON public.announcements;
DROP POLICY IF EXISTS announcements_g_del ON public.announcements;
-- announcements_g_read 保留（公告需公开读）
-- 写入走下方 RPC（admin_exec 里的 announce_* action 保留兼容，不再被前端调用）

-- ---------- 管理员鉴权小工具（09 模式内联版） ----------
-- 每个 RPC 内联以下三段，防 drift 不抽公共函数：
--   select s.username into v_caller from public.sessions s
--     where s.token = p_token and s.expires_at > now();
--   select ua.is_admin into v_caller_admin from public.user_accounts ua
--     where ua.username = v_caller;

-- ---------- 2.1 发布公告（含"仅显示此"逻辑） ----------
CREATE OR REPLACE FUNCTION public.admin_announce_publish(
  p_token text, p_title text, p_content text, p_only boolean DEFAULT false
)
RETURNS table(ok boolean, message text)
LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_caller       text;
  v_caller_admin boolean;
BEGIN
  SELECT s.username INTO v_caller FROM public.sessions s
    WHERE s.token = p_token AND s.expires_at > now();
  SELECT ua.is_admin INTO v_caller_admin FROM public.user_accounts ua
    WHERE ua.username = v_caller;

  IF NOT coalesce(v_caller_admin, false) THEN
    INSERT INTO public.admin_log (admin_user, action, target, detail)
      VALUES (coalesce(v_caller, '?'), 'DENIED:announce_publish', p_title, '非管理员越权尝试');
    RETURN QUERY SELECT false, '无管理员权限';
    RETURN;
  END IF;

  IF p_only THEN
    UPDATE public.announcements SET is_active = false WHERE is_active IS DISTINCT FROM false;
  END IF;
  INSERT INTO public.announcements (title, content, created_by, is_active)
    VALUES (p_title, p_content, v_caller, true);
  INSERT INTO public.admin_log (admin_user, action, target, detail)
    VALUES (v_caller, 'announce_publish', p_title, CASE WHEN p_only THEN 'only' ELSE '' END);
  RETURN QUERY SELECT true, '公告已发布';
END; $function$;

-- ---------- 2.2 删除单条公告 ----------
CREATE OR REPLACE FUNCTION public.admin_announce_delete(p_token text, p_id bigint)
RETURNS table(ok boolean, message text)
LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_caller       text;
  v_caller_admin boolean;
BEGIN
  SELECT s.username INTO v_caller FROM public.sessions s
    WHERE s.token = p_token AND s.expires_at > now();
  SELECT ua.is_admin INTO v_caller_admin FROM public.user_accounts ua
    WHERE ua.username = v_caller;

  IF NOT coalesce(v_caller_admin, false) THEN
    INSERT INTO public.admin_log (admin_user, action, target, detail)
      VALUES (coalesce(v_caller, '?'), 'DENIED:announce_delete', p_id::text, '非管理员越权尝试');
    RETURN QUERY SELECT false, '无管理员权限';
    RETURN;
  END IF;

  DELETE FROM public.announcements WHERE id = p_id;
  INSERT INTO public.admin_log (admin_user, action, target, detail)
    VALUES (v_caller, 'announce_delete', p_id::text, '');
  RETURN QUERY SELECT true, '公告已删除';
END; $function$;

-- ---------- 2.3 清空公告 ----------
CREATE OR REPLACE FUNCTION public.admin_announce_clear(p_token text)
RETURNS table(ok boolean, message text)
LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_caller       text;
  v_caller_admin boolean;
BEGIN
  SELECT s.username INTO v_caller FROM public.sessions s
    WHERE s.token = p_token AND s.expires_at > now();
  SELECT ua.is_admin INTO v_caller_admin FROM public.user_accounts ua
    WHERE ua.username = v_caller;

  IF NOT coalesce(v_caller_admin, false) THEN
    INSERT INTO public.admin_log (admin_user, action, target, detail)
      VALUES (coalesce(v_caller, '?'), 'DENIED:announce_clear', '', '非管理员越权尝试');
    RETURN QUERY SELECT false, '无管理员权限';
    RETURN;
  END IF;

  DELETE FROM public.announcements;
  INSERT INTO public.admin_log (admin_user, action, target, detail)
    VALUES (v_caller, 'announce_clear', '', '');
  RETURN QUERY SELECT true, '公告已清空';
END; $function$;

-- ================= 3. site_pages：匿名只读 =================
DROP POLICY IF EXISTS site_pages_g_ins ON public.site_pages;
DROP POLICY IF EXISTS site_pages_g_upd ON public.site_pages;
DROP POLICY IF EXISTS site_pages_g_del ON public.site_pages;
-- site_pages_g_read 保留（页面需公开读）
-- 前端原有"仅站主可建/改/删"客户端检查，服务端同样收归站主（kuo）

-- ---------- 3.1 保存页面（upsert，站主专用） ----------
CREATE OR REPLACE FUNCTION public.admin_sitepage_save(
  p_token text, p_slug text, p_title text, p_content text
)
RETURNS table(ok boolean, message text)
LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_caller text;
BEGIN
  SELECT s.username INTO v_caller FROM public.sessions s
    WHERE s.token = p_token AND s.expires_at > now();

  IF v_caller IS DISTINCT FROM 'kuo' THEN
    INSERT INTO public.admin_log (admin_user, action, target, detail)
      VALUES (coalesce(v_caller, '?'), 'DENIED:sitepage_save', p_slug, '非站主越权尝试');
    RETURN QUERY SELECT false, '仅站主可操作';
    RETURN;
  END IF;

  INSERT INTO public.site_pages (slug, title, content, created_by, updated_at)
    VALUES (p_slug, p_title, p_content, v_caller, now())
  ON CONFLICT (slug) DO UPDATE
    SET title = EXCLUDED.title, content = EXCLUDED.content, updated_at = now();
  INSERT INTO public.admin_log (admin_user, action, target, detail)
    VALUES (v_caller, 'sitepage_save', p_slug, '');
  RETURN QUERY SELECT true, '页面已保存';
END; $function$;

-- ---------- 3.2 删除页面（站主专用） ----------
CREATE OR REPLACE FUNCTION public.admin_sitepage_delete(p_token text, p_slug text)
RETURNS table(ok boolean, message text)
LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_caller text;
BEGIN
  SELECT s.username INTO v_caller FROM public.sessions s
    WHERE s.token = p_token AND s.expires_at > now();

  IF v_caller IS DISTINCT FROM 'kuo' THEN
    INSERT INTO public.admin_log (admin_user, action, target, detail)
      VALUES (coalesce(v_caller, '?'), 'DENIED:sitepage_delete', p_slug, '非站主越权尝试');
    RETURN QUERY SELECT false, '仅站主可操作';
    RETURN;
  END IF;

  DELETE FROM public.site_pages WHERE slug = p_slug;
  INSERT INTO public.admin_log (admin_user, action, target, detail)
    VALUES (v_caller, 'sitepage_delete', p_slug, '');
  RETURN QUERY SELECT true, '页面已删除';
END; $function$;

-- ============================================================
-- 前端对应改动（index.html）：
--   publishAnnounce()  -> POST /rest/v1/rpc/admin_announce_publish
--     {p_token, p_title, p_content, p_only}
--   deleteAnnounce(id)  -> POST /rest/v1/rpc/admin_announce_delete {p_token, p_id}
--   clearAnnounces()    -> POST /rest/v1/rpc/admin_announce_clear {p_token}
--   saveSitePage()      -> POST /rest/v1/rpc/admin_sitepage_save
--     {p_token, p_slug, p_title, p_content}（content 保持前端 sanitizeHTML）
--   deleteSitePage()    -> POST /rest/v1/rpc/admin_sitepage_delete {p_token, p_slug}
-- 验证：
--   匿名 POST /rest/v1/announcements -> 401；匿名 DELETE bans -> 401/204零行
-- ============================================================

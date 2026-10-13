-- ============================================================
-- 10 admin_config 加固：系统设置键分级 + 配置表读权限收紧
-- 执行位置: Supabase Dashboard → SQL Editor
-- 在 09 之后执行（依赖 admin_log 表；可重复执行，幂等）
--
-- 修复的口子：
--  [1] 任意键可写：admin_config 原来除 totp_secret 外允许写任意 key，
--      技术员可写入 captcha_mode='off' 关掉注册验证码，或塞入恶意键。
--      → 管理员只能写展示类白名单；其余键只允许站主。
--  [2] 会话标记鉴权：原来查 sessions.is_admin 旧标记，有 09 修复过的
--      降级残留问题。→ 改查 user_accounts 地面真相。
--  [3] 无审计：配置变更原来不记日志。→ 每次写入/越权拒绝都记 admin_log。
--  [4] system_config 匿名可读全部键：syscfg_public_read 允许 anon SELECT，
--      若 USING 未过滤，totp_secret 等敏感键直接暴露给全网，密码门形同虚设。
--      → 改为键白名单，只开放展示类键。
-- ============================================================

-- ---------- 1. admin_config 加固版 ----------
create or replace function public.admin_config(p_token text, p_key text, p_value text)
returns table(ok boolean)
language plpgsql security definer as $function$
declare
  v_caller       text;
  v_caller_admin boolean;
  v_is_owner     boolean;
begin
  -- 调用者身份：session 必须有效
  select s.username into v_caller
  from public.sessions s
  where s.token = p_token and s.expires_at > now();

  -- 地面真相：以 user_accounts.is_admin 为准
  select ua.is_admin into v_caller_admin
  from public.user_accounts ua
  where ua.username = v_caller;

  v_is_owner := (v_caller = 'kuo');

  if not v_is_owner and not coalesce(v_caller_admin, false) then
    return query select false;
    return;
  end if;

  -- totp_secret 永不允许经此接口改写（轮换走独立流程）
  if p_key = 'totp_secret' then
    return query select false;
    return;
  end if;

  -- 键分级：管理员仅允许展示类白名单；安全类键（如 captcha_mode）只允许站主
  if not v_is_owner
     and p_key not in ('site_name', 'announce_text', 'ban_title', 'ban_message') then
    insert into public.admin_log (admin_user, action, target, detail)
    values (v_caller, 'DENIED:admin_config', p_key, '非站主尝试写入安全配置键');
    return query select false;
    return;
  end if;

  insert into public.system_config (key, value, updated_at)
  values (p_key, p_value, now())
  on conflict (key) do update
    set value = excluded.value, updated_at = now();

  insert into public.admin_log (admin_user, action, target, detail)
  values (v_caller, 'admin_config', p_key, left(coalesce(p_value, ''), 200));

  return query select true;
end; $function$;

-- ---------- 2. system_config 读权限：改为键白名单 ----------
-- 先删掉原来的宽松 policy（无论它的 USING 是什么，一律替换为白名单）
drop policy if exists syscfg_public_read on public.system_config;

-- 只允许匿名读取展示类键；totp_secret 等敏感键永不对 anon 开放
-- （前端经 REST 读取的键：site_name / announce_text / ban_title / ban_message / site_code_hash）
create policy syscfg_public_read_whitelist
on public.system_config for select to anon
using (key in ('site_name', 'announce_text', 'ban_title', 'ban_message', 'site_code_hash'));

alter table public.system_config enable row level security;
-- 写 policy 本来就没有（匿名直写已收回），保持默认拒绝；
-- 写入只走 admin_config 等 SECURITY DEFINER 函数

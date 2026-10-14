-- ============================================================
-- 11 bans / sessions RLS 加固：封禁表匿名整表可读 → 收归 RPC；sessions 匿名零访问
-- 执行位置: Supabase Dashboard → SQL Editor
-- 在 09/10 之后执行（依赖 admin_log、sessions、user_accounts；可重复执行，幂等）
--
-- 修复的口子：
--  [1] bans 表匿名整表可读：前端 fetchBanReason 用纯 anon key（_hd()）
--      直读 /rest/v1/bans?username=eq.x，说明 bans 上必有一条 anon 可用的
--      SELECT policy；任何人拿 anon key 就能拖走全部封禁记录
--      （被封用户名、封禁原因、操作人 banned_by）。
--      → 删掉 bans 上所有旧 policy（RLS 默认拒绝）；封禁原因展示改走
--         get_ban_reason(p_username) RPC（只返回该用户最新一条原因），
--         管理员看列表改走 admin_recent_bans(p_token) RPC。
--  [2] sessions 表匿名可读从未确认：sessions 存有效登录 token，等价于密码明文；
--      健康检查页期望匿名读返回 401/403，但 policy 状态一直没人查过。
--      → 删掉 sessions 上所有 policy，恢复"默认拒绝"；合法访问本来就走
--         SECURITY DEFINER 函数（check_session 等），不受影响。
--  [3] 鉴权口径与 09 一致：admin RPC 校验 sessions 有效 token +
--      user_accounts.is_admin 地面真相；越权调用返回空集并记 admin_log。
-- ============================================================

-- ---------- 1. 清掉 bans / sessions 上的全部旧 policy ----------
do $$
declare r record;
begin
  for r in select tablename, policyname from pg_policies
           where schemaname = 'public' and tablename in ('bans', 'sessions')
  loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.bans enable row level security;
alter table public.sessions enable row level security;

-- ---------- 2. get_ban_reason：被封用户自查封禁原因（公开 RPC） ----------
-- 前端 fetchBanReason 原来匿名直读整表，现改为按用户名查最新一条。
create or replace function public.get_ban_reason(p_username text)
returns table(username text, reason text, banned_at timestamptz)
language plpgsql security definer as $function$
begin
  if p_username is null or p_username = '' then return; end if;
  return query
  select b.username, b.reason, b.banned_at
  from public.bans b
  where b.username = p_username
  order by b.banned_at desc
  limit 1;
end; $function$;
grant execute on function public.get_ban_reason(text) to anon, authenticated;

-- ---------- 3. admin_recent_bans：管理员看最近封禁列表 ----------
-- 前端 showAdminAudit 原来用 _h() 直读 /rest/v1/bans?select=*，现改走此 RPC。
create or replace function public.admin_recent_bans(p_token text, p_limit int default 20)
returns table(username text, reason text, banned_by text, banned_at timestamptz)
language plpgsql security definer as $function$
declare
  v_caller text;
  v_admin  boolean;
begin
  select s.username into v_caller
  from public.sessions s
  where s.token = p_token and s.expires_at > now();
  select coalesce(ua.is_admin, false) into v_admin
  from public.user_accounts ua
  where ua.username = v_caller;
  if v_caller is null or not v_admin then
    insert into public.admin_log (admin_user, action, target, detail)
    values (coalesce(v_caller, '(anon)'), 'admin_recent_bans', '(denied)', '非管理员调用被拒绝');
    return;
  end if;
  return query
  select b.username, b.reason, b.banned_by, b.banned_at
  from public.bans b
  order by b.banned_at desc
  limit least(coalesce(p_limit, 20), 100);
end; $function$;
grant execute on function public.admin_recent_bans(text, int) to anon, authenticated;

-- ---------- 4. 验证（执行后在 SQL Editor 里跑，期望见注释） ----------
-- select tablename, policyname, roles, cmd from pg_policies
-- where schemaname = 'public' and tablename in ('bans','sessions');
--   → 期望 0 行（两表回到默认拒绝）
-- select * from public.get_ban_reason('一个已知被封的用户名');
--   → 期望 1 行（username/reason/banned_at）；未知用户名 → 0 行
-- select * from public.admin_recent_bans('无效token', 5);
--   → 期望 0 行，且 admin_log 多一条 action='admin_recent_bans' 的 denied 记录

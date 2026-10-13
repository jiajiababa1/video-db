-- ============================================================
-- 09 站主权限加固：防越权
-- 执行位置: Supabase Dashboard → SQL Editor
-- 执行顺序: 在 06/07/08 之后执行（会替换 admin_exec / check_session / verify_passcode）
-- 可重复执行（幂等）
--
-- 修复的越权口子：
--  [1] 任意管理员可提拔新管理员：admin_exec 的 set_admin 原来只要求调用者
--      is_admin，技术员可随意提拔亲信，甚至把其他管理员全部降级实现独揽。
--      → set_admin / delete_user 收归站主(kuo)，非站主调用直接拒绝并记日志。
--  [2] 降级后权限残留：admin_exec 原来只查 sessions 表上的 is_admin 旧标记，
--      被降级的技术员只要不重新登录，旧 token 可一直用（check_session 还会
--      自动续期 30 天）。→ 改查 user_accounts.is_admin 地面真相；降级时立即
--      删除目标所有 session，踢下线。
--  [3] 审计日志裸奔：admin_log 表上有 anon 可 INSERT/UPDATE/DELETE 的 policy，
--      任何人可伪造、篡改、删除审计记录。→ 删掉所有 anon policy，只允许
--      SECURITY DEFINER 函数写入；读取走 get_audit_log RPC（需管理员）。
--  [4] TOTP 硬编码 fallback：verify_passcode 在未配置 totp_secret 时回退到
--      写死在函数源码里的种子，等于留了个公开的万能钥匙。→ 未配置直接拒绝。
-- ============================================================

-- ---------- 1. admin_exec 加固版 ----------
create or replace function public.admin_exec(p_token text, p_action text, p_target text, p_detail text default '')
returns table(ok boolean, message text)
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

  -- 地面真相：以 user_accounts.is_admin 为准，而非 session 上的旧标记
  select ua.is_admin into v_caller_admin
  from public.user_accounts ua
  where ua.username = v_caller;

  v_is_owner := (v_caller = 'kuo');

  if not v_is_owner and not coalesce(v_caller_admin, false) then
    return query select false, '无管理员权限';
    return;
  end if;

  -- 越权防护：只有站主能动权限（提拔/降级管理员、删除用户）
  if p_action in ('set_admin', 'delete_user') and not v_is_owner then
    insert into public.admin_log (admin_user, action, target, detail)
    values (v_caller, 'DENIED:' || p_action, p_target, '非站主越权尝试');
    return query select false, '仅站主可操作';
    return;
  end if;

  -- 站主账号保护（保留原有）
  if (p_target = 'kuo')
     and p_action in ('set_admin','delete_user','ban','unban','verify','unverify','set_vip') then
    return query select false, '不能操作站主账号';
    return;
  end if;

  insert into public.admin_log (admin_user, action, target, detail)
  values (v_caller, p_action, p_target, p_detail);

  case p_action
    when 'set_admin' then
      update public.user_accounts set is_admin = (p_detail = 'true') where username = p_target;
      if p_detail <> 'true' then
        -- 降级立即清除目标所有 session，防止旧 token 继续行使管理员权限
        delete from public.sessions where username = p_target;
      end if;
      return query select true, '已设置 ' || p_target || ' is_admin=' || p_detail;
    when 'delete_user' then
      delete from public.user_accounts where username = p_target;
      delete from public.sessions where username = p_target;
      return query select true, '已删除 ' || p_target;
    when 'ban' then
      update public.user_accounts set banned = true where username = p_target;
      insert into public.bans (username, reason, banned_by) values (p_target, nullif(p_detail, ''), v_caller);
      return query select true, '已封禁 ' || p_target;
    when 'unban' then
      update public.user_accounts set banned = false where username = p_target;
      return query select true, '已解封 ' || p_target;
    when 'verify' then
      update public.user_accounts set verified = true where username = p_target;
      return query select true, '已认证 ' || p_target;
    when 'unverify' then
      update public.user_accounts set verified = false where username = p_target;
      return query select true, '已取消认证';
    when 'set_vip' then
      -- p_detail = jsonb: {"level":"vip","expires_at":"ISO"或 null,"perm":bool}
      update public.user_accounts
        set vip_level = coalesce((p_detail::jsonb->>'level'), vip_level),
            vip_expires_at = case when coalesce(((p_detail::jsonb->>'perm')::boolean), false)
                                  then null else (p_detail::jsonb->>'expires_at')::timestamptz end
        where username = p_target;
      insert into public.user_vips (username, vip_level, started_at, expires_at, permanent, source)
      values (p_target,
              coalesce((p_detail::jsonb->>'level'), 'vip'), now(),
              case when coalesce(((p_detail::jsonb->>'perm')::boolean), false)
                   then null else (p_detail::jsonb->>'expires_at')::timestamptz end,
              coalesce(((p_detail::jsonb->>'perm')::boolean), false), 'admin');
      return query select true, '已设置VIP: ' || p_target;
    when 'delete_video' then
      delete from public.videos where video_id = p_target;
      return query select true, '已删除视频';
    when 'videos_rescrape_all' then
      update public.videos set needs_rescrape = true where has_mp4 = false or has_mp4 is null;
      return query select true, '已标记所有无法播放的视频为重爬';
    when 'videos_clear_rescrape' then
      update public.videos set needs_rescrape = false;
      return query select true, '已清除全部重爬标记';
    when 'videos_del_no_mp4' then
      delete from public.videos where has_mp4 = false or has_mp4 is null;
      return query select true, '已删除无MP4视频';
    when 'videos_del_old_30d' then
      delete from public.videos where scraped_at < now() - interval '30 days' and (has_mp4 = false or has_mp4 is null);
      return query select true, '已删除30天前未更新且无法播放的视频';
    when 'videos_rescrape_section' then
      update public.videos set needs_rescrape = true where source_section = p_target;
      return query select true, '已标记栏目重爬: ' || p_target;
    when 'videos_del_section' then
      delete from public.videos where source_section = p_target;
      return query select true, '已删除栏目: ' || p_target;
    when 'videos_del_author' then
      delete from public.videos where author = p_target;
      return query select true, '已删除作者: ' || p_target;
    when 'announce_create' then
      insert into public.announcements (title, content, created_by)
      values (p_target, nullif(p_detail, ''), v_caller);
      return query select true, '公告已发布';
    when 'announce_delete' then
      delete from public.announcements where id = p_target::bigint;
      return query select true, '公告已删除';
    when 'announce_clear' then
      delete from public.announcements;
      return query select true, '公告已清空';
    else
      return query select false, '未知操作: ' || p_action;
  end case;
end; $function$;

-- ---------- 2. check_session：is_admin 以 user_accounts 地面真相为准 ----------
create or replace function public.check_session(p_token text)
returns table(valid boolean, username text, is_admin boolean, vip_level text)
language plpgsql security definer as $function$
begin
  if exists (select 1 from public.sessions where token = p_token and expires_at > now()) then
    update public.sessions set expires_at = now() + interval '30 days' where token = p_token;
    return query
    select true, s.username, coalesce(ua.is_admin, false), coalesce(s.vip_level, 'free')
    from public.sessions s
    left join public.user_accounts ua on ua.username = s.username
    where s.token = p_token;
  else
    return query select false, null::text, false, ''::text;
  end if;
end; $function$;

-- ---------- 3. admin_log 锁死：删掉 anon 的读写 policy ----------
drop policy if exists admin_log_g_upd on public.admin_log;
drop policy if exists admin_log_g_read on public.admin_log;
drop policy if exists admin_log_g_ins on public.admin_log;
drop policy if exists admin_log_g_del on public.admin_log;
alter table public.admin_log enable row level security;
-- 无 policy = 默认拒绝；写入只走 SECURITY DEFINER 函数（admin_exec 等），绕过 RLS

-- 审计日志读取 RPC（管理员可见，防匿名偷窥/篡改）
create or replace function public.get_audit_log(p_token text, p_limit int default 50)
returns table(admin_user text, action text, target text, detail text, created_at timestamptz)
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
  if not (v_caller = 'kuo' or v_admin) then
    return; -- 无权限返回空
  end if;
  return query
  select l.admin_user, l.action, l.target, l.detail, l.created_at
  from public.admin_log l
  order by l.created_at desc
  limit least(coalesce(p_limit, 50), 200);
end; $function$;
grant execute on function public.get_audit_log(text, int) to anon;

-- ---------- 4. verify_passcode：去掉硬编码 fallback，未配置直接拒绝 ----------
create or replace function public.verify_passcode(p_code text, p_device_id text)
returns table(ok boolean, token text, message text)
language plpgsql security definer as $function$
declare v_seed text; cur text; prev text; v_token text;
begin
  select value into v_seed from public.system_config where key = 'totp_secret';
  -- 未配置密钥时直接拒绝，不再使用写死在源码里的 fallback 种子
  if v_seed is null or v_seed = '' then
    return query select false, null::text, '未配置密钥';
    return;
  end if;
  cur  := public._totp_now(v_seed);
  prev := public._totp_prev(v_seed);
  if p_code is null or (p_code <> cur and p_code <> prev) then
    return query select false, null::text, '密码错误';
    return;
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into public.sessions (device_id, token, username, is_admin, vip_level, expires_at)
  values (coalesce(p_device_id, ''), v_token, null, false, 'free', now() + interval '7 days');
  return query select true, v_token, '验证通过';
end; $function$;

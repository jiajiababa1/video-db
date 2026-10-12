-- ============================================================
-- 受信任设备免密码登录 (#站主免密)
-- 背景: 密码门 token 7 天过期，站主每次都要输动态密码。
-- 方案: 站主在密码框勾选"信任此设备"，服务端记录 device_id；
-- 下次打开时前端用 device_id 直接换取新 token，无需输密码。
-- 信任期 90 天，到期或点"退出登录"后需重新验证。
-- 执行位置: Supabase Dashboard → SQL Editor
-- ============================================================

create table if not exists public.trusted_devices (
  device_id  text primary key,
  label      text not null default '',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '90 days'
);
alter table public.trusted_devices enable row level security;
-- 不建任何 policy: 匿名不可直接读写，只能走下面的 RPC

-- 标记当前设备为信任 (需有效的 gate token)
create or replace function public.trust_device(p_token text, p_device_id text, p_label text default '')
returns jsonb language plpgsql security definer as $$
declare sess jsonb;
begin
  if p_device_id is null or p_device_id = '' then
    return jsonb_build_object('ok', false, 'message', 'bad device');
  end if;
  select to_jsonb(x) into sess from public.check_session(p_token) x limit 1;
  if sess is null or not coalesce((sess->>'valid')::boolean, false) then
    return jsonb_build_object('ok', false, 'message', 'forbidden');
  end if;
  insert into public.trusted_devices(device_id, label, expires_at)
  values (p_device_id, left(coalesce(p_label,''), 50), now() + interval '90 days')
  on conflict (device_id) do update
    set expires_at = now() + interval '90 days',
        label = excluded.label;
  return jsonb_build_object('ok', true);
end $$;

-- 受信任设备直接换取 gate token (无需密码)
-- 会话格式与 verify_passcode 一致: 7 天有效期
create or replace function public.device_gate_login(p_device_id text)
returns jsonb language plpgsql security definer as $$
declare v_token text;
begin
  if p_device_id is null or p_device_id = '' then
    return jsonb_build_object('ok', false);
  end if;
  if not exists (
    select 1 from public.trusted_devices
    where device_id = p_device_id and expires_at > now()
  ) then
    return jsonb_build_object('ok', false);
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into public.sessions (device_id, token, username, is_admin, vip_level, expires_at)
  values (p_device_id, v_token, null, false, 'free', now() + interval '7 days');
  -- 信任期顺延: 每次用都续 90 天，常用设备永不过期
  update public.trusted_devices
  set expires_at = now() + interval '90 days'
  where device_id = p_device_id;
  return jsonb_build_object('ok', true, 'token', v_token);
end $$;

-- 取消信任单个设备 (退出登录时调用)
create or replace function public.untrust_device(p_device_id text)
returns jsonb language plpgsql security definer as $$
begin
  delete from public.trusted_devices where device_id = p_device_id;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.trust_device(text, text, text) to anon;
grant execute on function public.device_gate_login(text) to anon;
grant execute on function public.untrust_device(text) to anon;

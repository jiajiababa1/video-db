-- ============================================================
-- 受信任设备改为站主(管理员)专用
-- 在 07_trusted_devices.sql 之后执行
-- ============================================================

-- 记录是哪位管理员信任的设备
alter table public.trusted_devices
  add column if not exists created_by text not null default '';

-- trust_device: 必须同时提供有效的管理员登录 token
create or replace function public.trust_device(
  p_gate_token text, p_admin_token text, p_device_id text, p_label text default ''
)
returns jsonb language plpgsql security definer as $$
declare gate jsonb; adm jsonb;
begin
  if p_device_id is null or p_device_id = '' then
    return jsonb_build_object('ok', false, 'message', 'bad device');
  end if;
  -- 密码门 token 有效
  select to_jsonb(x) into gate from public.check_session(p_gate_token) x limit 1;
  if gate is null or not coalesce((gate->>'valid')::boolean, false) then
    return jsonb_build_object('ok', false, 'message', 'bad gate token');
  end if;
  -- 管理员 token 有效且 is_admin
  select to_jsonb(x) into adm from public.check_session(p_admin_token) x limit 1;
  if adm is null
     or not coalesce((adm->>'valid')::boolean, false)
     or not coalesce((adm->>'is_admin')::boolean, false) then
    return jsonb_build_object('ok', false, 'message', 'admin only');
  end if;
  insert into public.trusted_devices(device_id, label, created_by, expires_at)
  values (p_device_id, left(coalesce(p_label,''), 50),
          coalesce(adm->>'username',''), now() + interval '90 days')
  on conflict (device_id) do update
    set expires_at = now() + interval '90 days',
        label = excluded.label,
        created_by = excluded.created_by;
  return jsonb_build_object('ok', true);
end $$;

-- 旧签名废弃 (防有人绕过)
create or replace function public.trust_device(p_token text, p_device_id text, p_label text default '')
returns jsonb language plpgsql security definer as $$
begin
  return jsonb_build_object('ok', false, 'message', 'admin only');
end $$;

grant execute on function public.trust_device(text, text, text, text) to anon;

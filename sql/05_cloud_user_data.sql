-- cloud_user_data 建表 (#6 收藏/历史云同步)
-- 在 Supabase SQL Editor 执行一次即可

create table if not exists public.cloud_user_data (
  username text not null,
  kind text not null check (kind in ('hist','fav','wl')),
  video_id text not null,
  watched_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  primary key (username, kind, video_id)
);
create index if not exists cloud_user_data_user_idx on public.cloud_user_data (username, kind, watched_at desc);
alter table public.cloud_user_data enable row level security;
-- 身份鉴权策略 (依赖 16_rls_token_guard.sql 中的 _req_username(); 请先执行一次 16 号脚本)
drop policy if exists "cloud_user_data_anon_all" on public.cloud_user_data;
drop policy if exists cloud_user_data_g_read on public.cloud_user_data;
drop policy if exists cloud_user_data_g_ins on public.cloud_user_data;
drop policy if exists cloud_user_data_g_upd on public.cloud_user_data;
drop policy if exists cloud_user_data_g_del on public.cloud_user_data;
create policy cloud_user_data_g_read on public.cloud_user_data for select to anon, authenticated using (username = public._req_username());
create policy cloud_user_data_g_ins on public.cloud_user_data for insert to anon, authenticated with check (username = public._req_username());
create policy cloud_user_data_g_upd on public.cloud_user_data for update to anon, authenticated using (username = public._req_username()) with check (username = public._req_username());
create policy cloud_user_data_g_del on public.cloud_user_data for delete to anon, authenticated using (username = public._req_username());
grant select, insert, update, delete on public.cloud_user_data to anon, authenticated, service_role;
create table if not exists public.cloud_user_config (
  username text not null primary key,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.cloud_user_config enable row level security;
drop policy if exists "cloud_user_config_anon_all" on public.cloud_user_config;
drop policy if exists cloud_user_config_g_read on public.cloud_user_config;
drop policy if exists cloud_user_config_g_ins on public.cloud_user_config;
drop policy if exists cloud_user_config_g_upd on public.cloud_user_config;
drop policy if exists cloud_user_config_g_del on public.cloud_user_config;
create policy cloud_user_config_g_read on public.cloud_user_config for select to anon, authenticated using (username = public._req_username());
create policy cloud_user_config_g_ins on public.cloud_user_config for insert to anon, authenticated with check (username = public._req_username());
create policy cloud_user_config_g_upd on public.cloud_user_config for update to anon, authenticated using (username = public._req_username()) with check (username = public._req_username());
create policy cloud_user_config_g_del on public.cloud_user_config for delete to anon, authenticated using (username = public._req_username());
grant select, insert, update, delete on public.cloud_user_config to anon, authenticated, service_role;

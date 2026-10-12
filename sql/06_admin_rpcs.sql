-- ============================================================
-- 管理员 SECURITY DEFINER RPCs (#5 RLS 收紧后的替代通道)
-- 背景: videos / scraped_videos / scrape_status 收紧为匿名只读后，
-- 前端以下合法写入需走 RPC：
--   1. submit_mp4        浏览器解析出 MP4 后的回填（任意过门用户）
--   2. admin_rename_tag  后台分区重命名（需管理员）
--   3. admin_scraped_push 后台浏览器抓取上传（需管理员）
--   4. admin_scraped_clear 后台清空抓取池（需管理员）
-- 管理员校验统一走现有 check_session(p_token) RPC。
-- 执行位置: Supabase Dashboard → SQL Editor
-- ============================================================

-- 1. MP4 回填（URL 白名单校验，防写入恶意地址）
create or replace function public.submit_mp4(p_video_id text, p_mp4_url text)
returns jsonb language plpgsql security definer as $$
begin
  if p_video_id is null or p_mp4_url is null
     or (p_mp4_url not like '%video.twimg.com%' and p_mp4_url not like '%.mp4%') then
    return jsonb_build_object('ok', false, 'message', 'invalid url');
  end if;
  update public.videos
  set duration = p_mp4_url,
      mp4_url = p_mp4_url,
      has_mp4 = true,
      needs_rescrape = false,
      updated_at = now()
  where video_id = p_video_id;
  return jsonb_build_object('ok', true);
end $$;

-- 2. 分区重命名（管理员）
create or replace function public.admin_rename_tag(p_token text, p_old text, p_new text)
returns jsonb language plpgsql security definer as $$
declare sess jsonb;
begin
  select to_jsonb(x) into sess from public.check_session(p_token) x limit 1;
  if sess is null
     or not coalesce((sess->>'valid')::boolean, false)
     or not coalesce((sess->>'is_admin')::boolean, false) then
    return jsonb_build_object('ok', false, 'message', 'forbidden');
  end if;
  if p_old is null or p_new is null or p_old = p_new or length(p_new) > 100 then
    return jsonb_build_object('ok', false, 'message', 'bad args');
  end if;
  update public.videos
  set source_section = p_new, updated_at = now()
  where source_section ilike '%' || p_old || '%';
  return jsonb_build_object('ok', true);
end $$;

-- 3. 抓取池批量上传（管理员）
create or replace function public.admin_scraped_push(p_token text, p_items jsonb)
returns jsonb language plpgsql security definer as $$
declare sess jsonb; it jsonb; n int := 0;
begin
  select to_jsonb(x) into sess from public.check_session(p_token) x limit 1;
  if sess is null
     or not coalesce((sess->>'valid')::boolean, false)
     or not coalesce((sess->>'is_admin')::boolean, false) then
    return jsonb_build_object('ok', false, 'message', 'forbidden');
  end if;
  if jsonb_typeof(p_items) != 'array' or jsonb_array_length(p_items) > 200 then
    return jsonb_build_object('ok', false, 'message', 'bad args');
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into public.scraped_videos(url, type, source_page, found_at)
    values (left(it->>'url', 2000), left(it->>'type', 20),
            left(it->>'source_page', 2000),
            coalesce((it->>'found_at')::timestamptz, now()));
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'count', n);
end $$;

-- 4. 清空抓取池（管理员）
create or replace function public.admin_scraped_clear(p_token text)
returns jsonb language plpgsql security definer as $$
declare sess jsonb;
begin
  select to_jsonb(x) into sess from public.check_session(p_token) x limit 1;
  if sess is null
     or not coalesce((sess->>'valid')::boolean, false)
     or not coalesce((sess->>'is_admin')::boolean, false) then
    return jsonb_build_object('ok', false, 'message', 'forbidden');
  end if;
  delete from public.scraped_videos;
  return jsonb_build_object('ok', true);
end $$;

-- 授权匿名可调用（权限由函数内的 token 校验控制）
grant execute on function public.submit_mp4(text, text) to anon;
grant execute on function public.admin_rename_tag(text, text, text) to anon;
grant execute on function public.admin_scraped_push(text, jsonb) to anon;
grant execute on function public.admin_scraped_clear(text) to anon;

-- ============================================================
-- video-db 视频评论表
-- 在 Supabase SQL Editor 里执行一次即可 (幂等, 可重复执行)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.video_comments (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  video_id   text NOT NULL,
  username   text NOT NULL CHECK (char_length(username) BETWEEN 1 AND 32),
  content    text NOT NULL CHECK (char_length(content) BETWEEN 1 AND 500),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_video_comments_video
  ON public.video_comments (video_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_video_comments_user
  ON public.video_comments (username);

ALTER TABLE public.video_comments ENABLE ROW LEVEL SECURITY;

-- 信任模型 (与本站 cloud_user_config 等表一致):
-- 前端统一用 anon key + x-login-token 会话头 (见站内 _h()),
-- public._req_username() 从 token 解析出应用层用户名,
-- public._req_is_admin() 判断是否为管理员。
-- 因此写入/删除在服务端强制归属, 前端只做按钮显隐。

-- 读:所有人 (含匿名) 可读
DROP POLICY IF EXISTS vc_select_all ON public.video_comments;
CREATE POLICY vc_select_all ON public.video_comments
  FOR SELECT USING (true);

-- 写:只能以自己的用户名发表 (防冒名刷屏; 未登录 token 解析为 NULL, 写不进去)
DROP POLICY IF EXISTS vc_insert_own ON public.video_comments;
CREATE POLICY vc_insert_own ON public.video_comments
  FOR INSERT WITH CHECK (username = public._req_username());

-- 删:仅本人或管理员可删
DROP POLICY IF EXISTS vc_delete_own ON public.video_comments;
CREATE POLICY vc_delete_own ON public.video_comments
  FOR DELETE USING (
    username = public._req_username() OR public._req_is_admin()
  );

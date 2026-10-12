-- ============================================================
-- TOTP 种子轮换 (#8)
-- 背景: 旧种子曾明文公开在 k9m2x7.html，轮换后旧种子彻底失效
-- 执行位置: Supabase Dashboard → SQL Editor (需 service_role 或 owner)
-- 注意顺序: 先跑 SQL，再更新 k9m2x7.html 里的混淆种子，最后验证
-- ============================================================

-- 步骤 1: 生成新种子 (32 字符 Base32，可直接用于 TOTP App)
-- 先单独跑这一句，把结果复制下来备用：
SELECT upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 32)) AS new_totp_seed;

-- 步骤 2: 把新种子写入 system_config (把 YOUR_NEW_SEED 换成步骤1的结果)
-- UPDATE public.system_config SET value = 'YOUR_NEW_SEED', updated_at = now()
-- WHERE key = 'totp_secret';

-- 步骤 3 (验证): 确认已更新
-- SELECT key, left(value, 4) || '...' AS preview, updated_at
-- FROM public.system_config WHERE key = 'totp_secret';

-- 步骤 4: 更新 k9m2x7.html
--   用站内已有的 XOR+Base64 混淆脚本把新种子编码，
--   替换 k9m2x7.html 里旧的混淆值 (见该文件 122 行附近注释)，
--   重新上传 k9m2x7.html 到 GitHub Pages。
--   验证: 打开 k9m2x7.html 显示的 6 位码，应与 Google Authenticator
--   (手动添加该种子) 显示的一致，且能通过网站密码门。

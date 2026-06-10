-- ═══════════════════════════════════════════
-- 🌱 03_seed.sql — 管理员账号 + 默认数据
-- ═══════════════════════════════════════════

-- 管理员: kuo / kuo2026
INSERT INTO public.user_accounts (username, password_hash, vip_level, is_admin, verified, display_name)
VALUES ('kuo', 'a2ced91de6ae4ead293db6bf4d0a91ac92331c6ffe4c5a73fd30ddaa9537d302', 'ultimate', true, true, '站长')
ON CONFLICT (username) DO UPDATE SET is_admin = true, verified = true, vip_level = 'ultimate';

-- 默认激活码
INSERT INTO public.activation_codes (code, vip_level, max_uses)
VALUES ('VIP2026', 'vip', 100), ('VVIP2026', 'vvip', 50), ('SVIP2026', 'svip', 20)
ON CONFLICT (code) DO NOTHING;

-- 默认系统配置
INSERT INTO public.system_config (key, value) VALUES ('site_name', 'VideoDB') ON CONFLICT (key) DO NOTHING;
INSERT INTO public.system_config (key, value) VALUES ('announce_text', '') ON CONFLICT (key) DO NOTHING;

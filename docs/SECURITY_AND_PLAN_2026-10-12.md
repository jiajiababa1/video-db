# video-db 新增安全问题与规划问题 (2026-10-12)

> 本次 8 项任务执行中的审计发现。RLS 审计方法：用前端同款 anon key
> 对 21 张表做只读探测（SELECT limit 1 + 空 POST 看 RLS 反应），未写任何脏数据。

## 一、新增安全问题（按严重度）

### 🔴 P0: `videos` 表可被匿名 UPDATE
- 现象：`PATCH /rest/v1/videos?video_id=eq.XXX` 返回 204，无 RLS 拦截。
- 影响：任何拿到 anon key 的人（key 在前端代码里，混淆可逆）能改任意视频的
  标题/作者/播放地址/播放量，可挂马链、删库式破坏（`removed=true`）。
- 修复（Supabase SQL Editor 执行）：
  ```sql
  alter table public.videos enable row level security;
  drop policy if exists videos_anon_all on public.videos;
  create policy videos_anon_read on public.videos
    for select using (true);
  -- 写操作只允许 service_role；爬虫/回填脚本用 service key 走后端
  ```

### 🔴 P0: `scraped_videos` / `scrape_status` 可被匿名写入
- 现象：空 POST 返回 201。攻击者可向抓取池塞垃圾、伪造爬虫状态。
- 修复：同上，只保留 `select` 给 anon（或完全关闭 anon 访问）。

### 🟡 P1: `work_requests` 空 POST 返回 400（疑似可写）
- 400 = 通过 RLS 但数据校验失败，说明写通道是通的。建议一并收紧到只读。

### 🟡 P1: SQL 迁移文件未入库
- `sql/` 只有 comments.sql；SCHEMA.md 明确记载 20 张表、26 个 RPC 的定义
  都不在版本控制里。一旦 Supabase 出问题无法重建，也无法做变更审计。
- 建议：从 Dashboard 导出完整 schema（含 RLS policies、functions），
  入库为 `sql/schema.sql`，以后改表结构走 migration 文件。

### 🟢 P2: anon key 长期有效且无轮换机制
- key 写死在前端（混淆）。若泄露只能去 Dashboard 手动 Rotate。
- 建议：每季度轮换一次；轮换后同步更新 index.html / watch.html 里的混淆值。

### 🟢 P2: `verify_passcode` 防爆破依赖服务端计数
- 前端限流可被绕过（直接调 RPC）。确认服务端函数内有失败计数+锁定，
  否则加 `pg_sleep` 延迟或失败计数表。

## 二、规划问题

### 1. 单文件 1MB 架构已到维护极限
- index.html 约 1MB、900+ 函数，改一处需全量回归。之前多页面拆分被叫停，
  但至少应把 JS 按模块拆成 `assets/*.js` 并用 `<script src>` 引入
  （构建时合并即可，不影响部署）。

### 2. 解析链路单点故障
- 播放强依赖 twjn.php + video.twimg.com。任一挂掉全站不可播。
- 本次已加后端回填（#1）+ 断链巡检（#3），建议再补：多源 fallback
  （如备用解析接口）、直链 CDN 缓存。

### 3. 爬虫与前端的数据契约无文档
- 字段含义（如 `duration` 里塞直链、`video_url` 存 monsnode 链接）只有代码知道。
- 建议在 SCHEMA.md 补一节「字段语义约定」。

### 4. 备份策略缺失
- 95k 条视频 + 用户数据无定期导出。一旦 Supabase 项目出问题即全丢。
- 建议：每周 Action 定时 `pg_dump`（或按表 CSV 导出）存到仓库私有分支/Release。

### 5. 监控告警缺失
- 爬虫挂了、解析成功率掉了、磁盘满了，都没人知道。
- 建议：Action 跑完后调 Bark/Telegram webhook 推送关键指标；
  前端加个轻量探针页给站主看。

## 三、本次已交付（2026-10-12）
| # | 内容 | 位置 |
|---|---|---|
| 1 | MP4 后端回填脚本 + 手动触发 workflow | scraper/mp4_backfill.py, .github/workflows/mp4-backfill.yml |
| 2 | PWA（manifest + SW + 注册） | manifest.json, sw.js, index.html |
| 3 | 断链巡检脚本 | scraper/link_check.py |
| 4 | 独立播放页 | watch.html |
| 5 | RLS 审计（本文件第一部分） | — |
| 6 | 云同步建表 SQL 提取 | sql/05_cloud_user_data.sql（表未建，需用户执行） |
| 7 | 搜索历史（已存在，无需改动） | index.html ssRecent/ssHotWords |
| 8 | TOTP 轮换 SQL 与步骤 | sql/totp_rotate.sql（需用户执行） |
| + | rou.py 残留文件清除 | 已删除 scraper/rou.py |
| + | 反盗版 env-guard（上一轮） | index.html, k9m2x7.html |

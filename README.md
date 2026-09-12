# video-db

2048 伪装外壳 + monsnode 成人视频爬虫 + Supabase 后端 + GitHub Pages 静态站点。

## 架构

```
index.html          ← 唯一部署到 GitHub Pages 的文件 (2048 外壳 + 隐藏视频站 + 管理面板)
totp.html           ← 动态密码生成页 (含内部密钥, 仅供站主私下发给成员, 不部署)
scraper/main.py     ← GitHub Actions 爬虫 v11 (纯 HTTP 抓取列表/搜索 + 批量解析 MP4)
scraper/0*.sql      ← Supabase 数据库迁移 (按编号顺序执行, 01 → 最新)
.github/workflows/  ← GitHub Actions
```

## 爬虫 (scraper/main.py v11)

- **纯 HTTP, 不用浏览器**: monsnode 的列表页/搜索页是服务端渲染的静态 HTML, 用 `httpx`
  直连即可。旧版用 Playwright 真实导航, 被页面里同步加载的外部 CDN 脚本拖到 100% 超时
  → `pages_crawled=0`、一条都存不进 (这是「抓不全」的根因之一)。
- **抓取范围**: 归档首页 + `?page=1..20` (只认 `?page=`, 旧代码用的 `?p=` 被服务器忽略,
  永远只抓第 1 页)、排行榜 (24h/3d/7d/30d)、trending, 以及关键词搜索 `search.php`
  —— 搜索能直达整个历史库 (归档只保留最新约 1600 条)。搜索词按小时轮换起点, 多轮下来
  覆盖全部关键词。
- **MP4 解析**: `twjn.php?v=<id>` 返回 base64 编码的直链, 纯 HTTP 并发解析 (默认 20 路),
  每轮可解析数千条。失败不再永久放弃 (实测老视频的 twjn.php 依然有效, 旧版把它误判成死链,
  累积了约 2.9 万条假死链)。
- **批量写回**: 解析结果经 `apply_mp4_results(jsonb)` RPC 一次性更新上千行
  (`11_bulk_results.sql`)。数据库没有该函数时自动回退逐条 PATCH。
- **可调环境变量**: `MP4_WORKERS` (解析并发)、`RESOLVE_LIMIT` / `RESOLVE_BUDGET` (每轮条数/秒数)、
  `ARCHIVE_MAX_PAGES`、`SEARCH_MAX_PAGES`、`SEARCH_TERMS` (逗号分隔)、`CRAWL_TIME_BUDGET`。
- 运行模式: `python scraper/main.py full|resolve|test` (`test` 只做连通性自检, 不写库)。

## 安全模型 (09_lockdown.sql 之后)

- **客户端只读/只写必要数据**：`videos` 允许 anon SELECT/INSERT/UPDATE（爬虫与客户端 MP4 解析需要），
  `scrape_status` 允许 anon SELECT/INSERT；其余表（用户/激活码/会话/系统配置/管理员日志等）全部对 anon 关闭。
- **登录/注册/改密**：服务端 bcrypt 校验，不再在客户端比对哈希；服务端签发会话 token（`sessions` 表）。
- **密码锁 (TOTP)**：密钥存 `system_config.totp_secret`，服务端计算校验，页面里不再有算法常数。
  当前种子 `VIDEODB2026LOCKKEY`（S1=1241, P1=7919, P2=6271, M=7782311），5 分钟轮换，
  接受当前 + 上一窗口以容忍时钟偏差。
- **管理后台**：全部改为"会话 token 鉴权"的 RPC（`admin_exec` / `admin_*`），不再信任客户端上报的用户名。
- **代码完整性校验**：部署时 GitHub Actions 计算 `index.html` 的 SHA-256 写入
  `system_config.site_code_hash`；前端启动时拉取当前页面源码计算哈希比对——
  不一致则显示红色篡改警告横幅并禁止进入视频模式。另有每日定时 verify job 比对线上与仓库。
- **爬虫密钥**：建议把 GitHub secret `SUPABASE_KEY` 换成 service_role key
  （`upsert_videos`/`increment_retry` 等已对 anon 保留执行权，anon key 也可继续用）。

## 部署步骤

1. 在 Supabase SQL Editor 按编号顺序执行 `scraper/01_tables.sql` … `11_bulk_results.sql`。
   `10_rescrape_fix.sql` 修复重爬管线 (upsert_videos 崩溃 / 死链复活)；`11_bulk_results.sql`
   提供 MP4 结果批量写回 RPC —— 不执行 11 也能跑, 爬虫会自动回退逐条写入, 只是慢很多。
2. GitHub 仓库 Settings → Secrets：设置 `SUPABASE_URL`、`SUPABASE_KEY`（anon 或 service_role 均可）、
   `SUPABASE_SERVICE_ROLE_KEY`（pages.yml 写 `site_code_hash` 需要）。
3. GitHub Pages 开启（Settings → Pages → Source: GitHub Actions）。
4. 推送 `main` → `pages.yml` 自动部署 + 写哈希；`scraper.yml` 每 2 小时完整抓取、
   每小时批量解析 MP4 (公开仓库的 Actions 分钟数免费)。也可在 Actions 页手动触发
   `Scraper` 工作流: 模式选 `test` 做连通性自检, 选 `resolve` 只解析 MP4, 选 `full` 完整抓取。
5. 站主用 `totp.html`（本地打开）生成动态密码分发给成员；**不要把 totp.html 推到公开仓库**。

## 初始管理员

`kuo` 的 bcrypt 哈希已写入 09_lockdown.sql（明文密码由站主私下保管，首次登录后请立即修改密码）。

## 已知局限（未加固）

- `friends` / `messages` / `cloud_favorites` / `user_follows` / `site_pages` / `scraped_videos`
  仍对 anon 全开（这些功能的前端仍直接读写表，未迁移到 RPC）。
- `videos` 表仍允许 anon 写入（爬虫与客户端解析的代价）——被滥用时可写入脏数据，
  但无法触碰用户/会话/配置等敏感数据。
- 静态页面上的客户端 JS 无法真正"加密"隐藏信息——密钥/哈希/URL 对任何会看 DevTools 的人可见。
  安全边界是服务端 RLS + token 鉴权，而非前端混淆。
- 迪菲-赫尔曼/前端密钥交换不适用于单静态客户端场景（没有第二个活体参与方），
  因此采用"服务端鉴权 + 部署时哈希 + 定时校验"作为等效的篡改检测手段。

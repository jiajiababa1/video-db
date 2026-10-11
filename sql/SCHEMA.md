# video-db Supabase 数据字典 (SCHEMA.md)

> 生成日期：2026-10-12
> 来源：`index.html`（前端单文件应用）与 `scraper/*.py`（爬虫）的实际调用点逆向整理。
> 行号以 `video-db-review` 仓库 `main` 分支当前版本为准，后续改动请以代码为准。
>
> ⚠️ 重要缺口：仓库中**没有任何 `.sql` 建表/函数脚本**（代码注释里引用的
> `src/sql/*.sql`、`09_lockdown.sql`、`10_rescrape_fix.sql` 等均未入库）。
> 本文档只记录"代码怎么用数据库"，**不能**用来重建数据库。
> 建议尽快把 Supabase 里的表结构与函数定义导出为 SQL 并纳入版本控制。

---

## 一、表清单（20 张，全部经实测存在）

| 表名 | 用途 | 代码中实际用到的关键列 | 主要调用处 |
|---|---|---|---|
| `videos` | 视频库主表：视频网格、搜索、播放器的数据源；爬虫写入目标 | `video_id`(业务主键), `id`(数值自增), `author`, `title`, `thumbnail_url`, `duration`, `views`, `has_mp4`, `mp4_url`, `needs_rescrape`, `removed`, `playable`, `vip_early`, `vote_up`, `vote_down`, `source_page`, `source_section`, `monsnode_video_id`, `retry_count`, `mp4_checked_at`, `scraped_at`, `created_at` | 前端主列表 `loadMore`(5742/5782/6049)、单条查询 `video_id=eq.`(4932等)、爬虫 `scraper/main.py`(873/1036/1130/1348)、`text_backfill.py`(406/421) |
| `user_accounts` | 用户账号：登录/注册/VIP等级/封禁/管理员 | `username`, `password_hash`(仅健康检查验证不可读), `is_admin`, `vip_level`, `vip_expires_at`, `verified`, `banned`, `ban_reason`, `device_id`, `email`, `display_name`, `created_at`, `last_login` | `showUserProfile`(9730)、`showFriendCard`(10078)、`userExists`(9837)、健康检查(10369/10376/10389)；业务查询均为白名单列，无 `select=*` |
| `sessions` | 登录会话（服务端校验用） | （前端仅做连通性探测 `?limit=1`） | 健康检查 `checkDBStatus`(10430)：验证匿名头读不到该表 |
| `system_config` | 键值配置表 | `key`, `value`, `updated_at`；实际 key 有 `totp_secret`、`site_name`、`announce_text`、`ban_title` 等 | `admin_config` RPC 读写(10694/12242)、`remoteTime`(172)、`fetchBanConfig`(13795) |
| `friends` | 好友关系（双向记录） | `user1`, `user2`, `status`(pending/accepted), `created_at` | `handleFriend`(9813)、`addFriend`(9984)、`removeFriend`(9985)、`cancelFriendRequest`(9987)、`getFriendRows`(10001) |
| `user_follows` | 用户关注作者 | （按 `username`/`author` 过滤） | `followUser`(9777)、`showUserProfile`(9738)、`showFriendCard`(10083) |
| `cloud_user_config` | 云端用户配置：外观偏好、黑名单、搜索偏好、联动 key（按账号存，敏感 key 加密后存） | 整行 JSON 式 upsert（`username` + 配置字段） | `cloudPushConfig`(4296)、`cloudPullConfig`(4308) |
| `cloud_user_data` | 云端用户数据备份：观看历史/收藏/稍后看 | `username`, `kind` in ('hist','fav','wl'), `video_id`, `watched_at`；上限 hist 200 / fav 500 / wl 200 | `_cloudTable`(4087) 起的云同步模块；建表 SQL 内嵌在代码注释 (4088 起，`src/sql/05_cloud_user_data.sql` 未入库） |
| `board_groups` | 板块群（群聊） | `id`(数值), `name`, `owner`, `avatar_url`, `description`, `entry_mode`(direct/question), `entry_question`, `entry_answer`, `mute_all`, `status` | `submitCreateBoard`(13515)、`bcSaveSettings`(13688)、`bcToggleMuteAll`(13636)、`loadHubPage`(13461)、`bcApproveGroup`(13540) |
| `board_members` | 群成员 | `group_id`, `username`, `role`(owner/admin/member), `muted_until`, `mute_all_exempt`, `joined_at` | `ensureMember`(13452)、`bcMute`(13693)/`bcUnmute`(13703)、`bcKick`、`bcPromote`、`bcExempt` |
| `board_messages` | 群聊消息（真实消息走 Supabase，实时刷新靠 server-plugin 广播） | （按 `group_id` 拉取） | `boardSend`(13607)、`refreshBoardRoom`(13581) |
| `board_join_reqs` | 入群申请（需回答问题/审核） | `group_id`, `applicant`, `answer`, `status`(pending) | `submitJoinAnswer`(13625)、`bcApproveJoin`(13720)、`bcRejectJoin`(13721) |
| `announcements` | 站内公告（**当前表为空**，前端有完整的发布/展示/删除功能） | `id` | `loadAnnouncements`(10536)、`publishAnnounce`(10556)、`deleteAnnounce`(10570)、`showAnnounceHistory`(10575) |
| `works` | 作品墙作品 | （按作者/状态过滤） | `loadWorksPage`(12979)、`submitWork`(13159)、`approveWork`(13238) |
| `work_requests` | 作品投稿审核队列 | `status` | `submitWork`(13215)、`approveWork`(13235)、`rejectWork`(13239)、`auditWorks`(13244) |
| `site_pages` | 站主自定义页面（/links 等） | `slug`, `title`, `content` | `saveSitePage`(11584)、`editSitePage`(11605)、`deleteSitePage`(11624)、`openSitePage`(11473) |
| `bans` | 封禁记录（展示封禁原因） | （按 `username` 查） | `fetchBanReason`(13790)、`showAdminAudit`(10839) |
| `admin_log` | 管理员操作审计日志 | `target`, `detail`, `created_at` | `asAudit`(7366)、`showAdminAudit`(10838)、`doAdminDbClean`(12491/12494) |
| `scraped_videos` | 爬虫抓取的原始视频（浏览器抓取页/待处理池） | 整行 | `scrapeBrowserPage`(11801)、`showAdminScrapedVids`(12007)、`delScrapedVid`(12030)、`doAdminDbClean`(12490) |
| `scrape_status` | 爬虫运行状态（上次运行/发现数/入库数） | `last_run`, `videos_found`, `videos_saved` | `fetchLastScrape`(7790)、`showStats`(9378)、爬虫写回 `scraper/main.py`(1246) |

> 注：健康检查 `checkDBStatus`(10333 起) 还会探测 `messages`、`user_vips`、`activation_codes` 三张表，
> 期望它们**对匿名头不可读**（RLS 锁定验证）；`cloud_favorites` 在期望表列表中且经实测存在，
> 但前端业务代码无读写，疑似历史遗留。

---

## 二、RPC 清单（26 个，全部经实测存在；参数以代码实际调用为准）

### 账号与会话

| 函数名 | 参数（实际调用） | 用途 | 调用处 |
|---|---|---|---|
| `verify_passcode` | `p_code`, `p_device_id` | 动态密码（TOTP）门验证；服务端有防爆破计数 | `checkPassword`(3703) |
| `check_session` | `p_token` | 会话校验：自动登录(12079)、登录续期(3675)；返回 `{valid, username, is_admin, vip_level}` | `extendAuth`(3675)、`autoLogin`(12079) |
| `login_account` | `p_username`, `p_password`, `p_device_id` | 账号登录，返回 ok/message/is_admin 等 | `doLogin`(9535)；前端限流 8 次/分钟 |
| `register_account` | `p_username`, `p_password`, `p_device_id`, `p_captcha_id`, `p_captcha_key` | 账号注册（含图形验证码） | `doRegister`(9665) |
| `logout` | `p_token` | 登出，使服务端会话失效 | `clearLoginSession`(12059) |
| `change_password` | `p_username`, `p_old_password`, `p_new_password` | 修改密码，成功后清本地加密 key 并要求重登 | `doChangePassword`(9801) |
| `redeem_code` | `p_username`, `p_code` | VIP 激活码兑换，返回 `vip_level`/`vip_expires_at`/`permanent` | `redeemVip`(12880) |

### 爬虫（`scraper/main.py`）

| 函数名 | 参数（实际调用） | 用途 | 调用处 |
|---|---|---|---|
| `upsert_videos` | `videos`（数组，批量） | 批量写入视频；空字段不覆盖已有值，`has_mp4` 只升不降 | `sb_save`(1111/1118)；失败时自动降级为逐条调用 |
| `apply_mp4_results` | `p_results`（数组，每批 1000） | MP4 解析结果批量写回；库中无此函数时自动回退逐条 PATCH | `main.py`(1170) |
| `increment_retry` | `p_video_id` | MP4 解析失败时该视频重试计数 +1 | `batchResolveMp4`(8506) |
| `reset_retry_batch` | `p_limit`（前端传 300） | 重置一批死链的重试计数，使其重新进入解析队列 | `doVideoMgmtQuick`(10933) |

### 私信（好友聊天；函数名带 `_t` 后缀是刻意命名，见 10346 注释）

| 函数名 | 参数（实际调用） | 用途 | 调用处 |
|---|---|---|---|
| `send_message_t` | `p_token`, `p_to`, `p_content`；表情/语音/位置额外带 `t`, `v` 或 `t`, `n`, `lat`, `lng` | 发送私信（文本/表情/语音/位置） | `sendChat`(10204)、`sendSticker`(10228)、`uploadVoice`(10291)、`sendLocation`(10306) |
| `get_conversation_t` | `p_token`, `p_with`, `p_limit` | 拉取与指定用户的私信会话 | `refreshMessages`(10188) |
| `unread_count_t` | `p_token` | 未读私信数（>0 时 toast 提醒） | `checkUnread`(10313) |

### 管理员（均需 `p_token` 且服务端校验管理员身份）

| 函数名 | 参数（实际调用） | 用途 | 调用处 |
|---|---|---|---|
| `admin_exec` | `p_token`, `p_action`, `p_target`, `p_detail` | 通用管理员操作：升/降管理员、删用户、封禁/解封 | `doSetAdminQuick`(10634)、`delUserAccount`(10650)、`doAdminBanUser`(12268)、`doAdminUnbanUser`(12295)、`adminBanQuick`(12303)、`adminUnbanQuick`(12304) |
| `admin_config` | `p_token`, `p_key`, `p_value` | 读写 `system_config` 键值 | `saveConfig`(10694)、`upsert`(12242) |
| `admin_broadcast_dm` | `p_token`, `p_recipients`, `p_content` | 管理员群发私信，返回 `sent` 条数 | `doAdminMassNotify`(12522) |
| `admin_delete_videos` | `p_token` + (`p_ids` 数组 / `p_filter`+`p_value`) | 删除视频：按 id 批量删，或按条件删（如 `no_mp4`、按栏目） | `doAdminDelVideo`(10769)、`doAdminDelVideoBatch`(10787)、`doVideoMgmtQuick`(10945)、`adminDelTag`(11975)、`doAdminDbClean`(12493) |
| `admin_generate_code` | `p_token`, `p_level`, `p_uses`, `p_duration_minutes`, `p_permanent` | 生成 VIP 激活码 | `doAdminGenCode`(12635) |
| `admin_list_codes` | `p_token` | 列出激活码 | `showAdminVipCodes`(12603) |
| `admin_recent_messages` | `p_token`, `p_limit` | 最近私信（内容审计） | `showAdminMessages`(10794) |
| `admin_reset_password` | `p_token`, `p_target`, `p_new_password` | 管理员重置指定用户密码 | `doAdminResetPwd`(10751) |
| `delete_old_messages` | `p_token`, `p_days` | 清理 N 天前的群聊消息 | `doAdminDbClean`(12492) |
| `delete_works` | `p_token`, `p_ids`（数值数组） | 批量删除作品墙作品 | `deleteSelectedWorks`(12983) |

### 封禁申诉

| 函数名 | 参数（实际调用） | 用途 | 调用处 |
|---|---|---|---|
| `ban_appeal_send` | `p_username`, `p_content` | 被封禁用户提交申诉 | `banContactSend`(13924) |
| `ban_appeal_thread` | `p_username`, `p_limit` | 拉取申诉对话线程 | `banContactRefresh`(13905) |

---

## 三、调用约定（代码中观察到的规律）

- 所有请求头：`apikey` + `Authorization: Bearer <anon_key>`；登录后额外带 `x-login-token`（见 `_h()`）。
- RPC 统一用 POST + JSON body；返回多为数组，取 `[0].ok` / `[0].message` 判定。
- 管理员 RPC 全部要求 `p_token` 为管理员会话 token，服务端二次校验。
- `verify_passcode` 有服务端防爆破：失败计数由 `increment_retry`-like 机制累计（前端另有 8 次/分钟限流）。

# 国内中转 (Cloudflare Worker)

目的: 让 App 在不开梯子时也能播 Twitter 源视频 (video.twimg.com) 和看封面 (pbs.twimg.com)。

## 部署 (一次性)

1. 用户本人注册 Cloudflare 账号 (dash.cloudflare.com, 邮箱+密码, 免费)。
2. 左侧 Workers & Pages → Create → Worker, 名字随意 (如 vdb-relay), Deploy。
3. Edit code: 把 worker.js 全文粘进去替换默认代码, Deploy。
4. 拿到地址: https://vdb-relay.<账号子域>.workers.dev
5. 自测: 浏览器打开 https://<地址>/pbs.twimg.com/media/<任意图> 能出图即通。

## App 接入 (部署完成后做, v1.7.3)

- Resolver: 解链得到的 video.twimg.com 地址改写为 <中转地址>/video.twimg.com/... 再交给播放器。
- CachedImage: pbs.twimg.com 封面同样改写。
- 直连仍优先或中转优先待实测决定 (中转通了就中转优先, 因为国内直连 twimg 基本不通)。

## 注意

- workers.dev 域名在国内个别运营商可能也不稳; 真不稳时绑一个自己的域名到 Worker 会好很多 (需有域名)。
- 免费版每天 10 万次请求: 封面走边缘缓存, 视频是分段 Range 请求, 个人使用足够。

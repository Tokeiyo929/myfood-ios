# MyFood iOS

MyFood 的 iOS 端（uni-app / Vue 2），复用 myfood-worker 后端（Neon PostgreSQL + 腾讯 COS）。

## 目录结构
- `pages/index/index.vue` — 记录页（拍照/相册上传、今日记录列表、评论）
- `pages/detail/detail.vue` — 详情页（价格 [原价,折扣]、类别/原料/味道、编辑/删除）
- `pages/edit/edit.vue` — 编辑页
- `common/api.js` — 后端接口封装（对应 myfood-worker routes）

## 开发流程（Windows，无 Mac 也可）

1. **安装 HBuilderX**（DCloud 官方 IDE，Windows 版免费）
2. 用 HBuilderX 打开本目录（文件 → 打开目录）
3. 运行验证：运行 → 运行到手机或模拟器，或先在 内置浏览器 里看基本交互
4. **云打包 iOS**：发行 → 原生App-云打包 → 选 iOS，包名如 `com.tokeiyo929.myfood`，选"打正式包"（会生成 .ipa）
   - 无需苹果开发者账号即可云打包（生成的是未签名 ipa）
5. **签名安装到 iPhone（免费 Apple ID，7 天有效）**
   - 电脑装 [Sideloadly](https://sideloadly.io)（Windows 版）
   - 数据线连 iPhone，iTunes/Apple Devices 装好驱动
   - Sideloadly 拖入 .ipa → 输入你的 Apple ID → Start，手机上就装好了
   - 手机首次运行需：设置 → 通用 → VPN与设备管理 → 信任该 Apple ID 开发者
   - **每 7 天**要连电脑重新签一次（免费账号限制），重签同一 ipa 数据不丢
6. 后端直连 `myfood-worker.keiyokaze.workers.dev`：国内直连 Cloudflare 可能被断，需手机开 Clash 代理

## 注意
- 拍摄时间 iOS 端用上传时刻（小程序同款逻辑）
- manifest.json 里的 iOS 证书字段留空即可（走云打包+ sideload 不需要）

# MyFood iOS (Capacitor)

MyFood 的 iOS 端：原生壳（Capacitor）+ 内置网页（www/），复用 myfood-worker 后端。**真 app**，有图标、独立运行。

## 构建（全自动，无需本地 Mac）
- GitHub Actions（`.github/workflows/build-ios.yml`）：每次 push 到 master 自动在 macOS runner 上构建**未签名 ipa**
- 到仓库 Actions 页面 → 最新 run → Artifacts 下载 `myfood-unsigned-ipa`

## 安装到 iPhone（Sideloadly，免费 Apple ID，7 天有效）
1. 下载 artifact 得到 `myfood-unsigned.ipa`
2. 打开 Sideloadly，数据线连 iPhone（手机点"信任"）
3. 拖入 ipa → 输入 Apple ID → Start
4. 手机：设置 → 通用 → VPN与设备管理 → 信任 Apple ID
5. 每 7 天连电脑重签（打开 Sideloadly 插线即自动续签）

## 结构
- `www/` — 应用本体（原生 JS SPA：api.js + app.js + app.css + index.html）
- `ios/App/` — Capacitor 生成的原生工程（xcodebuild 构建）
- `capacitor.config.json` — appId com.tokeiyo929.myfood

## 本地开发
- 改 `www/` 下的文件 → `npx cap sync ios` → push（或直接 push，CI 会 sync）
- 注意：`ios/App/App/public/` 是 www 的拷贝，以 www/ 为准

## 注意
- 拍摄时间用上传时刻；后端 workers.dev 需手机开 Clash
- iOS 上照片选择用 WKWebView file input（iOS 自动把 HEIC 转 JPEG）

# 觅食记 · MyFood iOS

原生 SwiftUI 应用，最低 iOS 17。支持美食记录、拍照/相册建档、详情编辑（含选填的新鲜度：日清/短保/冻转鲜/长保，四选一）、评论和语音输入、Vision OCR 划选、中国/欧洲美食地图、类别排名、后台轨迹、好词好句摘抄。API 地址统一在 `ios/App/App/API.swift`。

## 开发与构建

用 Xcode 打开 `ios/App/App.xcodeproj`，选择 App scheme。真机运行需配置开发签名；现有工程使用 Swift 5 语言模式，保持与 CI 工具链一致。

```sh
cd ios/App
xcodebuild -project App.xcodeproj -scheme App -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO
```

推送 master 的 iOS、测试或 workflow 改动后，Actions 构建设备版和模拟器版、运行隔离回归与进程内自测、巡访 13 个页面并上传截图。全部通过才发布未签名 IPA；可用 Sideloadly 重签安装。其他分支可通过 `workflow_dispatch` 验证，产物仅上传 artifact。

## 测试

核心回归需 macOS Swift 工具链，当前使用 CryptoKit、Network 和 Observation，不能直接照搬到 Linux：

```sh
swiftc -DDEBUG ios/App/App/API.swift ios/App/App/AppState.swift ios/App/App/OfflineStore.swift ios/App/App/GCJConverter.swift ios/App/App/SyncLog.swift ios/App/App/SyncDiff.swift ios/App/App/TestSupport.swift tests/CoreTests.swift -o /tmp/myfood-core-tests
/tmp/myfood-core-tests
python3 -m unittest discover -s tests -p 'test_*.py'
bash tests/test_simulator_runner.sh
```

Debug App 的 `-autoTest` 验证 API 编解码、配置、评论草稿、新鲜度单选/清空、离线重放和真实页面模型；`-autoSmoke` 打开历史、详情、OCR、快速建档、两张美食地图、省份面板、排名、今日轨迹、每日记录、某天轨迹、设置和摘抄。runner 通过 marker/ack 握手截图。API 和远端图片共用可注入的 URLSession；fixture 未实现的请求直接失败，不访问正式服务。Release 不启用测试参数。首次授权、真实相机/语音、后台定位与锁屏恢复仍需设备验证。

`tests/backend_api_test.py` 为独立后端集成测试，会创建并删除临时记录，必须显式提供测试服务地址：

```sh
python3 tests/backend_api_test.py http://localhost:8787
```

可加 `--proxy URL`；`--proxy none` 直连，省略则遵循系统代理。临时记录在 finally 中清理；网络故障仍可能导致服务端删除未完成，脚本会报告失败及记录 ID。

## 结构与边界

- `MyFoodApp.swift`：SwiftUI 生命周期、tab 和导航路径；页面状态由 `@Observable` 模型维护。
- `AppState.swift`：共享配置校验、评论草稿、轨迹上传队列和排名变更计算。
- `tests/`：隔离回归、模拟器 runner、显式目标后端集成测试。
- 图片尺寸、JPEG 质量、分页和默认偏好来自已验证的 `/api/config`；配置失败允许重试。
- `OfflineStore.swift`：配置/记录/类别/轨迹/摘抄/图片缓存，以及离线写队列和重放。
- `SyncDiff.swift`：git 式同步 Diff 引擎（见下）。
- 网络不可达才回退缓存或入队；业务错误原样提示。队列重放失败保留操作与原图，手动同步报告错误。队首错误修复后继续按序重试。
- 同步是 git 式的：快照 `synced.json` 记上次同步完成的远端状态，静默拉取存 `remote.json` 暂存（只存不应用，等同 fetch）。设置页同步卡据此显示 ↑本地待推送 / ↓远端更新 / ⚠冲突；无差异时按钮置灰。手动同步 = 先拉取合并非冲突变化，再排空队列推送；本地与远端都改了同一条记录时逐条整选「用本地/用远端」（可展开字段明细），全部解决后续跑推送。推送成功后增量并入快照，同步完成后以服务端真值重建快照。启动/恢复联网也会静默暂存并自动补传，冲突记录的队列项跳过留给手动同步。
- 记录比较只看内容字段：图片签名 URL 剥掉过期参数只比稳定 path，`modify_at`/`repurchase` 为服务端派生不参与。远端删除检测 = 快照有、拉取没有；摘抄只有建/删不产生冲突；类别/原料/轨迹不纳入 Diff。
- 离线新档使用负数 ID 与稳定 `client_key`；同步创建后替换为服务端 ID，并改写后续编辑目标。删除本地新档直接撤销创建。
- 缓存写盘使用串行后台队列，待同步操作同步落盘；轨迹待传点也持久化。队列与缓存格式保持兼容。
- 轨迹保存 WGS-84，国内显示转换 GCJ-02，境外直通。拍摄时间使用上传时刻，元数据为 `image_metadata.taken_at`。

提交演进、保留机制的原因和本次清理见 [历史审查](docs/history-review.md)。

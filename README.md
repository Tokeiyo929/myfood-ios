# MyFood iOS

原生 Swift/UIKit 应用，使用 MapKit、CoreLocation、Speech；最低 iOS 15。后端为 myfood-worker，API 地址统一在 `ios/App/App/API.swift`。

## 开发与构建

用 Xcode 打开 `ios/App/App.xcodeproj`，选择 App scheme。真机运行需配置开发签名。

```sh
cd ios/App
xcodebuild -project App.xcodeproj -scheme App -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO
```

推送 master 的 iOS、测试或 workflow 改动后，Actions 构建未签名 IPA、执行隔离回归及模拟器巡访。成功后上传 artifact 并发布 release；可用 Sideloadly 重签安装。

## 测试

纯 Swift 核心回归可在 Mac 或 Linux Swift 6 环境运行，无第三方依赖：

```sh
swiftc -DDEBUG ios/App/App/API.swift ios/App/App/AppState.swift ios/App/App/TestSupport.swift tests/CoreTests.swift -o /tmp/myfood-core-tests
/tmp/myfood-core-tests
python3 -m unittest discover -s tests -p 'test_*.py'
```

Debug App 启动参数 `-autoTest` 与 `-autoSmoke` 使用 URLProtocol 内存数据，未知 API 端点直接失败。前者测试实际请求编解码和核心状态，后者等待目标页面就绪，由 runner 截取八张页面截图。Release 不启用测试参数。真实拖动、首次授权、后台定位仍需模拟器或设备验证。

`tests/backend_api_test.py` 为独立后端集成测试，会创建并删除临时记录，必须显式提供测试服务地址：

```sh
python3 tests/backend_api_test.py http://localhost:8787
```

可加 `--proxy URL`；`--proxy none` 直连，省略则遵循系统代理。临时记录在 finally 中清理；网络故障仍可能导致服务端删除未完成，脚本会报告失败及记录 ID。

## 结构与边界

- `ios/App/App/`：页面、API、现有 AppConfig、轨迹与语音管理器。
- `AppState.swift`：共享配置校验、评论草稿、轨迹上传队列和排名变更计算。
- `tests/`：隔离回归、模拟器 runner、显式目标后端集成测试。
- 图片尺寸、JPEG 质量、分页和默认偏好来自已验证的 `/api/config`；配置失败允许重试。
- 拍摄时间使用上传时刻，元数据为 `image_metadata.taken_at`。定位使用 WGS84，国内地图可能存在坐标偏移。
- 轨迹上传失败保留内存批次，联网后重试；进程退出后的恢复尚未落盘。服务端排名逐条更新，部分失败需在弹窗重试。

# 历史审查与清理依据

基线：`cf489e7`（2026-11-08）。核对完整非 shallow 历史的提交说明、文件变更范围、关键故障修复，以及现有全部 Swift 源码、测试与构建配置。逐条提交索引见文末。

## 为什么会有这些功能和机制

- `179ceeb` 至 `95b4e49`：先复用小程序形态快速形成 iOS 入口，经过 uni-app、Capacitor，加入地图与原生后台定位。网页方案的包和桥接已经在 `2de7360` 删除，不应重新引入。
- `2de7360` 至 `0657ef0`：改用原生 UIKit、MapKit、CoreLocation，解决原生权限、轨迹和打包需求；随后的工程引用/类型修复保证能编译。
- `4e2e20f`、`dfd9666`：建立可侧载的未签名 IPA；使用国内可访问的自定义 API 域名。不能把当前域名替回被阻断的 workers.dev。
- `bd9bd10` 至 `daa9271`：历史卡片对齐小程序；详情补评论、味道、偏好、原料、价格、复购；语音解决现场输入，OCR 减少包装文字录入；美食地图通过已吃类别解锁省份和排名；照片附带时间与位置。
- `3aa5f18` 至 `dd22ff6`：截图巡访经历窗口查找、模拟器签名/AMFI、进程退出和黑图故障。最终由 runner 截屏、app 写 marker/等 ack。握手、进程退出检查和超时是真实故障保护，保留。
- `ae8c884` 至 `160c7ab`：语音权限改为按需请求；偏好按服务端字符串发送；`worth_it` 读字符串、写 Bool；搜索正确编码；配置统一校验；引入隔离、进程内和 runner 回归。信任边界校验不是应删的防御性代码。
- `6a77c98`、`700372d`：历史居中，拍照/相册直接快速建档；上传与定位并行，定位 10 秒超时；轨迹默认自动记录。历史入口和自动记录是明确产品选择，保留。
- `d0b9e65` 至 `de5812f`：断网浏览、编辑、建档、换图、排名、轨迹可用；负数本地 ID、client_key 幂等创建和后续 patch 目标改写支持重连。`b03eaa9` 修复 NSLock 重入死锁，`d2eca1c` 修复本地删除遗漏后续编辑；锁内 *Unlocked 调用和连带撤销必须保留。
- `3b82176` 至 `b84b84f`：增加摘抄与手动同步；缓存后台写盘、图片后台解码；轨迹 WGS-84 存储、GCJ-02 显示；12 页拟真截图、图标与显示名。异步写盘后的 flushIO、纠偏向量回归有明确用途。
- `6fa3ed2` 至 `cf489e7`：完整迁移 SwiftUI，提升状态与页面维护性；后续修复类型推断、环境注入、导航注册、搜索模型自包含和巡访诊断。旧 UIKit 控制器已删除，但迁移带来重复状态和旧文档，本次据此整理。

## 本次清理

1. 评论只由 CommentDraft 持有，去掉不同步的 comments/editingIndex 副本；连续保存刷新草稿与完整缓存记录。
2. 详情通过带 ID 的 SwiftUI task 加载，去掉 needsLoad/父子 onAppear 顺序依赖。轨迹路径明确区分每日列表与某天地图，删去空包装和提前加载兜底。
3. 图片路径只走 API.imageUrl，味道文案只走 AppConfig.flavorLabel；删除无调用方法、从不赋值的拖动状态、空删除动作、重复绑定回调。
4. 换图后清空旧视图图片、取消过期加载；图片磁盘读取/解码回后台，测试图片同样使用 fixture 会话。
5. OCR 展示状态由模型派生；识别由页面 task 启动，同步 Vision 工作放后台，去掉可能重复 resume 的 continuation。划选以起点决定选择/取消，跨格连续处理。
6. 手动同步由模型独占状态，失败不再被按钮覆盖成成功。重放并发调用等待同一个任务；失败保留队列和原图，不丢弃待传修改。
7. 换图队列携带原图；兼容旧队列从 image_path 恢复原图信息。创建 ID 在 API 校验，删除本地新档不请求负数服务端 ID。
8. 快速建档只组装一次记录，上传或创建中途断网都进入同一离线流程，重试沿用原 client_key。
9. 网络与轨迹状态改为 Observation，移除 UIKit 时代无人订阅的回调。麦克风权限使用现有 iOS 17 支持的 AVAudioApplication API。
10. README 更新实际平台、文件清单、持久化、纠偏与 12 页测试；CI 增加构建超时和正式分支发布限制。部署目标、Swift 语言模式、持久化格式和 API 业务协议保持兼容。

## 验证与边界

- 本地：Python 后端测试工具的 3 个模拟服务用例、runner 的 7 个成功/失败场景、git diff --check。
- macOS CI：设备 Release、模拟器 Debug、核心隔离回归、进程内自测、12 页截图巡访；构建结果和目检记录随本次验证结果补充。
- 新增回归覆盖评论编辑与连续保存、OCR 连选/取消、本地记录和摘抄删除、换图重放、坏创建响应、失败保留原图/队列、业务错误不误入队和手动同步错误提示。
- 真机相机、语音授权、后台定位与锁屏恢复没有被模拟器 fixture 代替；需设备验证。没有向正式后端写测试记录。
- 同步队首失败会停止后续重放并显示错误，保留数据；永久坏操作需要修正，不能用丢弃操作制造“成功”。缓存后台写盘和离线入队仍沿用既有持久化边界，本次没有改数据库格式或引入新层。

## 完整提交索引

- 179ceeb init myfood-ios: uni-app skeleton (index/detail/edit + api)
- f62b769 switch to Capacitor native shell: www SPA + GitHub Actions unsigned ipa build
- b8fa136 fix: align capacitor versions with lockfile (8.x)
- 7b6c7f3 ci: node 22 for capacitor 8
- 8ba177e add map page with track recording (geolocation + track API + OSM tiles)
- 15e90ec tab architecture: center map tab (default), record/history/tracks/settings tabs
- 95b4e49 track: foreground 3s + native background geolocation watcher, dedup by distance
- 2de7360 rewrite: pure native Swift app (UIKit+MapKit+CLLocationManager), remove Capacitor entirely
- 104b192 fix: rename MainTabBar.swift ref to MainTabBarController.swift in pbxproj
- f4bfd8f fix: swift compile errors round 1
- 0657ef0 1
- 4e2e20f CI 对齐 outfit-scorer：模拟器冒烟截图自检 + IPA 发 Release 免登录下载
- dfd9666 fix(api): custom domain myfood.tuqingyu.xyz (workers.dev blocked in CN)
- bd9bd10 feat: 历史页对齐小程序（搜索/分页/卡片/味道材料标签/复购/偏好着色）+ 绿主题
- 34d7f40 fix: 历史页 #selector(refresh) 与局部变量重名导致编译失败
- 6901e8f feat: 语音输入评论 SFSpeechRecognizer + 详情页编译修复
- 9b963cb feat: OCR 划选识别（Vision 字格划选填入名称/品牌/原料）+ 修 VoiceManager 缺 import UIKit
- 81cd2b3 feat: 美食地图（中国/欧洲 GeoJSON + 省份点选 + 类别排行榜拖拽交换）
- daa9271 feat: 记录页评论面板（🎤 语音）+ 上传定位元数据（taken_at/经纬度）
- 3aa5f18 feat(ci): SmokeTour auto-walks all pages and uploads screenshots
- 8d93bf5 fix(ci): SmokeTour keyWindow lookup without flatMap chain
- eeb28a2 fix(ci): isKeyWindow, not isKey
- 62e161b ci: add smoke-tour diagnostics to artifact
- 37c88de ci: never fail smoke-tour step, always upload diagnostics
- 58806ea feat(ci): tour logs, viewDidAppear trigger, debug to release
- 4c580ef fix(ci): escape newline literal in tour logger
- b624634 ci: collect simulator crash reports and app log into diagnostics
- c22a2c9 ci: unconditional args diagnostic, ps-based process check
- b2f1065 ci: keep default ad-hoc signing for simulator build (AMFI kill), earlier probes
- 1122996 ci: console-mode launch to capture app stdout and exit reason
- 488e79a ci: background console launch with shell watchdog
- c03f6b6 ci: codesign verify + AMFI log capture
- d23c9d9 ci: rerun
- d0a6d9d ci: rerun
- 41b6642 fix(map): add dishScroll to panel before activating constraints
- cb9a427 ci: attach smoke screenshots to release
- a5595b7 ci: rerun
- 8075c15 smoke: allow data to load before snapshots; rank opens from visited categories
- dd22ff6 smoke: runner-side simctl screenshots via marker/ack handshake (app-side render went black)
- ae8c884 fix: request voice permissions on demand instead of at page appear
- 0d9a51f fix preference type mismatch: send string value instead of Int, backend 400 invalid preference; APIError shows real message
- 2b6d17c fix currentPref property type Int to String
- f4fbb80 fix: gesture/worth_it/charset/map-stretch/tracks IA + autoTest CI
- 10cfbec fix(test): AppConfig 非 Equatable，neq 改 eqb
- 160c7ab 去除防御性编程
- 6a77c98 feat: 历史居中并吞记录页(拍照/相册入口)；列表按最后修改日期倒序
- 700372d fix: 添加记录并行定位+10s超时兜底；轨迹默认自动记录去手动开关；地图顶部对齐；选省列表全宽行；去悬浮历史按钮；smoke 补 03-record
- d0b9e65 feat(offline): 全功能离线可用——磁盘缓存+离线写队列+联网自动同步
- 1885b87 fix(offline): AppConfig.loading 元组任务类型对齐（Task<(raw, config), Error>）
- b589b9f ci: 核心回归拆三步+独立超时（定位上一 run 卡死在 Core regression 步骤）
- acead32 ci: CoreTests stdout 行缓冲，超时时保留逐条 PASS 定位卡死点
- 06887a1 test: 离线用例加 MARK 逐语句标记定位卡死点
- b03eaa9 fix(offline): records() 在持锁内调用带锁 loadJSON 自死锁——改 loadJSONUnlocked；去调试 MARK
- d2eca1c fix(offline): cancelPendingCreate 连带撤销同 clientKey 的 patch（本地记录离线删除语义）+ 用例对齐
- de5812f test: 撤销用例断言对齐——队列余下已改写 patch@42 属预期
- 3b82176 feat: 键盘点击空白收起；设置页常驻手动同步；更多页改好词好句摘抄
- 39e1531 fix: rebuildRecords 入参类型（dict 而非数组）
- 0d0ab90 fix: respondQuotes 参数标签
- c826a71 fix(track): 国内轨迹纠偏 GCJ-02 显示；perf: 磁盘 IO/图片解码全部移出主线程
- a87fc9f fix: GCJConverter 独立文件（纯 Foundation，加入 CI swiftc 隔离测试集与 pbxproj）
- f7d2927 feat: 视觉巡访扩到 12 页（一/二/三级全覆盖）+ fixture 拟真化 + 图标/应用名 + 轨迹页当前位置居中
- 0966ea8 feat: 应用显示名改为 觅食记
- 99a59cf fix: fixture price 字面量显式 [Any]（Float16 推断歧义）
- b84b84f fix(ui): 视觉目检修复 6 处——地图垂直居中/摘抄排序/排行底部避让/chip 拉伸/OCR 字格过高/轨迹状态标位置
- 6fa3ed2 feat: 全量移植 SwiftUI——UIKit UI 层完全移除
- db3d601 fix: 原料确认按钮字符串插值拆分（嵌套插值解析失败）
- 96866fa fix: SwiftUI 首轮编译错清一批——PhotosUI 导入/重复 stopVoice/scrollDismisses 模式/Color 命名/stripRecords 改名/features 作用域/smoke 状态可见性/onMove 索引(待验)
- ac55eca fix: List.onMove 参数类型（IndexSet, Int）
- 56f60c3 fix: SwiftUI 编译错二批——双 Bindable/features 作用域/三元组解构/indices ForEach/UIColor Color 桥
- 4e52b27 fix: 三批编译错——tap 命中名/BASE_URL/Notification.Name 扩展回归/UIColor 桥/days Bindable
- 6cede01 fix: AppModel 单例注入（SmokeTour 驱动 .shared 与 UI 双实例导致历史加载超时）
- 106dd7f fix(smoke): 每日记录超时——nav 注册去重+days loadIfNeeded 兜底+fixture 请求日志
- ee84b48 test: uiRegression 加 MARK 步骤标记定位超时点
- 5faef02 test: mark 改走 stdout（lines 不在 uiRegression 作用域）
- 3fe50ce test: shot ack 超时转储目录现场
- f213b25 test: 搜索等待轮询加状态快照
- cf489e7 fix: onSearchChange 写入 search（VM 自包含，修复自测搜索超时）

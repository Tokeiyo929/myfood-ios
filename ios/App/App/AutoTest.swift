import UIKit

enum AutoTest {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("-autoTest")
    #else
    static let enabled = false
    #endif
    private static var started = false

    @MainActor
    static func start() {
        guard enabled, !started else { return }
        started = true
        #if DEBUG
        Task {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("autotest")
            var lines: [String] = []
            var failures = 0
            func check(_ ok: Bool, _ name: String) {
                lines.append("\(ok ? "PASS" : "FAIL") \(name)")
                if !ok { failures += 1 }
            }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await CoreRegression.run(report: check)
                try await uiRegression(check: check)
                check(DetailViewModel.parseWorth("yes") == "yes", "worth yes")
                check(DetailViewModel.parseWorth(false) == "no", "worth Bool")
                check(DetailViewModel.parseWorth(NSNull()) == "", "worth null")
                let params = FoodMapGeometry.projectParams(vw: 400, vh: 400, minLon: 73, maxLon: 135, minLat: 18, maxLat: 53)
                let point = FoodMapGeometry.projectPoint(CGPoint(x: 73, y: 53), params: params)
                check(abs(Double(point.x) - params.offsetX) < 0.001 && abs(Double(point.y) - params.offsetY) < 0.001, "地图投影起点")
                let ratio = (62 * params.cosLat * params.k) / (35 * params.k)
                check(abs(ratio - 62 * cos(35.5 * .pi / 180) / 35) < 0.001, "地图投影cos校正")
                check(abs(params.offsetY - (400.0 - 35 * params.k) / 2) < 0.001 && params.offsetY >= 0, "地图投影垂直居中不留大片空白")
                // 轨迹纠偏（eviltransform 已知向量）+ 境外直通
                let shanghai = GCJConverter.wgs84ToGcj02(lat: 31.1774276, lng: 121.5272106)
                check(abs(shanghai.lat - 31.17530398364597) < 1e-4 && abs(shanghai.lng - 121.5315426) < 1e-4, "WGS84→GCJ02 符合 eviltransform 已知向量")
                let oversea = GCJConverter.wgs84ToGcj02(lat: 35.68, lng: 139.76)
                check(oversea.lat == 35.68 && oversea.lng == 139.76, "境外坐标不纠偏")
            } catch { check(false, "自测异常：\(error)") }
            lines.append(failures == 0 ? "RESULT: ALL PASS" : "RESULT: FAIL")
            do {
                try lines.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                try (failures == 0 ? "PASS" : "FAIL").write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch { print("FAIL 无法写入测试结果：\(error)"); exit(1) }
            exit(failures == 0 ? 0 : 1)
        }
        #endif
    }

    #if DEBUG
    @MainActor
    private static func uiRegression(check: (Bool, String) -> Void) async throws {
        TestFixture.install()
        var oldRequestStarted = false
        FixtureProtocol.responseDelay = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "search" }?.value
            if request.url?.path == "/api/foods", query == nil {
                Task { @MainActor in oldRequestStarted = true }
                return 1
            }
            return 0
        }
        // SwiftUI 迁移后 UI 回归走 ViewModel：慢旧搜索不阻挡、不覆盖最新搜索
        func mark(_ m: String) { print("MARK \(m)") } // 进 autotest-console.txt
        let app = AppModel.shared
        app.history.needsRefresh = false
        OfflineStore.wipeAll()
        mark("启动慢请求前")
        Task { await app.history.loadRecords(reset: true) }
        try await waitUntil { oldRequestStarted }
        mark("慢请求已开始")
        app.history.onSearchChange("测试记录 80")
        var lastState = ""
        try await waitUntil {
            let state = "loaded=\(app.history.loaded) count=\(app.history.recordIDs.count) loading=\(app.history.loading) search=\(app.history.search)"
            if state != lastState { print("MARK poll \(state)"); lastState = state }
            return app.history.loaded && app.history.recordIDs == [80]
        }
        check(app.history.recordIDs == [80] && !app.history.loading, "慢旧搜索不阻挡、不覆盖最新搜索")
        mark("搜索断言后")
        // 图片加载：无图路径返回 nil
        let img = await RemoteImageModel.shared.load(nil)
        check(img == nil, "无图路径不产出图片")
        mark("图片断言后")
        // 详情 VM：填充与表单往返
        app.detail.open(recordId: 80)
        OfflineStore.flushIO()
        await app.detail.loadAll()
        check(app.detail.loaded && app.detail.name == "测试记录 80", "详情按 id 加载记录")
        check(DetailViewModel.prevRecordLabel(["2026-11-01", "2026-11-03"]) == "上次记录：2026-11-01", "上次记录标签")
        mark("详情断言后")
        try await modelRegression(check: check)
        TestFixture.install()
    }

    @MainActor
    private static func modelRegression(check: (Bool, String) -> Void) async throws {
        TestFixture.install()
        OfflineStore.wipeAll()
        _ = try await API.updateFoodDetails(80, fields: ["comment": ["A", "B", "C"]])
        let detail = DetailViewModel()
        detail.open(recordId: 80)
        await detail.loadAll()
        check(detail.comments == ["A", "B", "C"], "详情加载评论与草稿一致")
        detail.editComment(1)
        detail.deleteComment(0)
        check(detail.editingCommentIndex == 0, "删除前一条评论后编辑索引同步")
        detail.commentInput = "B编辑"
        detail.saveDetail()
        try await waitUntil { !detail.saving }
        var saved = try await API.getFoodById(80)
        check(saved["comment"] as? [String] == ["B编辑", "C"], "编辑评论保存覆盖原条目")
        detail.commentInput = "追加"
        detail.saveDetail()
        try await waitUntil { !detail.saving }
        saved = try await API.getFoodById(80)
        check(saved["comment"] as? [String] == ["B编辑", "C", "追加"], "连续保存不恢复旧草稿")
        detail.editComment(0)
        detail.deleteComment(0)
        check(detail.editingCommentIndex == nil && detail.commentInput.isEmpty, "删除正在编辑的评论清空输入态")

        let image = await RemoteImageModel.shared.load(API.imageUrl("myfood/regression.png"))
        check(image != nil, "图片通过 fixture 会话加载和解码")
        let ocr = OCRViewModel(image: UIImage())
        ocr.chars = ["美", "食", "日", "记"]
        ocr.touchStarted(0)
        ocr.touchMoved(3)
        ocr.touchEnded()
        check(ocr.builtText == "美食日记", "OCR 跨格拖动连续选字")
        ocr.touchStarted(1)
        ocr.touchMoved(2)
        ocr.touchEnded()
        check(ocr.builtText == "美记", "OCR 从已选字起拖连续取消")

        let geometry = FoodMapViewModel()
        geometry.magnify(1.1)
        geometry.magnify(1.2)
        check(abs(geometry.zoom - 1.2) < 0.001, "捏合倍率相对手势起点，不逐帧累乘")
        geometry.endMagnify()
        geometry.magnify(2)
        check(abs(geometry.zoom - 2.4) < 0.001, "下次捏合沿用上次结束倍率")
        let rings = [[CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)],
                     [CGPoint(x: 3, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 1)]]
        let paths = geometry.renderedPaths(size: CGSize(width: 400, height: 400), features: [.init(name: "岛", rings: rings)])
        var starts = 0
        paths.first?.path.forEach { if case .move = $0 { starts += 1 } }
        check(starts == 2, "多岛地图每个环独立起笔，不连接离岛")

        var local = saved
        local["id"] = -1
        local["client_key"] = "local-detail"
        OfflineStore.upsertRecord(local)
        OfflineStore.enqueue(.create(record: local, clientKey: "local-detail", localId: -1, localImage: nil))
        detail.open(recordId: -1)
        let before = TestFixture.requests.count
        await detail.loadAll()
        check(detail.loaded && detail.recordId == -1 && TestFixture.requests.count == before, "本地新档不请求负数服务端 ID")
        detail.deleteCurrent()
        check(OfflineStore.record(id: -1) == nil && OfflineStore.pendingCount() == 0, "本地新档直接撤销创建并删除")

        let localQuote: [String: Any] = ["id": -1, "text": "离线摘抄", "client_key": "local-quote"]
        OfflineStore.upsertQuote(localQuote)
        OfflineStore.enqueue(.quoteCreate(record: localQuote, clientKey: "local-quote", localId: -1))
        let quotes = QuotesViewModel()
        quotes.quotes = [localQuote]
        quotes.delete(localQuote)
        check(OfflineStore.quote(id: -1) == nil && OfflineStore.pendingCount() == 0, "本地摘抄直接撤销创建并删除")

        if let image {
            FixtureProtocol.handler = { request in
                let response = try TestFixture.respond(request)
                if request.url?.path == "/api/foods", request.httpMethod == "POST" {
                    throw URLError(.networkConnectionLost)
                }
                return response
            }
            let history = HistoryViewModel()
            history.quickAdd(image: image)
            try await waitUntil(timeout: 20) { history.smokeAddState != "running" }
            let pending = OfflineStore.pendingMutations().first
            check(history.smokeAddState == "offline-saved"
                  && pending?.clientKey == (TestFixture.foods.last?["client_key"] as? String),
                  "建档响应丢失后离线补传保留原 client_key")
            FixtureProtocol.handler = TestFixture.respond
            try await SyncEngine.drain()
            check(TestFixture.foods.count == 81 && OfflineStore.pendingCount() == 0, "补传幂等创建不生成重复记录")
        }

        // 5xx：服务端故障与断网同策略——读回落缓存、写入队待重试（手动同步仍原样报告）
        FixtureProtocol.handler = { _ in (500, ["error": "服务端拒绝"]) }
        let settings = SettingsViewModel()
        await settings.runManualSync()
        check(settings.syncStatus == "同步失败：服务端拒绝" && !settings.syncing, "手动同步失败保留错误状态")
        let history = HistoryViewModel()
        await history.loadRecords(reset: true)
        check(!history.records.isEmpty && history.toast == "离线数据（可能不是最新）", "5xx 读取回落本地缓存")
        let map = FoodMapViewModel()
        map.allFoods = [["id": 80, "category_rank": ["c": 2]]]
        try await map.applyRankOrder(list: [["id": 80]], cat: "c")
        check(OfflineStore.pendingCount() == 1, "排名 5xx 入队待重试，不报错误")
        FixtureProtocol.handler = TestFixture.respond
        try await SyncEngine.drain()
        check(OfflineStore.pendingCount() == 0, "排名离线队列恢复联网后排空")
        // 4xx：业务错误必须原样报告，不得伪装成离线成功
        FixtureProtocol.handler = { _ in (400, ["error": "参数有误"]) }
        let history2 = HistoryViewModel()
        await history2.loadRecords(reset: true)
        check(history2.records.isEmpty && history2.toast == "参数有误", "业务失败不伪装为历史离线成功")
        let map2 = FoodMapViewModel()
        map2.allFoods = [["id": 80, "category_rank": ["c": 2]]]
        do {
            try await map2.applyRankOrder(list: [["id": 80]], cat: "c")
            check(false, "排名业务失败必须报告")
        } catch {
            check(OfflineStore.pendingCount() == 0, "排名业务失败不进入离线队列")
        }
        FixtureProtocol.handler = TestFixture.respond
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw APIError(message: "UI回归等待超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    #endif
}

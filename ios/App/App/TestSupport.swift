#if DEBUG
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 所有测试请求由 URLProtocol 截获；未实现的端点报错，不回退正式服务。
final class FixtureProtocol: URLProtocol {
    static var handler: (URLRequest) throws -> (Int, Any) = { _ in throw APIError(message: "未配置测试响应") }
    static var responseDelay: (URLRequest) -> TimeInterval = { _ in 0 }
    private var delivery: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, object) = try Self.handler(request)
            let data = try (object as? Data) ?? JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            let deliver = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            delivery = deliver
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.responseDelay(request), execute: deliver)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { delivery?.cancel(); delivery = nil }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return URLSession(configuration: config)
    }
}

enum TestFixture {
    private static let lock = NSLock()
    static let config: [String: Any] = [
        "flavor_scale": ["min_level": 0, "default_level": 50, "max_level": 100,
                         "low_threshold": 25, "mid_threshold": 50, "high_threshold": 75],
        "flavors": ["酸", "甜", "苦", "辣", "咸"],
        "preferences": [
            "excellent": ["value": "推荐吃", "label": "推荐吃", "level": 100, "face": "😄"],
            "good": ["value": "偏好吃", "label": "偏好吃", "level": 50, "face": "🙂"],
            "bad": ["value": "偏难吃", "label": "偏难吃", "level": 0, "face": "😞"],
        ],
        "pagination": ["page_size": 10, "max_page_size": 50],
        "image": ["max_dimension": 640, "quality": 0.5] as [String: Any],
    ]
    static var foods: [[String: Any]] = []
    static var requests: [URLRequest] = []

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        // 拟真异构数据：长名/未命名/无图/长评论/多原料/混合偏好，让视觉测试能暴露真实数据下的布局问题
        foods = (1...80).map { id in
            let longName = id % 7 == 0
            let unnamed = id % 11 == 0
            let noImage = id % 5 == 0
            let richComment = id % 4 == 0
            let manyIngredients = id % 3 == 0
            let pref: String
            if id % 9 == 0 { pref = "推荐吃" } else if id % 9 == 5 { pref = "偏难吃" } else { pref = "偏好吃" }
            let cat = ["北京烤鸭", "四川火锅", "广东早茶", "新疆大盘鸡", "苏式面点"][id % 5]
            let name = unnamed ? "" : "测试记录 \(id)" + (longName ? "·进口黑巧克力夹心威化饼干超长名称家庭分享装" : "")
            let comments: [String] = richComment
                ? ["这家店排队半小时也值，奶油入口即化，甜度刚好不齁，下次带朋友一起来。", "包装很精致，送人也有面子，保质期新鲜。", "第二次回购了，孩子特别爱吃。"]
                : ["UTF-8 中文 🍰"]
            let ingredients: [[String: Any]] = manyIngredients
                ? [["name": "奶油", "amount": 20], ["name": "面粉", "amount": 35], ["name": "鸡蛋", "amount": 15], ["name": "白砂糖", "amount": 12], ["name": "可可粉", "amount": 8], ["name": "乳酪", "amount": 6], ["name": "海盐", "amount": 1]]
                : [["name": "奶油", "amount": 20]]
            return ["id": id, "name": name, "brand_name": id % 6 == 0 ? "" : "测试品牌",
                    "price": id % 8 == 0 ? NSNull() : ([12 + id % 40, id % 10 == 0 ? 9.9 : NSNull()] as [Any]),
                    "categories": [cat], "category_rank": [cat: id],
                    "ingredients": ingredients, "flavors": [["name": "甜", "level": 75]],
                    "preference": pref, "comment": comments,
                    "worth_it": id % 2 == 0 ? "yes" : (id % 3 == 0 ? "no" : ""),
                    "image_path": noImage ? "" : "myfood/fixture-\(id).jpg",
                    "image_metadata": ["taken_at": "2026:11:03 12:00:00"], "modify_at": ["2026-11-03"]] as [String: Any]
        }
        requests = []
        FixtureProtocol.responseDelay = { _ in 0 }
        FixtureProtocol.handler = respond
        API.session = FixtureProtocol.session()
        AppConfig.shared = nil
    }

    private static func respondQuotes(request: URLRequest, url: URL, method: String) throws -> (Int, Any) {
        if url.path == "/api/quotes" && method == "GET" {
            return (200, ["items": [
                ["id": 501, "text": "山川是不卷收的画卷，行走其间，人便成了笔。", "note": "", "day": "2026-11-06"],
                ["id": 502, "text": "把日子过成诗，一半烟火，一半清欢。凡事不必太执着，尽人事，安天命。人生的幸福，一半要争，一半要随。争，不是与他人争，而是与困苦抗争；随，不是随波逐流，而是知止而后安。", "note": "", "day": "2026-11-05"],
                ["id": 503, "text": "唯有美食与爱不可辜负。", "note": "", "day": "2026-11-01"],
            ], "total": 3])
        }
        if url.path == "/api/quotes" && method == "POST" { return (201, ["id": 501]) }
        if url.path.hasPrefix("/api/quotes/") && method == "DELETE" { return (200, ["id": 5]) }
        throw APIError(message: "测试端点未实现：\(method) \(url.path)")
    }

    static func respond(_ request: URLRequest) throws -> (Int, Any) {
        lock.lock()
        defer { lock.unlock() }
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        print("[fixture] \(method) \(url.path)") // 请求追踪（进 smoke-console.txt）
        if url.path.hasPrefix("/myfood/"), method == "GET" {
            return (200, Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAIklEQVR4nGPUz/ZnIAUwkaSaYVQDcYCJSHVwMKqBGECyBgD7zAEJ8UHNGgAAAABJRU5ErkJggg==")!)
        }
        // 摘抄页在自测启动时自动加载，不计入请求计数断言
        if url.path.hasPrefix("/api/quotes") {
            return try respondQuotes(request: request, url: url, method: method)
        }
        requests.append(request)
        if url.path == "/api/config" { return (200, config) }
        if url.path == "/api/categories" {
            return (200, ["items": [["name": "北京烤鸭", "parentcategories": "北京市"],
                                     ["name": "四川火锅", "parentcategories": "四川省"],
                                     ["name": "广东早茶", "parentcategories": "广东省"],
                                     ["name": "新疆大盘鸡", "parentcategories": "新疆维吾尔自治区"],
                                     ["name": "苏式面点", "parentcategories": "江苏省"]]])
        }
        if url.path == "/api/tracks/days" {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return (200, ["days": [["day": f.string(from: Date()), "points": 160]]])
        }
        if url.path == "/api/tracks" && method == "GET" {
            // 确定性的上海漫步路径：冒烟截图能看到完整折线（并真实走过 GCJ-02 纠偏渲染）
            var pts: [[String: Any]] = []
            for i in 0..<160 {
                let t = Double(i) * 0.09
                pts.append(["lat": 31.2304 + 0.0035 * sin(t),
                            "lng": 121.4737 + 0.0045 * (cos(t) * 0.8 + 0.2),
                            "acc": 8.0,
                            "ts": 1_799_000_000.0 + Double(i) * 30_000])
            }
            return (200, ["points": pts])
        }
        // multipart 上传不做 JSON 解析，直接返回固定路径
        if url.path == "/api/upload", method == "POST" { return (200, ["path": "myfood/smoke-test.jpg", "metadata": [:]]) }
        if url.path == "/api/foods", method == "GET" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let page = Int(query.first { $0.name == "page" }!.value!)!
            let limit = min(50, Int(query.first { $0.name == "limit" }!.value!)!)
            let search = query.first { $0.name == "search" }?.value ?? ""
            let matches = foods.filter { search.isEmpty || ($0["name"] as! String).contains(search) }
                .sorted { a, b in // 镜像服务端：最后修改日期倒序，id 兜底
                    let ma = (a["modify_at"] as? [String])?.last ?? ""
                    let mb = (b["modify_at"] as? [String])?.last ?? ""
                    if ma != mb { return ma > mb }
                    return (a["id"] as? Int ?? 0) > (b["id"] as? Int ?? 0)
                }
            return (200, ["items": Array(matches.dropFirst((page - 1) * limit).prefix(limit)), "total": matches.count])
        }
        var body: [String: Any] = [:]
        if let data = request.httpBody { body = try JSONSerialization.jsonObject(with: data) as! [String: Any] }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        if url.path == "/api/foods", method == "POST" {
            if let key = body["client_key"] as? String, !key.isEmpty,
               let existing = foods.first(where: { $0["client_key"] as? String == key }) {
                return (200, ["id": existing["id"] as! Int])
            }
            let id = (foods.compactMap { $0["id"] as? Int }.max() ?? 0) + 1
            body["id"] = id
            // 镜像服务端：INSERT 时写入当天 modify_at，新记录排在列表最前
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            body["modify_at"] = [fmt.string(from: Date())]
            foods.append(body)
            return (200, ["id": id])
        }
        if url.path.hasPrefix("/api/foods/"), let id = Int(url.lastPathComponent),
           let index = foods.firstIndex(where: { $0["id"] as? Int == id }) {
            switch method {
            case "GET": return (200, foods[index])
            case "PATCH":
                for (key, value) in body["fields"] as? [String: Any] ?? body {
                    if key == "worth_it" { foods[index][key] = (value as? Bool).map { $0 ? "yes" : "no" } ?? "" }
                    else { foods[index][key] = value }
                }
                return (200, ["ok": true])
            case "DELETE": foods.remove(at: index); return (200, ["ok": true])
            default: break
            }
        }
        throw APIError(message: "测试端点未实现：\(method) \(url.path)")
    }
}

enum CoreRegression {
    @MainActor
    static func run(report: (Bool, String) -> Void) async throws {
        let config = try AppConfig(raw: TestFixture.config)
        report(config.flavorScale["default"] == 50 && config.defaultPreference == "偏好吃", "配置使用服务端刻度和默认偏好")
        for key in ["flavor_scale", "preferences", "pagination", "image"] {
            var invalid = TestFixture.config
            invalid.removeValue(forKey: key)
            do { _ = try AppConfig(raw: invalid); report(false, "缺少 \(key) 必须失败") }
            catch { report(true, "缺少 \(key) 被拒绝") }
        }
        var invalid = TestFixture.config
        var scale = invalid["flavor_scale"] as! [String: Int]
        scale.removeValue(forKey: "default_level")
        invalid["flavor_scale"] = scale
        do { _ = try AppConfig(raw: invalid); report(false, "缺少刻度不应使用默认值") }
        catch { report(true, "缺少内部刻度被拒绝") }
        invalid = TestFixture.config
        invalid["image"] = ["max_dimension": 320, "quality": 80] as [String: Any]
        do { _ = try AppConfig(raw: invalid); report(false, "百分比质量不应静默兼容") }
        catch { report(true, "非法图片质量被拒绝") }
        var draft = CommentDraft(comments: ["A", "B"], editingIndex: 1)
        draft.remove(at: 0)
        report(try draft.applying("B编辑") == ["B编辑"], "编辑B、删除A后保存不越界")
        report(draft.comments == ["B"], "未保存草稿不修改原评论")
        draft.remove(at: 0)
        report(draft.editingIndex == nil, "删除正在编辑的评论清除编辑态")
        report(try draft.applying("新增") == ["新增"], "空列表追加评论")
        draft = CommentDraft(comments: ["A", "B", "C"], editingIndex: 0)
        draft.remove(at: 2)
        let removedComment = try draft.applying("")
        report(draft.editingIndex == 0 && removedComment == ["B"], "删除后面的评论保留编辑，空文本删除当前评论")

        var fail = true
        var sent: [Int] = []
        var calls = 0
        let queue = TrackUploadQueue { points in
            calls += 1
            await Task.yield()
            if fail { throw URLError(.notConnectedToInternet) }
            sent += points.map { $0["id"] as! Int }
        }
        queue.append(["id": 1])
        do { try await queue.flush(); report(false, "断网上传必须失败") } catch { report(true, "断网上传报告失败") }
        report(queue.pending.count == 1, "断网保留全部待上传点")
        fail = false
        queue.append(["id": 2])
        async let first: Void = queue.flush()
        async let second: Void = queue.flush()
        try await first
        try await second
        report(sent == [1, 2] && queue.pending.isEmpty && calls == 2, "并发flush只发送一次、恢复后保序排空")

        let original: [[String: Any]] = [["id": 1, "category_rank": ["c": 1]], ["id": 2, "category_rank": ["c": 2]]]
        let swapped = Array(original.reversed())
        let changes = RankOrder.changes(swapped, current: original, category: "c")
        var current = original
        for change in changes { current[current.firstIndex { $0["id"] as? Int == change.id }!]["category_rank"] = change.rank }
        report(changes.count == 2 && RankOrder.changes(original, current: current, category: "c").count == 2, "排名交换再换回，两次都有保存变更")
        report(RankOrder.changes(swapped, current: current, category: "c").isEmpty, "已保存排名不重复提交")

        TestFixture.install()
        async let config1 = AppConfig.load()
        async let config2 = AppConfig.load()
        let loaded1 = try await config1
        let loaded2 = try await config2
        report(loaded1 === loaded2 && TestFixture.requests.count == 1, "并发配置请求合并")
        TestFixture.install()
        let all = try await API.getAllFoods(limit: config.maxPageSize)
        report(all.count == 80 && TestFixture.requests.count == 2, "80条记录、服务端上限50完整分页")
        let query = "蛋糕&today=1+?#中文"
        _ = try await API.getFoods(page: 1, limit: 10, search: query)
        let queryItems = URLComponents(url: TestFixture.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        report(queryItems.first { $0.name == "search" }?.value == query && queryItems.count == 3
               && TestFixture.requests.last!.url!.absoluteString.contains("%2B"), "搜索特殊字符不注入查询参数，保留加号")

        for object in [Data("not json".utf8) as Any, ["items": []] as Any, ["items": "bad", "total": 1] as Any] {
            FixtureProtocol.handler = { _ in (200, object) }
            do { _ = try await API.getFoods(page: 1, limit: 10); report(false, "坏响应必须失败") }
            catch { report(true, "坏JSON或缺列表字段被拒绝") }
        }
        FixtureProtocol.handler = { _ in (500, ["error": "删除失败"]) }
        do { _ = try await API.deleteFood(1); report(false, "删除失败不能返回成功") }
        catch { report(error.localizedDescription == "删除失败", "HTTP删除失败保留具体错误") }
        FixtureProtocol.handler = { _ in (200, ["items": [], "total": 80]) }
        do { _ = try await API.getAllFoods(limit: 50); report(false, "空分页不应无限请求") }
        catch { report(true, "不完整分页报错") }
        AppConfig.shared = nil
        do { _ = try await AppConfig.load(); report(false, "坏配置不应缓存") }
        catch { report(true, "坏配置报告失败") }
        FixtureProtocol.handler = TestFixture.respond
        _ = try await AppConfig.load()
        report(AppConfig.shared != nil, "配置失败后可重试")
        TestFixture.install()
        let created = try await API.submitFood(["name": "中文🍰", "comment": ["奶油足"], "preference": config.defaultPreference])
        let id = created["id"] as! Int
        _ = try await API.updateFoodDetails(id, fields: ["comment": ["修改后的中文🍰"], "worth_it": false])
        let food = try await API.getFoodById(id)
        report(food["comment"] as? [String] == ["修改后的中文🍰"] && food["worth_it"] as? String == "no", "JSON中文与worth读写往返")
        _ = try await API.deleteFood(id)
        report(TestFixture.foods.count == 80, "隔离测试记录清理完成")

        // —— 离线能力 ——
        OfflineStore.wipeAll()
        report(isNetworkError(URLError(.notConnectedToInternet)), "断网错误归类为可离线")
        report(!isNetworkError(APIError(message: "服务器配置无效")), "业务错误不视为可离线")
        // 轨迹纠偏：eviltransform 已知向量（上海）+ 境外直通
        let shanghai = GCJConverter.wgs84ToGcj02(lat: 31.1774276, lng: 121.5272106)
        report(abs(shanghai.lat - 31.17530398364597) < 1e-4 && abs(shanghai.lng - 121.5315426) < 1e-4, "WGS84→GCJ02 符合 eviltransform 已知向量")
        let oversea = GCJConverter.wgs84ToGcj02(lat: 35.68, lng: 139.76) // 东京：境外直通不纠偏
        report(oversea.lat == 35.68 && oversea.lng == 139.76, "境外坐标不纠偏")
        let older = ["id": 7, "name": "旧记录", "modify_at": ["2026-11-01"]] as [String: Any]
        let newer = ["id": 9, "name": "新记录", "modify_at": ["2026-11-03"]] as [String: Any]
        let localNew = ["id": -1, "name": "离线新档", "modify_at": [OfflineStore.todayString()]] as [String: Any]
        OfflineStore.mergeRecords([older, newer, localNew])
        report(OfflineStore.cachedRecords().map { $0["id"] as! Int } == [-1, 9, 7], "缓存排序：本地新档置顶再按修改日期倒序")
        report(OfflineStore.searchRecords("离线").map { $0["id"] as! Int } == [-1], "本地搜索命中名称")
        report(OfflineStore.record(id: 7)?["name"] as? String == "旧记录", "按 id 读缓存")
        OfflineStore.removeRecord(id: 7)
        report(OfflineStore.record(id: 7) == nil, "删除缓存记录")
        OfflineStore.enqueue(.create(record: ["name": "x", "client_key": "k1"], clientKey: "k1", localId: -1, localImage: nil))
        OfflineStore.enqueue(.patchLocal(clientKey: "k1", fields: ["name": "y"]))
        OfflineStore.resolvePending(clientKey: "k1", serverId: 42)
        let resolved = OfflineStore.pendingMutations()
        report(resolved.count == 2 && resolved[1].serverId == 42 && resolved[1].clientKey == nil, "create 成功后本地 patch 改写为服务端 id")
        OfflineStore.cancelPendingCreate(clientKey: "k2") // 无关 key 无副作用
        report(OfflineStore.pendingMutations().count == 2, "撤销无关 create 无副作用")
        OfflineStore.cancelPendingCreate(clientKey: "k1") // 已改写的 patch 归属服务端记录，保留
        report(OfflineStore.pendingMutations().count == 1 && OfflineStore.pendingMutations()[0].serverId == 42, "撤销本地 create 只移除 create 本体")
        // 本地记录未同步即被删：create 与其后续 patch 一并撤销
        OfflineStore.enqueue(.create(record: ["name": "z", "client_key": "k3"], clientKey: "k3", localId: -2, localImage: nil))
        OfflineStore.enqueue(.patchLocal(clientKey: "k3", fields: ["name": "z2"]))
        OfflineStore.cancelPendingCreate(clientKey: "k3")
        // 队列里仅剩此前已改写为服务端 id 的 patch@42；k3 的 create 与 patch 均被连带撤销
        report(OfflineStore.pendingMutations().count == 1 && OfflineStore.pendingMutations()[0].serverId == 42, "本地记录离线删除连带撤销其 patch")

        // AppConfig 断网兜底：先联网一次落盘缓存，再断网应命中缓存；无缓存必须失败
        AppConfig.shared = nil
        _ = try await AppConfig.load()
        OfflineStore.flushIO() // 配置落盘是后台 write-behind，读缓存前先落完
        AppConfig.shared = nil
        FixtureProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let offlineConfig = try await AppConfig.load()
        report(offlineConfig.flavorScale["default"] == 50, "断网时配置回退磁盘缓存")
        AppConfig.shared = nil
        OfflineStore.wipeAll()
        do { _ = try await AppConfig.load(); report(false, "无缓存断网必须失败") }
        catch { report(isNetworkError(error), "无缓存断网报网络错误") }

        // 轨迹待传点持久化：append 落盘，新实例可恢复
        OfflineStore.wipeAll()
        let trackQueue = TrackUploadQueue(persistent: true)
        trackQueue.append(["lat": 1.0, "lng": 2.0, "ts": 3.0])
        OfflineStore.flushIO() // 待传点写盘是后台 write-behind，新实例读取前先落完
        let revived = TrackUploadQueue(persistent: true)
        report(revived.pending.count == 1 && (revived.pending[0]["lat"] as? Double) == 1.0, "轨迹待传点落盘可恢复")

        // 摘抄离线队列：create 同步后换服务端 id；delete 排空（fixture 先恢复，覆盖此前的断网 handler）
        OfflineStore.wipeAll()
        FixtureProtocol.handler = TestFixture.respond
        OfflineStore.enqueue(.quoteCreate(record: ["text": "山川湖海", "note": "", "client_key": "q1"], clientKey: "q1", localId: -1))
        OfflineStore.upsertQuote(["id": -1, "text": "山川湖海", "note": "", "day": OfflineStore.todayString(), "client_key": "q1"])
        try await SyncEngine.drain()
        report(OfflineStore.quote(id: -1) == nil && OfflineStore.quote(id: 501)?["text"] as? String == "山川湖海", "摘抄离线建档同步后换服务端 id")
        OfflineStore.enqueue(.quoteDelete(serverId: 501))
        try await SyncEngine.drain()
        report(OfflineStore.quote(id: 501) == nil && OfflineStore.pendingMutations().isEmpty, "摘抄删除同步后队列排空")
        report(OfflineStore.cachedQuotes().isEmpty, "摘抄缓存同步后一致")

        report(API.imageUrl("myfood/photo.jpg")?.absoluteString == BASE_URL + "/myfood/photo.jpg"
               && API.imageUrl("/myfood/photo.jpg") == API.imageUrl("myfood/photo.jpg"), "图片相对路径统一解析")
        for response in [[String: Any](), ["id": -1], ["id": "1"]] {
            FixtureProtocol.handler = { _ in (200, response) }
            do { _ = try await API.submitFood([:]); report(false, "坏建档响应必须失败") }
            catch { report(true, "坏建档 ID 在 API 边界拒绝") }
            do { _ = try await API.createQuote(text: "x", note: "", clientKey: "x"); report(false, "坏摘抄响应必须失败") }
            catch { report(true, "坏摘抄 ID 在 API 边界拒绝") }
        }

        // 失败必须保留待传修改和原图；并发同步等待同一次排空完成。
        OfflineStore.wipeAll()
        let imagePath = OfflineStore.saveLocalImage(Data([1, 2, 3]))
        let patch = PendingMutation.patch(serverId: 80, fields: ["image_path": imagePath])
        var legacy = patch.dict
        legacy.removeValue(forKey: "localImage")
        report(PendingMutation.from(dict: legacy)?.localImage == imagePath, "旧换图队列仍恢复待上传原图")
        OfflineStore.enqueue(patch)
        FixtureProtocol.handler = { _ in (503, ["error": "稍后重试"]) }
        do { try await SyncEngine.drain(); report(false, "同步错误必须报告") }
        catch { report(error.localizedDescription == "上传失败", "同步错误传给调用方") }
        report(OfflineStore.pendingCount() == 1 && OfflineStore.localImageData(imagePath) != nil, "HTTP 失败保留队列与原图")
        FixtureProtocol.handler = { request in
            if request.url?.path == "/api/upload" { return (200, ["path": "/myfood/replaced.jpg"]) }
            return try TestFixture.respond(request)
        }
        async let drain1: Void = SyncEngine.drain()
        async let drain2: Void = SyncEngine.drain()
        try await drain1
        try await drain2
        let replaced = try await API.getFoodById(80)
        report(OfflineStore.pendingCount() == 0 && replaced["image_path"] as? String == "/myfood/replaced.jpg"
               && OfflineStore.localImageData(imagePath) == nil, "并发同步完成换图上传后才清理原图")

        // 创建成功却缺 ID 时，不能把本地新档当成同步成功清掉。
        OfflineStore.enqueue(.quoteCreate(record: ["text": "保留"], clientKey: "missing-id", localId: -2))
        FixtureProtocol.handler = { _ in (200, [:]) }
        do { try await SyncEngine.drain(); report(false, "缺 ID 的同步必须失败") }
        catch { report(OfflineStore.pendingCount() == 1, "缺 ID 的同步保留待传创建") }

        // —— git 式同步 Diff：快照/暂存/三方对比/冲突解决 ——
        let diffFoodsBackup = TestFixture.foods
        OfflineStore.wipeAll()
        FixtureProtocol.handler = TestFixture.respond
        let diffFoods = try await API.getAllFoods(limit: 50)
        let diffQuotes = (try await API.getQuotes())["items"] as! [[String: Any]]
        OfflineStore.mergeRecords(diffFoods) // 应用内 records 缓存始终保有上次同步的数据
        SyncDiff.initializeSnapshotIfMissing(foods: diffFoods, quotes: diffQuotes)
        SyncDiff.stashRemote(foods: diffFoods, quotes: diffQuotes)
        report(!SyncDiff.compute().hasDiff, "快照初始化后本地与远端无差异")
        SyncDiff.clearStash()
        report(!SyncDiff.compute().hasDiff, "暂存缺失只代表远端未知，不误报全量删除")
        SyncDiff.stashRemote(foods: diffFoods, quotes: diffQuotes)

        // ↑ 本地待推送：patch 入队即计；远端未动不产生冲突
        OfflineStore.enqueue(.patch(serverId: 5, fields: ["comment": ["本地评论"]]))
        var state = SyncDiff.compute()
        report(state.pendingCount == 1 && state.conflicts.isEmpty, "本地待推送计入 ↑，远端未动不冲突")

        // 本地与远端同改一条 → 冲突并给出字段明细；用远端后队列清空、本地取远端内容
        if let i = TestFixture.foods.firstIndex(where: { $0["id"] as? Int == 5 }) {
            TestFixture.foods[i]["comment"] = ["远端评论"]
        }
        SyncDiff.stashRemote(foods: try await API.getAllFoods(limit: 50), quotes: diffQuotes)
        state = SyncDiff.compute()
        report(state.remoteChangedIds == [5] && state.conflicts.count == 1
               && state.conflicts[0].fields.contains { $0.key == "comment" && $0.remote == "远端评论" },
               "本地与远端同改一条 → 冲突并给出字段明细")
        SyncDiff.resolve(state.conflicts[0], choice: .remote)
        report(OfflineStore.pendingMutations().isEmpty
               && (OfflineStore.record(id: 5)?["comment"] as? [String]) == ["远端评论"],
               "采用远端版本：队列清空且本地记录更新")
        SyncDiff.rebuildSnapshot(foods: try await API.getAllFoods(limit: 50), quotes: diffQuotes)
        SyncDiff.clearStash()
        report(!SyncDiff.compute().hasDiff, "解决冲突并对齐快照后回到无差异")

        // 远端删除：快照有、拉取没有 → ↓；与无关本地改动互不干扰，应用后本地缓存同步删除
        OfflineStore.enqueue(.patch(serverId: 6, fields: ["comment": ["本地新评论"]]))
        TestFixture.foods.removeAll { $0["id"] as? Int == 7 }
        SyncDiff.stashRemote(foods: try await API.getAllFoods(limit: 50), quotes: diffQuotes)
        state = SyncDiff.compute()
        report(state.remoteDeletedIds == [7] && state.conflicts.isEmpty && state.pendingCount == 1,
               "远端删除被检测且不与无关本地改动混淆")
        SyncDiff.applyRemoteChanges()
        report(OfflineStore.record(id: 7) == nil, "远端删除应用到本地缓存")

        // 本地修改 + 远端已删 → 冲突；用本地转为重建（create 换新 client_key，不带图）
        if var rec8 = OfflineStore.record(id: 8) { rec8["comment"] = ["本地保存的评论"]; OfflineStore.upsertRecord(rec8) }
        OfflineStore.enqueue(.patch(serverId: 8, fields: ["comment": ["本地保存的评论"]]))
        TestFixture.foods.removeAll { $0["id"] as? Int == 8 }
        SyncDiff.stashRemote(foods: try await API.getAllFoods(limit: 50), quotes: diffQuotes)
        state = SyncDiff.compute()
        report(state.conflicts.count == 1 && state.conflicts[0].id == 8 && state.conflicts[0].remoteKind == "已删除",
               "本地修改遇远端删除产生冲突")
        SyncDiff.resolve(state.conflicts[0], choice: .local)
        let diffQueue = OfflineStore.pendingMutations()
        report(diffQueue.contains { $0.kind == "create" && $0.localId == 8 }
               && !diffQueue.contains { $0.kind == "patch" && $0.serverId == 8 },
               "用本地版本：远端已删的修改转为重建队列项")
        try await SyncEngine.drain()
        report(OfflineStore.pendingCount() == 0 && OfflineStore.record(id: 8) == nil
               && OfflineStore.record(id: 81)?["comment"] as? [String] == ["本地保存的评论"],
               "重建记录同步后换新服务端 id 且队列排空")
        report(OfflineStore.record(id: 6)?["comment"] as? [String] == ["本地新评论"], "无关本地改动正常推送")

        // 本地删除 + 远端有修改 → 冲突；用远端恢复远端内容并清队列
        if let i = TestFixture.foods.firstIndex(where: { $0["id"] as? Int == 9 }) {
            TestFixture.foods[i]["comment"] = ["远端还在改"]
        }
        OfflineStore.enqueue(.delete(serverId: 9))
        OfflineStore.removeRecord(id: 9) // 镜像详情页：删除即移除本地
        SyncDiff.stashRemote(foods: try await API.getAllFoods(limit: 50), quotes: diffQuotes)
        state = SyncDiff.compute()
        report(state.conflicts.count == 1 && state.conflicts[0].id == 9
               && state.conflicts[0].localKind == "已删除" && state.conflicts[0].remoteKind == "有修改",
               "本地删除遇远端修改产生冲突")
        SyncDiff.resolve(state.conflicts[0], choice: .remote)
        report(OfflineStore.pendingMutations().isEmpty
               && OfflineStore.record(id: 9)?["comment"] as? [String] == ["远端还在改"],
               "采用远端版本：恢复被本地删除的记录")

        // 恢复 fixture 与缓存基线
        TestFixture.foods = diffFoodsBackup
        OfflineStore.wipeAll()
        FixtureProtocol.handler = TestFixture.respond
        AppConfig.shared = nil
        _ = try await AppConfig.load()
    }
}
#endif

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
        "image": ["max_dimension": 1600, "quality": 0.8] as [String: Any],
    ]
    static var foods: [[String: Any]] = []
    static var requests: [URLRequest] = []

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        foods = (1...80).map { id in
            ["id": id, "name": "测试记录 \(id)", "brand_name": "测试品牌", "price": [12, NSNull()],
             "categories": ["北京烤鸭"], "category_rank": ["北京烤鸭": id],
             "ingredients": [["name": "奶油", "amount": 20]], "flavors": [["name": "甜", "level": 75]],
             "preference": "偏好吃", "comment": ["UTF-8 中文 🍰"], "worth_it": "yes",
             "image_path": "", "image_metadata": ["taken_at": "2026:11:03 12:00:00"], "modify_at": ["2026-11-03"]]
        }
        requests = []
        FixtureProtocol.responseDelay = { _ in 0 }
        FixtureProtocol.handler = respond
        API.session = FixtureProtocol.session()
        AppConfig.shared = nil
    }

    static func respond(_ request: URLRequest) throws -> (Int, Any) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        if url.path == "/api/config" { return (200, config) }
        if url.path == "/api/categories" { return (200, ["items": [["name": "北京烤鸭", "parentcategories": "北京市"]]]) }
        if url.path == "/api/tracks/days" { return (200, ["days": []]) }
        if url.path == "/api/tracks" { return (200, method == "GET" ? ["points": []] : ["ok": true]) }
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
            let id = (foods.compactMap { $0["id"] as? Int }.max() ?? 0) + 1
            body["id"] = id
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
    }
}
#endif

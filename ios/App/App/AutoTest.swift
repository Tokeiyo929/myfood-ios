import UIKit

// CI 自测（launch argument "-autoTest"）：
// 1) 纯逻辑断言（worth 解析 / config 偏好解析 / 地图投影 / 手势接管）
// 2) 走 app 真实 API 链路的服务器往返（中文评论 PATCH/GET —— 乱码回归）
// 结果写 tmp/autotest/result.txt（每行 PASS/FAIL），done.txt 收尾后 exit(0)。
// CI 轮询该文件，出现 FAIL 行则 job 失败。
enum AutoTest {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-autoTest")
    private static var started = false

    static func start() {
        guard enabled, !started else { return }
        started = true
        Task { @MainActor in
            await run()
        }
    }

    @MainActor
    private static func run() async {
        removeOld()
        log("== MyFood auto test ==")

        // ---- 纯逻辑 ----
        // 1. worth_it 解析：worker 返回 "yes"/"no" 字符串（历史数据可能是 bool/null）
        eq(DetailViewController.parseWorth("yes"), "yes", "parseWorth yes 字符串")
        eq(DetailViewController.parseWorth("no"), "no", "parseWorth no 字符串")
        eq(DetailViewController.parseWorth(true), "yes", "parseWorth bool")
        eq(DetailViewController.parseWorth(NSNull()), "", "parseWorth null")
        eq(DetailViewController.parseWorth("garbage"), "", "parseWorth 非法值")

        // 2. config 偏好解析：value 是字符串（Int/字符串不匹配曾导致保存 400）
        let cfgRaw: [String: Any] = [
            "flavor_scale": ["min_level": 0, "default_level": 1, "max_level": 5, "low_threshold": 1, "mid_threshold": 3, "high_threshold": 4],
            "flavors": ["甜", "苦", "辣", "咸", "酸"],
            "preferences": [
                "excellent": ["value": "推荐吃", "label": "推荐吃", "level": 100, "face": "😄"],
                "good": ["value": "偏好吃", "label": "偏好吃", "level": 50, "face": "🙂"],
                "bad": ["value": "偏难吃", "label": "偏难吃", "level": 0, "face": "😞"],
            ],
            "pagination": ["page_size": 10, "max_page_size": 100],
        ]
        let cfg = AppConfig(raw: cfgRaw)
        eqb(cfg != nil, "AppConfig 解析")
        if let c = cfg {
            eq(c.preferences.count, 3, "偏好数量")
            eq(c.preferences.last?.value, "推荐吃", "最高偏好 value 为字符串")
            eq(c.preferences.first?.value, "偏难吃", "最低偏好 value 为字符串")
        }

        // 3. 手势接管判定
        let wheel = FlavorWheelView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let track = PreferenceTrack(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let label = UILabel()
        eqb(DetailViewController.gestureOwnsTouch(wheel), "轮盘接管触摸")
        eqb(DetailViewController.gestureOwnsTouch(track), "偏好滑条接管触摸")
        eqb(!DetailViewController.gestureOwnsTouch(label), "普通视图不接管")
        // 子视图命中也要接管（滑条 thumb/填充层）
        let thumb = UIView()
        track.addSubview(thumb)
        eqb(DetailViewController.gestureOwnsTouch(thumb), "滑条子视图接管")

        // 4. 地图投影：cos 校正后横向比例 ≈ 真实纵横比 * cos(midLat)，且居中
        // 中国 bbox 近似：lon 73~135, lat 18~53
        let pp = FoodMapViewController.projectParams(vw: 400, vh: 400, minLon: 73, maxLon: 135, minLat: 18, maxLat: 53)
        let midLatCos = cos((18.0 + 53.0) / 2 * .pi / 180)
        let drawnW = (135.0 - 73.0) * midLatCos * pp.k
        let drawnH = (53.0 - 18.0) * pp.k
        ratio(drawnW, drawnH, 62.0 * midLatCos, 35.0, 0.001, "投影纵横比=真实*cos(中纬)")
        eq(pp.offsetX > 0 || pp.offsetY > 0, true, "图形在视窗内居中(有偏移)")
        eqb(pp.offsetX + drawnW <= 400.5 && pp.offsetY + drawnH <= 400.5, "图形不超出视窗")
        let p0 = FoodMapViewController.projectPoint(CGPoint(x: 73, y: 53), params: pp) // 左下角
        near(Double(p0.x), pp.offsetX, 0.001, "投影 x 起点=offsetX")
        near(Double(p0.y), pp.offsetY, 0.001, "投影 y 起点=offsetY")

        // ---- 服务器往返（走 app 自己的 API 链路：JSONSerialization + URLSession）----
        await serverRoundtrip()

        log("== done ==")
        finish()
        try? await Task.sleep(nanoseconds: 300_000_000)
        exit(0)
    }

    // 中文/写路径回归：建临时记录（唯一 client_key）→ PATCH 中文评论 → 读回比对 → 删除
    @MainActor
    private static func serverRoundtrip() async {
        let key = "autotest-ios-\(Int(Date().timeIntervalSince1970 * 1000))"
        let cnName = "自测·中文泡芙"
        let cnComment0 = ["奶油挺多的，味道不错！", "UTF-8 往返 🍰 中文"]
        let cnComment1 = cnComment0 + ["追加评论：保存后不应变成乱码????"]
        do {
            // 建记录（对齐 RecordViewController 新增路径：preference 传字符串）
            let rec: [String: Any] = [
                "name": cnName, "brand_name": "", "price": NSNull(), "categories": [],
                "ingredients": [], "flavors": [], "preference": "偏好吃", "comment": cnComment0,
                "image_path": "", "image_metadata": [:], "client_key": key,
            ]
            let created = try await API.submitFood(rec)
            guard let id = created["id"] as? Int else {
                log("FAIL server 建临时记录 未返回 id")
                return
            }
            log("PASS server 建临时记录 id=\(id)")
            defer { Task { _ = try? await API.deleteFood(id) } }

            // GET 读回（乱码回归：POST 中文）
            let g1 = try await API.getFoodById(id)
            eq(g1["name"] as? String, cnName, "server POST 中文名读回")
            eq(g1["comment"] as? [String], cnComment0, "server POST 中文评论读回")
            eq(DetailViewController.parseWorth(g1["worth_it"]), "", "server 默认 worth_it 空")

            // PATCH fields 中文（对齐 DetailViewController.saveDetail 路径）
            _ = try await API.updateFoodDetails(id, fields: ["name": "改名·草莓大福", "comment": cnComment1])
            let g2 = try await API.getFoodById(id)
            eq(g2["name"] as? String, "改名·草莓大福", "server PATCH fields 中文名")
            eq(g2["comment"] as? [String], cnComment1, "server PATCH 中文评论读回(乱码回归)")

            // PATCH 独立 comment 路径（对齐 addComment）
            _ = try await API.addComment(id, comment: ["只改评论一条"])
            let g3 = try await API.getFoodById(id)
            eq(g3["comment"] as? [String], ["只改评论一条"], "server addComment 读回")
        } catch {
            log("FAIL server 往返异常 \(error)")
        }
    }

    // MARK: - 断言与落盘

    private static func eq<T: Equatable>(_ a: T?, _ b: T?, _ name: String) {
        result(a == b, name, "got=\(String(describing: a)) want=\(String(describing: b))")
    }

    private static func neq<T: Equatable>(_ a: T?, _ b: T?, _ name: String) {
        result(a != b, name, "got=\(String(describing: a))")
    }

    private static func eqb(_ a: Bool, _ name: String) { result(a, name, "got=\(a)") }

    private static func near(_ a: Double, _ b: Double, _ eps: Double, _ name: String) {
        result(abs(a - b) <= eps, name, "got=\(a) want=\(b)")
    }

    private static func ratio(_ w1: Double, _ h1: Double, _ w2: Double, _ h2: Double, _ eps: Double, _ name: String) {
        result(abs(w1 / h1 - w2 / h2) <= eps, name, "got=\(w1 / h1) want=\(w2 / h2)")
    }

    private static func result(_ ok: Bool, _ name: String, _ detail: String) {
        log("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : "  \(detail)")")
    }

    private static func removeOld() {
        try? FileManager.default.removeItem(at: dir)
    }

    private static var dir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("autotest")
    }

    private static func log(_ line: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("result.txt")
        if let h = try? String(contentsOf: f, encoding: .utf8) {
            try? (h + line + "\n").write(to: f, atomically: true, encoding: .utf8)
        } else {
            try? (line + "\n").write(to: f, atomically: true, encoding: .utf8)
        }
    }

    private static func finish() {
        try? "done".write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }
}

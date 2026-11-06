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
                check(DetailViewController.parseWorth("yes") == "yes", "worth yes")
                check(DetailViewController.parseWorth(false) == "no", "worth Bool")
                check(DetailViewController.parseWorth(NSNull()) == "", "worth null")
                let scroll = DetailScrollView()
                let wheel = FlavorWheelView()
                let track = PreferenceTrack()
                let child = UIView()
                track.addSubview(child)
                check(!scroll.touchesShouldCancel(in: wheel), "实际scrollView保留轮盘触摸")
                check(!scroll.touchesShouldCancel(in: child), "实际scrollView保留偏好子视图触摸")
                let params = FoodMapViewController.projectParams(vw: 400, vh: 400, minLon: 73, maxLon: 135, minLat: 18, maxLat: 53)
                let point = FoodMapViewController.projectPoint(CGPoint(x: 73, y: 53), params: params)
                check(abs(Double(point.x) - params.offsetX) < 0.001 && abs(Double(point.y) - params.offsetY) < 0.001, "地图投影起点")
                let ratio = (62 * params.cosLat * params.k) / (35 * params.k)
                check(abs(ratio - 62 * cos(35.5 * .pi / 180) / 35) < 0.001, "地图投影cos校正")
                check(params.offsetY == 0, "地图投影顶部对齐不留上方空白")
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
        let history = HistoryViewController()
        history.loadViewIfNeeded()
        history.viewWillAppear(false)
        try await waitUntil { oldRequestStarted }
        history.searchBar(UISearchBar(), textDidChange: "测试记录 80")
        try await waitUntil { history.completedLoads == 2 }
        check(history.recordIDs == [80] && !history.loading, "慢旧搜索不阻挡、不覆盖最新搜索")
        let imageView = UIImageView()
        imageView.tag = 4
        ImageLoader.shared.load(nil, into: imageView)
        check(imageView.tag == 5 && imageView.image != nil, "无图绑定使旧下载token失效并显示占位图")
        TestFixture.install()
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw APIError(message: "UI回归等待超时") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    #endif
}

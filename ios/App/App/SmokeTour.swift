import UIKit

// runner 截图并回写 ack，页面就绪与截图确认均有超时断言。
enum SmokeTour {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("-autoSmoke")
    #else
    static let enabled = false
    #endif
    private static var started = false
    private static let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smoke")

    @MainActor
    static func start() {
        guard enabled, !started else { return }
        started = true
        Task {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await tour()
                try "RESULT: ALL PASS\n".write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                try "PASS".write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
                exit(0)
            } catch {
                try? "FAIL \(error)\n".write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                try? "FAIL".write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
                exit(1)
            }
        }
    }

    @MainActor
    private static func tour() async throws {
        // tab 布局：0 地图 | 1 轨迹 | 2 历史(中心) | 3 设置 | 4 摘抄
        guard let tab = keyTab(), let nav = tab.viewControllers?[2] as? UINavigationController,
              let history = nav.viewControllers.first as? HistoryViewController else { throw APIError(message: "历史页不存在") }
        tab.selectedIndex = 2
        try await waitUntil("历史加载") { history.loaded }
        try await shot("01-history")

        // 详情（二级）+ OCR 面板（三级）：均等加载/识别完成
        history.smokeOpenFirst()
        try await waitUntil("详情加载") { (nav.topViewController as? DetailViewController)?.loaded == true }
        try await shot("02-detail")
        if let detail = nav.topViewController as? DetailViewController {
            detail.smokePresentOcr()
            try await waitUntil("OCR识别") { detail.smokeOcrController?.recognized == true }
            try await shot("03-ocr")
            detail.smokeOcrController?.dismiss(animated: false)
        }
        nav.popToRootViewController(animated: false)

        // 快速建档全流程（上传+定位兜底+提交），新记录应出现在列表最前
        history.smokeQuickAdd()
        try await waitUntil("记录保存") { history.smokeAddState == "saved" }
        try await shot("04-record")

        tab.selectedIndex = 0
        guard let map = (tab.viewControllers?[0] as? UINavigationController)?.topViewController as? FoodMapViewController else {
            throw APIError(message: "美食地图不存在")
        }
        try await waitUntil("地图加载") { map.mapReady }
        try await shot("05-map-china")
        map.smokeSwitchEurope()
        try await shot("06-map-europe")
        map.smokeOpenRank()
        try await waitUntil("排行打开") { map.view.subviews.contains { $0 is RankModalView } }
        try await shot("07-rank")
        map.view.subviews.compactMap { $0 as? RankModalView }.forEach { $0.close() }

        // 轨迹（今天）+ 每日记录（二级）+ 某天轨迹（三级）
        tab.selectedIndex = 1
        guard let trackNav = tab.viewControllers?[1] as? UINavigationController,
              let trackRoot = trackNav.topViewController as? MapViewController else {
            throw APIError(message: "轨迹页不存在")
        }
        try await waitUntil("今日轨迹") { trackRoot.loaded }
        try await shot("08-tracks")
        trackRoot.smokeOpenDays()
        try await waitUntil("每日记录") { (trackNav.topViewController as? TrackDaysViewController)?.loaded == true }
        try await shot("09-track-days")
        (trackNav.topViewController as? TrackDaysViewController)?.smokeOpenFirst()
        try await waitUntil("某天轨迹") { trackNav.topViewController !== trackRoot && (trackNav.topViewController as? MapViewController)?.loaded == true }
        try await shot("10-track-day")
        trackNav.popToRootViewController(animated: false)

        tab.selectedIndex = 3
        guard (tab.selectedViewController as? UINavigationController)?.topViewController is SettingsViewController else {
            throw APIError(message: "设置页不存在")
        }
        try await shot("11-settings")

        // 摘抄页（tab 4）：等数据加载完
        tab.selectedIndex = 4
        guard let quotes = (tab.viewControllers?[4] as? UINavigationController)?.viewControllers.first as? QuotesViewController else {
            throw APIError(message: "摘抄页不存在")
        }
        try await waitUntil("摘抄加载") { quotes.loaded }
        try await shot("12-quotes")
    }

    @MainActor
    private static func waitUntil(_ name: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(40)
        while !condition() {
            guard Date() < deadline else { throw APIError(message: "\(name)超时") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @MainActor
    private static func shot(_ name: String) async throws {
        // 等布局提交后再通知外部截屏。
        await Task.yield()
        try "1".write(to: dir.appendingPathComponent("now-\(name)"), atomically: true, encoding: .utf8)
        try await waitUntil("截图\(name)") { FileManager.default.fileExists(atPath: dir.appendingPathComponent("ack-\(name)").path) }
    }

    @MainActor
    private static func keyTab() -> MainTabBarController? {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            if let tab = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController as? MainTabBarController { return tab }
        }
        return nil
    }
}

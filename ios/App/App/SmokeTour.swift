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
        // tab 布局：0 地图 | 1 轨迹 | 2 历史(中心) | 3 设置 | 4 更多(占位)
        guard let tab = keyTab(), let nav = tab.viewControllers?[2] as? UINavigationController,
              let history = nav.viewControllers.first as? HistoryViewController else { throw APIError(message: "历史页不存在") }
        tab.selectedIndex = 2
        try await waitUntil("历史加载") { history.loaded }
        try await shot("01-history")
        history.smokeOpenFirst()
        try await waitUntil("详情加载") { (nav.topViewController as? DetailViewController)?.loaded == true }
        try await shot("02-detail")
        nav.popToRootViewController(animated: false)

        tab.selectedIndex = 0
        guard let map = (tab.viewControllers?[0] as? UINavigationController)?.topViewController as? FoodMapViewController else {
            throw APIError(message: "美食地图不存在")
        }
        try await waitUntil("地图加载") { map.mapReady }
        try await shot("04-map-china")
        map.smokeSwitchEurope()
        try await shot("05-map-europe")
        map.smokeOpenRank()
        try await waitUntil("排行打开") { map.view.subviews.contains { $0 is RankModalView } }
        try await shot("06-rank")
        map.view.subviews.compactMap { $0 as? RankModalView }.forEach { $0.close() }

        tab.selectedIndex = 1
        let track = (tab.viewControllers?[1] as? UINavigationController)?.topViewController as? MapViewController
        try await waitUntil("轨迹加载") { track?.loaded == true }
        try await shot("07-tracks")
        tab.selectedIndex = 3
        guard (tab.selectedViewController as? UINavigationController)?.topViewController is SettingsViewController else {
            throw APIError(message: "设置页不存在")
        }
        try await shot("08-settings")
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

import UIKit

// CI 冒烟巡访：launch argument "-autoSmoke" 时自动遍历各页并自截 PNG 到 tmp/smoke/，
// runner 端从 app 容器拷走上传。仅用于 CI 验证，不影响正常启动。
enum SmokeTour {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-autoSmoke")

    static func start() {
        guard enabled,
              let tab = keyTab() else { return }
        let nav0 = tab.viewControllers?[0] as? UINavigationController

        // 时间串联：历史 → 详情 → 记录 → 地图(中国/欧洲/排行榜) → 轨迹 → 设置
        at(2.0) { tab.selectedIndex = 0 }                                       // 历史
        at(2.5) {
            snap("01-history")
            (nav0?.topViewController as? HistoryViewController)?.smokeOpenFirst()
        }
        at(3.0) {
            snap("02-detail")
            nav0?.popToRootViewController(animated: false)
        }
        at(1.0) { tab.selectedIndex = 1 }                                       // 记录
        at(2.0) { snap("03-record") }
        at(0.5) { tab.selectedIndex = 2 }                                       // 地图
        at(3.5) {
            snap("04-map-china")
            mapVC()?.smokeSwitchEurope()
        }
        at(2.0) {
            snap("05-map-europe")
            mapVC()?.smokeOpenRank()
        }
        at(2.5) {
            snap("06-rank")
            mapVC()?.view.subviews.compactMap { $0 as? RankModalView }.forEach { $0.close() }
        }
        at(1.0) { tab.selectedIndex = 3 }                                       // 轨迹
        at(2.0) { snap("07-tracks") }
        at(0.5) { tab.selectedIndex = 4 }                                       // 设置
        at(1.5) {
            snap("08-settings")
            finish()
        }
    }

    // MARK: - 私有

    private static func keyTab() -> MainTabBarController? {
        keyWindow()?.rootViewController as? MainTabBarController
    }

    private static func mapVC() -> FoodMapViewController? {
        (keyTab()?.viewControllers?[2] as? UINavigationController)?
            .viewControllers.first as? FoodMapViewController
    }

    // 平铺查找 keyWindow（避开 flatMap 类型推断坑）
    private static func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows where w.isKey { return w }
        }
        return nil
    }

    private static var clock: TimeInterval = 0

    private static func at(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        clock += delay
        DispatchQueue.main.asyncAfter(deadline: .now() + clock, execute: body)
    }

    private static func snap(_ name: String) {
        guard let window = keyWindow(),
            window.bounds.size.width > 0 else { return }
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        let img = renderer.image { ctx in
            window.layer.render(in: ctx.cgContext)
        }
        guard let data = img.pngData() else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smoke")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private static func finish() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smoke")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "done".write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }
}

import UIKit

// CI 冒烟巡访：launch argument "-autoSmoke" 时自动遍历各页。
// 截图由 runner 端 simctl io screenshot 完成（app 内自截会偶发黑屏）：
// 本类切到目标页后写 marker(now-XX)，等 runner 截完回写 ack(ack-XX) 再走下一步。
enum SmokeTour {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-autoSmoke")
    private static var started = false

    // 无条件诊断（viewDidAppear 触发一次，记录实际收到的参数）
    static func debugNote(_ line: String) { log(line) }

    static func start() {
        guard enabled, !started else { return }
        started = true
        log("boot")
        Task { @MainActor in
            await tour()
        }
    }

    // MARK: - 巡访序列：历史 → 详情 → 记录 → 地图(中国/欧洲/排行榜) → 轨迹 → 设置
    @MainActor
    private static func tour() async {
        guard let tab = keyTab() else { log("no key tab"); finish(); return }
        let nav0 = tab.viewControllers?[0] as? UINavigationController

        tab.selectedIndex = 0                                       // 历史
        await pause(8.0)                                            // 等后端数据（首请求慢）
        await shot("01-history")
        (nav0?.topViewController as? HistoryViewController)?.smokeOpenFirst()
        await pause(1.0)
        await shot("02-detail")
        nav0?.popToRootViewController(animated: false)

        tab.selectedIndex = 1                                       // 记录
        await pause(2.0)
        await shot("03-record")

        tab.selectedIndex = 2                                       // 地图
        await pause(8.0)                                            // 等类目/地理数据
        await shot("04-map-china")
        mapVC()?.smokeSwitchEurope()
        await pause(4.0)
        await shot("05-map-europe")
        mapVC()?.smokeOpenRank()
        await pause(2.0)
        await shot("06-rank")
        mapVC()?.view.subviews.compactMap { $0 as? RankModalView }.forEach { $0.close() }

        tab.selectedIndex = 3                                       // 轨迹
        await pause(2.0)
        await shot("07-tracks")

        tab.selectedIndex = 4                                       // 设置
        await pause(1.5)
        await shot("08-settings")
        finish()
        log("exiting")
        try? await Task.sleep(nanoseconds: 500_000_000)
        exit(0) // 仅 -autoSmoke
    }

    // MARK: - 私有

    // 通知 runner 截屏并等 ack（最多 40s，超时放行不卡巡访）
    @MainActor
    private static func shot(_ name: String) async {
        try? FileManager.default.createDirectory(at: smokeDir, withIntermediateDirectories: true)
        try? "1".write(to: smokeDir.appendingPathComponent("now-\(name)"), atomically: true, encoding: .utf8)
        for _ in 0..<80 {
            if (try? String(contentsOf: smokeDir.appendingPathComponent("ack-\(name)"), encoding: .utf8)) != nil {
                log("shot \(name) acked")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("shot \(name) ack TIMEOUT")
    }

    @MainActor
    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static var smokeDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smoke")
    }

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
            for w in ws.windows where w.isKeyWindow { return w }
        }
        return nil
    }

    private static func finish() {
        try? FileManager.default.createDirectory(at: smokeDir, withIntermediateDirectories: true)
        do {
            try "done".write(to: smokeDir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            log("finish ok")
        } catch { log("finish failed: \(error)") }
    }

    // 诊断日志：写进 tmp/smoke/smoke-log.txt，随 CI artifact 上传
    private static func log(_ line: String) {
        try? FileManager.default.createDirectory(at: smokeDir, withIntermediateDirectories: true)
        let f = smokeDir.appendingPathComponent("smoke-log.txt")
        if let h = try? String(contentsOf: f, encoding: .utf8) {
            try? (h + line + "\n").write(to: f, atomically: true, encoding: .utf8)
        } else {
            try? (line + "\n").write(to: f, atomically: true, encoding: .utf8)
        }
    }
}

import UIKit

// runner 截图并回写 ack，页面就绪与截图确认均有超时断言。
// SwiftUI 迁移后巡访改为驱动 AppModel 的页面 ViewModel（12 页：一/二/三级全覆盖）。
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
        let app = AppModel.shared
        // 01 历史
        app.tab = .history
        try await waitUntil("历史加载") { app.history.loaded }
        try await shot("01-history")

        // 02 详情（二级）+ 03 OCR 面板（三级）
        guard let first = app.history.records.first else { throw APIError(message: "历史列表为空") }
        app.detail.open(recordId: first.id)
        app.historyPath = [first.id]
        try await waitUntil("详情加载") { app.detail.loaded }
        try await shot("02-detail")
        app.detail.smokePresentOcr()
        try await waitUntil("OCR识别") { app.detail.ocrVM?.recognized == true }
        try await shot("03-ocr")
        app.detail.closeOcr()
        app.historyPath = []

        // 04 快速建档全流程（上传+定位兜底+提交），新记录应出现在列表最前
        app.history.smokeQuickAdd()
        try await waitUntil("记录保存") { app.history.smokeAddState == "saved" }
        try await shot("04-record")

        // 05 中国地图 / 06 欧洲地图 / 07 排行榜
        app.tab = .map
        try await waitUntil("地图加载") { app.foodMap.mapReady }
        try await shot("05-map-china")
        app.foodMap.smokeSwitchEurope()
        try await shot("06-map-europe")
        app.foodMap.smokeOpenRank()
        try await waitUntil("排行打开") { app.foodMap.rankCategory != nil }
        try await shot("07-rank")
        app.foodMap.rankCategory = nil

        // 08 轨迹（今天）/ 09 每日记录（二级）/ 10 某天轨迹（三级）
        app.tab = .tracks
        try await waitUntil("今日轨迹") { app.tracks.loaded }
        try await shot("08-tracks")
        let today = TrackView.fmtDay(Date())
        app.daysPath = [TrackDestination(day: today)]
        app.days.loadIfNeeded()
        try await waitUntil("每日记录") { app.days.loaded }
        try await shot("09-track-days")
        let dayToOpen = (app.days.days.first?["day"] as? String) ?? today
        app.dayVM.loaded = false
        app.daysPath.append(TrackDestination(day: dayToOpen))
        try await waitUntil("某天轨迹") { app.dayVM.loaded }
        try await shot("10-track-day")
        app.daysPath = []

        // 11 设置
        app.tab = .settings
        try await shot("11-settings")

        // 12 摘抄
        app.tab = .quotes
        try await waitUntil("摘抄加载") { app.quotes.loaded }
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
        do {
            try await waitUntil("截图\(name)") { FileManager.default.fileExists(atPath: dir.appendingPathComponent("ack-\(name)").path) }
        } catch {
            // 现场证据：ack 未出现时转储目录内容与探测结果
            let ackExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("ack-\(name)").path)
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted().joined(separator: ",") ?? "unreadable"
            print("[smoke] ack 超时 \(name) ackExists=\(ackExists) dir=[\(contents)]")
            throw error
        }
    }
}

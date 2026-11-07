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
        let app = AppModel.shared
        app.history.needsRefresh = false
        OfflineStore.wipeAll()
        Task { await app.history.loadRecords(reset: true) }
        try await waitUntil { oldRequestStarted }
        app.history.onSearchChange("测试记录 80")
        try await waitUntil { app.history.loaded && app.history.recordIDs == [80] }
        check(app.history.recordIDs == [80] && !app.history.loading, "慢旧搜索不阻挡、不覆盖最新搜索")
        // 图片加载：无图路径返回 nil
        let img = await RemoteImageModel.shared.load(nil)
        check(img == nil, "无图路径不产出图片")
        // 详情 VM：填充与表单往返
        app.detail.open(recordId: 80)
        OfflineStore.flushIO()
        await app.detail.loadAll()
        check(app.detail.loaded && app.detail.name == "测试记录 80", "详情按 id 加载记录")
        check(DetailViewModel.prevRecordLabel(["2026-11-01", "2026-11-03"]) == "上次记录：2026-11-01", "上次记录标签")
        TestFixture.install()
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw APIError(message: "UI回归等待超时") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    #endif
}

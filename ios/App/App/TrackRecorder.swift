import Foundation
import CoreLocation
import Observation

// 纯原生轨迹记录器：CLLocationManager 后台持续定位，锁屏也记点
@MainActor
@Observable
// manager 在主线程创建，CoreLocation 在对应的主 run loop 派发 delegate 回调。
final class TrackRecorder: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = TrackRecorder()

    private let manager = CLLocationManager()
    private var lastSent: (lat: Double, lng: Double, t: TimeInterval)?
    private let queue = TrackUploadQueue(persistent: true) // 待传点落盘，断网/进程退出不丢
    private var startRequested = false
    private var pointDay = Calendar.current.startOfDay(for: Date())
    private var flushTimer: Timer?
    private(set) var isTracking = false
    private(set) var todayPoints: [(lat: Double, lng: Double)] = []
    private(set) var lastError: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        guard !isTracking else { return }
        startRequested = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: beginTracking()
        default:
            startRequested = false
            lastError = "请在设置中允许定位"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if startRequested { beginTracking() }
        case .denied, .restricted:
            guard startRequested || isTracking else { return }
            startRequested = false
            if isTracking {
                Task {
                    do { try await stop() }
                    catch { lastError = "轨迹上传失败，待上传点已保留" }
                }
            }
            lastError = "未获得定位权限"
        default: break
        }
    }

    private func beginTracking() {
        guard !isTracking else { return }
        startRequested = false
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        isTracking = true
        lastError = nil
        lastSent = nil
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flush() }
        }
    }

    func stop() async throws {
        startRequested = false
        manager.stopUpdatingLocation()
        isTracking = false
        flushTimer?.invalidate()
        flushTimer = nil
        try await queue.flush()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isTracking else { return }
        let day = Calendar.current.startOfDay(for: Date())
        if day != pointDay { todayPoints.removeAll(); pointDay = day }
        for loc in locations {
            guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy < 100 else { continue }
            let lat = loc.coordinate.latitude, lng = loc.coordinate.longitude
            let now = loc.timestamp.timeIntervalSince1970 * 1000
            // 采样对齐成熟方案（GPX 源头 ~13s 中位间隔）：距上点 <15s 或移动 ≤2m 都不记。
            // 此前仅静止去重，移动时全量记录（~1.6万点/天）；节流后同量级且路径渲染不受影响
            if let last = lastSent {
                let dx = (lat - last.lat) * 111320
                let dy = (lng - last.lng) * 111320 * cos(last.lat * .pi / 180)
                let dist = (dx * dx + dy * dy).squareRoot()
                if (now - last.t) < 15000 || dist <= 2 { continue }
            }
            lastSent = (lat, lng, now)
            if Calendar.current.isDateInToday(loc.timestamp) {
                todayPoints.append((lat, lng))
            }
            queue.append(["lat": lat, "lng": lng, "ts": now, "acc": loc.horizontalAccuracy])
        }
        if queue.pending.count >= 10 { Task { await flush() } }
    }

    private func flush() async {
        do { try await queue.flush(); lastError = nil }
        catch { lastError = "轨迹上传失败，待上传点已保留；联网后重试" }
    }

    // 离线查看用：某天尚未上传的点
    func pendingPoints(day: String) -> [[String: Any]] { queue.pendingPoints(day: day) }

    // 离线查看用：全部尚未上传的点
    func allPendingPoints() -> [[String: Any]] { queue.allPendingPoints() }

    // 今天页地图定位用：最后已知位置
    var lastKnownCoordinate: CLLocationCoordinate2D? { manager.location?.coordinate }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { lastError = error.localizedDescription }
}

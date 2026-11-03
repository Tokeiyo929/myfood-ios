import Foundation
import CoreLocation

// 纯原生轨迹记录器：CLLocationManager 后台持续定位，锁屏也记点
@MainActor
final class TrackRecorder: NSObject, CLLocationManagerDelegate {
    static let shared = TrackRecorder()

    private let manager = CLLocationManager()
    private var lastSent: (lat: Double, lng: Double, t: TimeInterval)?
    private let queue = TrackUploadQueue()
    private var startRequested = false
    private var pointDay = Calendar.current.startOfDay(for: Date())
    private var flushTimer: Timer?
    private(set) var isTracking = false
    private(set) var todayPoints: [(lat: Double, lng: Double)] = []
    var onNewPoint: ((Double, Double) -> Void)?
    var onStateChange: (() -> Void)?
    var onError: ((String) -> Void)?

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
            onError?("请在设置中允许定位")
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
                    catch { onError?("轨迹上传失败，待上传点已保留") }
                }
            }
            onError?("未获得定位权限")
        default: break
        }
    }

    private func beginTracking() {
        guard !isTracking else { return }
        startRequested = false
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        // 请求延迟批量定位；系统不保证固定回调间隔。
        manager.startUpdatingLocation()
        manager.allowDeferredLocationUpdates(untilTraveled: 5, timeout: 15)
        isTracking = true
        onStateChange?()
        lastSent = nil
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flush() }
        }
    }

    func stop() async throws {
        startRequested = false
        manager.stopUpdatingLocation()
        isTracking = false
        onStateChange?()
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
            // 去重: 移动>2m 或 距上个点>30s
            if let last = lastSent {
                let dx = (lat - last.lat) * 111320
                let dy = (lng - last.lng) * 111320 * cos(last.lat * .pi / 180)
                let dist = (dx * dx + dy * dy).squareRoot()
                if dist <= 2 && (now - last.t) < 30000 { continue }
            }
            lastSent = (lat, lng, now)
            if Calendar.current.isDateInToday(loc.timestamp) {
                todayPoints.append((lat, lng))
                onNewPoint?(lat, lng)
            }
            queue.append(["lat": lat, "lng": lng, "ts": now, "acc": loc.horizontalAccuracy])
        }
        if queue.pending.count >= 10 { Task { await flush() } }
    }

    private func flush() async {
        do { try await queue.flush() }
        catch { onError?("轨迹上传失败，待上传点已保留；联网后重试") }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { onError?(error.localizedDescription) }
}

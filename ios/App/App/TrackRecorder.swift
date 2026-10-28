import Foundation
import CoreLocation

// 纯原生轨迹记录器：CLLocationManager 后台持续定位，锁屏也记点
final class TrackRecorder: NSObject, CLLocationManagerDelegate {
    static let shared = TrackRecorder()

    private let manager = CLLocationManager()
    private var lastSent: (lat: Double, lng: Double, t: TimeInterval)?
    private var pending: [[String: Any]] = []
    private var flushTimer: Timer?
    private(set) var isTracking = false
    private(set) var todayPoints: [(lat: Double, lng: Double)] = []
    var onNewPoint: ((Double, Double) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        manager.requestAlwaysAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        // 移动5米或最长15秒回调一次（前后台均生效）
        manager.startUpdatingLocation()
        manager.allowDeferredLocationUpdates(untilTraveled: 5, timeout: 15)
        isTracking = true
        lastSent = nil
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.flush(force: false)
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        isTracking = false
        flushTimer?.invalidate()
        flushTimer = nil
        flush(force: true)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
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
            todayPoints.append((lat, lng))
            pending.append(["lat": lat, "lng": lng, "ts": now, "acc": loc.horizontalAccuracy])
            DispatchQueue.main.async { self.onNewPoint?(lat, lng) }
        }
        if pending.count >= 10 { flush(force: false) }
    }

    private func flush(force: Bool) {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        Task {
            do { try await API.postTrackPoints(batch) }
            catch {
                if force { pending.insert(contentsOf: batch, at: 0) } // 最终失败放回，下次再试
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

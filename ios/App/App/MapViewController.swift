import UIKit
import MapKit

// 轨迹 tab：MapKit + 默认自动记录（App 启动即记录，无需手动开关）
class MapViewController: UIViewController, MKMapViewDelegate {
    private var mapView: MKMapView!
    private var statusLabel: UILabel!
    private var infoLabel: UILabel!
    var viewDay: String?
    private(set) var loaded = false

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = viewDay.map { "轨迹 · \($0)" } ?? "轨迹"
        buildUI()
        // 轨迹 tab 根页：右上角进每日记录列表（二级页）；按天进入的历史页不重复加
        if viewDay == nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "每日记录", style: .plain, target: self, action: #selector(openDayList))
            // 定位被拒绝时状态条可点按重新发起（重新拉系统授权）
            statusLabel.isUserInteractionEnabled = true
            statusLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retryTracking)))
        }
    }

    @objc private func openDayList() {
        navigationController?.pushViewController(TrackDaysViewController(), animated: true)
    }

    @objc private func retryTracking() {
        TrackRecorder.shared.start()
        refreshStatus()
    }

    private func buildUI() {
        mapView = MKMapView()
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)

        statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.backgroundColor = UIColor(white: 1, alpha: 0.85)
        statusLabel.layer.cornerRadius = 6
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(statusLabel)

        infoLabel = UILabel()
        infoLabel.font = .systemFont(ofSize: 13)
        infoLabel.textColor = .secondaryLabel
        infoLabel.textAlignment = .center
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            mapView.bottomAnchor.constraint(equalTo: infoLabel.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: mapView.leadingAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: mapView.bottomAnchor, constant: -8),
            infoLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            infoLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        refreshStatus()
        statusLabel.text = "加载中…"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStatus()
        loadTrack()
        guard viewDay == nil else { return }
        TrackRecorder.shared.onNewPoint = { [weak self] lat, lng in
            self?.addPointToLine(lat: lat, lng: lng)
            self?.refreshStatus()
        }
        TrackRecorder.shared.onStateChange = { [weak self] in self?.refreshStatus() }
        TrackRecorder.shared.onError = { [weak self] message in Toast.show(message, self?.view) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard viewDay == nil else { return }
        TrackRecorder.shared.onNewPoint = nil
        TrackRecorder.shared.onStateChange = nil
        TrackRecorder.shared.onError = nil
    }

    // 默认记录无手动开关：记录中显示点数；未记录（如定位被拒）提示点按开启
    private func refreshStatus() {
        guard viewDay == nil else { return }
        if TrackRecorder.shared.isTracking {
            statusLabel.text = "记录中 · \(TrackRecorder.shared.todayPoints.count)点"
        } else {
            statusLabel.text = "未记录 · 点按开启"
        }
    }

    private func loadTrack() {
        let day = viewDay ?? Self.fmtDay(Date())
        statusLabel.text = "加载中…"
        Task {
            do {
                let points = try await API.getTrackPoints(day: day)
                render(points: points)
                loaded = true
            } catch {
                DispatchQueue.main.async { self.statusLabel.text = "轨迹加载失败" }
            }
        }
    }

    private func render(points: [[String: Any]]) {
        mapView.removeOverlays(mapView.overlays)
        guard !points.isEmpty else {
            statusLabel.text = "无轨迹点"
            return
        }
        var coords: [CLLocationCoordinate2D] = []
        for p in points {
            guard let lat = p["lat"] as? Double, let lng = p["lng"] as? Double else { continue }
            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lng))
        }
        if let first = coords.first {
            let r = MKCoordinateRegion(center: first, latitudinalMeters: 800, longitudinalMeters: 800)
            mapView.setRegion(r, animated: false)
        }
        let line = MKPolyline(coordinates: coords, count: coords.count)
        mapView.addOverlay(line)
        statusLabel.text = "\(coords.count)点"
        infoLabel.text = viewDay != nil ? "历史轨迹 · \(viewDay!)" : ""
    }

    private func addPointToLine(lat: Double, lng: Double) {
        // 简单方式：直接在地图上画个小点 + 累积线
        let ann = MKPointAnnotation()
        ann.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        mapView.addAnnotation(ann)
        if mapView.overlays.isEmpty {
            let r = MKCoordinateRegion(center: ann.coordinate, latitudinalMeters: 800, longitudinalMeters: 800)
            mapView.setRegion(r, animated: true)
        }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let r = MKPolylineRenderer(polyline: line)
        r.strokeColor = Theme.primary
        r.lineWidth = 4
        return r
    }

    static func fmtDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: d)
    }
}

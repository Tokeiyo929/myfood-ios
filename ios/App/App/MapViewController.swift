import UIKit
import MapKit

// 地图 tab：MapKit + 轨迹 + 开始/停止记录
class MapViewController: UIViewController, MKMapViewDelegate {
    private var mapView: MKMapView!
    private var statusLabel: UILabel!
    private var toggleBtn: UIButton!
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
        }
    }

    @objc private func openDayList() {
        navigationController?.pushViewController(TrackDaysViewController(), animated: true)
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

        toggleBtn = UIButton(type: .system)
        toggleBtn.backgroundColor = Theme.primary
        toggleBtn.setTitleColor(.white, for: .normal)
        toggleBtn.titleLabel?.font = .boldSystemFont(ofSize: 16)
        toggleBtn.layer.cornerRadius = 10
        toggleBtn.addTarget(self, action: #selector(toggleTracking), for: .touchUpInside)
        toggleBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toggleBtn)

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
            mapView.bottomAnchor.constraint(equalTo: toggleBtn.topAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: mapView.leadingAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: mapView.bottomAnchor, constant: -8),
            toggleBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toggleBtn.widthAnchor.constraint(equalToConstant: 180),
            toggleBtn.heightAnchor.constraint(equalToConstant: 44),
            toggleBtn.bottomAnchor.constraint(equalTo: infoLabel.topAnchor, constant: -8),
            infoLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            infoLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        updateToggle()
        statusLabel.text = "加载中…"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateToggle()
        loadTrack()
        guard viewDay == nil else { return }
        TrackRecorder.shared.onNewPoint = { [weak self] lat, lng in
            self?.addPointToLine(lat: lat, lng: lng)
            self?.statusLabel.text = "记录中 · \(TrackRecorder.shared.todayPoints.count)点"
        }
        TrackRecorder.shared.onStateChange = { [weak self] in self?.updateToggle() }
        TrackRecorder.shared.onError = { [weak self] message in Toast.show(message, self?.view) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard viewDay == nil else { return }
        TrackRecorder.shared.onNewPoint = nil
        TrackRecorder.shared.onStateChange = nil
        TrackRecorder.shared.onError = nil
    }

    private func updateToggle() {
        toggleBtn.setTitle(TrackRecorder.shared.isTracking ? "停止记录" : "开始记录", for: .normal)
        infoLabel.text = TrackRecorder.shared.isTracking ? "记录中…(锁屏也持续)" : ""
    }

    @objc private func toggleTracking() {
        if TrackRecorder.shared.isTracking {
            toggleBtn.isEnabled = false
            Task {
                defer { toggleBtn.isEnabled = true }
                do {
                    try await TrackRecorder.shared.stop()
                    loadTrack()
                } catch { Toast.show("上传失败，轨迹点已保留；开始记录后重试", view) }
            }
        } else {
            TrackRecorder.shared.start()
        }
        updateToggle()
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

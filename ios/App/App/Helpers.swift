import UIKit
import CoreLocation

// 全局主题（对齐小程序 #2f6b4f）
enum Theme {
    static let primary = UIColor(red: 0x2f/255.0, green: 0x6b/255.0, blue: 0x4f/255.0, alpha: 1)
    static let excellent = UIColor(red: 0x2c/255.0, green: 0x9e/255.0, blue: 0x5f/255.0, alpha: 1)
    static let bad = UIColor(red: 0xc0/255.0, green: 0x50/255.0, blue: 0x4d/255.0, alpha: 1)
    static let border = UIColor(red: 0xe0/255.0, green: 0xe0/255.0, blue: 0xe0/255.0, alpha: 1)
}

// 异步图片加载 + 内存缓存，避免 cell 复用时重复下载
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()

    func load(_ url: URL?, into imageView: UIImageView) {
        imageView.tag += 1
        imageView.image = UIImage(systemName: "photo")
        guard let url else { return }
        let tag = imageView.tag
        if let img = cache.object(forKey: url as NSURL) {
            imageView.image = img
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            self.cache.setObject(img, forKey: url as NSURL)
            DispatchQueue.main.async {
                if imageView.tag == tag { imageView.image = img }
            }
        }.resume()
    }
}

extension AppConfig {
    // 记录卡片装饰：偏好着色 class + 味道/材料标签
    static func decorate(_ record: [String: Any]) -> DecoratedRecord {
        let c = shared
        var d = DecoratedRecord(record: record)
        if let pref = record["preference"] as? String, let cfg = c,
           let excellent = cfg.preferences.last, let bad = cfg.preferences.first {
            if pref == excellent.value { d.prefKind = .excellent }
            else if pref == bad.value { d.prefKind = .bad }
            else { d.prefKind = .good }
        }
        if let cfg = c, let fl = record["flavors"] as? [[String: Any]] {
            d.flavorLabels = fl.compactMap { f -> String? in
                guard let name = f["name"] as? String, let level = f["level"] as? Int, level != cfg.flavorScale["default"] else { return nil }
                return cfg.flavorLabel(name, level: level)
            }
        }
        if let ing = record["ingredients"] as? [[String: Any]] {
            d.ingredientLabels = ing.compactMap { i -> String? in
                guard let n = i["name"] as? String else { return nil }
                if let a = i["amount"] as? NSNumber, a.doubleValue != 0 { return "\(n)(\(a.intValue)%)" }
                if let a = i["amount"] as? String, !a.isEmpty, a != "0" { return "\(n)(\(a)%)" }
                return n
            }
        }
        return d
    }
}

struct DecoratedRecord {
    enum PrefKind { case excellent, bad, good }
    let record: [String: Any]
    var id: Int { record["id"] as? Int ?? 0 }
    var name: String { (record["name"] as? String) ?? "" }
    var brand: String { (record["brand_name"] as? String) ?? "" }
    var imagePath: String? { record["image_path"] as? String }
    var repurchase: Int { record["repurchase"] as? Int ?? 0 }
    var prefKind: PrefKind?
    var flavorLabels: [String] = []
    var ingredientLabels: [String] = []
    var prefBorderColor: UIColor? {
        switch prefKind {
        case .excellent: return Theme.excellent
        case .bad: return Theme.bad
        default: return nil
        }
    }
}

// 拍摄时间元数据（EXIF 风格，对齐小程序）
func nowTakenAt() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return f.string(from: Date())
}

// 一次性定位（对齐 wx.getLocation；iOS 为 WGS84 原始坐标）
@MainActor
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    struct Result { let lat: Double; let lng: Double }
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<Result?, Never>?
    private var requested = false

    static func fetch() async -> Result? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }
        let locator = LocationOnce()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                locator.cont = continuation
                locator.manager.delegate = locator
                locator.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                if Task.isCancelled { locator.finish(nil) }
                else { locator.authorize() }
            }
        }, onCancel: { Task { @MainActor in locator.finish(nil) } })
    }

    private func authorize() {
        guard cont != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if !requested { requested = true; manager.requestLocation() }
        default: finish(nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { authorize() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last.map { Result(lat: $0.coordinate.latitude, lng: $0.coordinate.longitude) })
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }

    private func finish(_ result: Result?) {
        let continuation = cont
        cont = nil
        manager.delegate = nil
        manager.stopUpdatingLocation()
        continuation?.resume(returning: result)
    }
}

extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let m = max(size.width, size.height)
        guard m > maxDimension else { return self }
        let scale = maxDimension / m
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

final class Toast {
    static func show(_ text: String, _ view: UIView?) {
        guard let v = view else { return }
        let lb = UILabel()
        lb.text = text
        lb.font = .systemFont(ofSize: 14)
        lb.textColor = .white
        lb.backgroundColor = UIColor(white: 0, alpha: 0.75)
        lb.textAlignment = .center
        lb.layer.cornerRadius = 8
        lb.clipsToBounds = true
        lb.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(lb)
        NSLayoutConstraint.activate([
            lb.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            lb.bottomAnchor.constraint(equalTo: v.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            lb.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            lb.heightAnchor.constraint(equalToConstant: 36),
        ])
        UIView.animate(withDuration: 0.25, delay: 1.2, options: [], animations: { lb.alpha = 0 }) { _ in lb.removeFromSuperview() }
    }
}

import UIKit

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
        guard let url else { imageView.image = nil; return }
        imageView.tag += 1
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

// 配置（/api/config）的轻量包装：味道刻度 / 偏好选项 / 分页
final class AppConfig {
    static var shared: AppConfig?
    let raw: [String: Any]
    let flavorScale: [String: Int]        // min/default/max/low/mid/high threshold
    let flavors: [String]
    let preferences: [(value: Int, label: String, face: String, level: Int)] // 按 level 升序
    let pageSize: Int
    let maxPageSize: Int
    let imageMaxDimension: Int
    let imageQuality: CGFloat

    init?(raw: [String: Any]) {
        guard let scale = raw["flavor_scale"] as? [String: Any] else { return nil }
        self.raw = raw
        flavorScale = [
            "min": scale["min_level"] as? Int ?? 0,
            "default": scale["default_level"] as? Int ?? 1,
            "max": scale["max_level"] as? Int ?? 5,
            "low": scale["low_threshold"] as? Int ?? 1,
            "mid": scale["mid_threshold"] as? Int ?? 3,
            "high": scale["high_threshold"] as? Int ?? 4,
        ]
        flavors = raw["flavors"] as? [String] ?? []
        var prefs: [(Int, String, String, Int)] = []
        if let p = raw["preferences"] as? [String: Any] {
            for (_, v) in p {
                guard let pv = v as? [String: Any],
                      let value = pv["value"] as? Int,
                      let level = pv["level"] as? Int else { continue }
                prefs.append((value, pv["label"] as? String ?? "", pv["face"] as? String ?? "", level))
            }
        }
        preferences = prefs.sorted { $0.3 < $1.3 }
        let pag = raw["pagination"] as? [String: Any] ?? [:]
        pageSize = pag["page_size"] as? Int ?? 10
        maxPageSize = pag["max_page_size"] as? Int ?? 100
        let img = raw["image"] as? [String: Any] ?? [:]
        imageMaxDimension = img["max_dimension"] as? Int ?? 320
        imageQuality = (img["quality"] as? Double).map { $0 <= 1 ? CGFloat($0) : CGFloat($0) / 100.0 } ?? 0.8
    }

    static func load() async -> AppConfig? {
        if let s = shared { return s }
        guard let raw = try? await API.getConfig(), let c = AppConfig(raw: raw) else { return nil }
        shared = c
        return c
    }

    // 味道标签文案：不X / 微X / X / 太X
    func flavorLabel(_ name: String, level: Int) -> String {
        let s = flavorScale
        if level < s["low"]! { return "不" + name }
        if level < s["mid"]! { return "微" + name }
        if level < s["high"]! { return name }
        return "太" + name
    }

    // 记录卡片装饰：偏好着色 class + 味道/材料标签
    static func decorate(_ record: [String: Any]) -> DecoratedRecord {
        let c = shared
        var d = DecoratedRecord(record: record)
        if let pref = record["preference"] as? Int, let cfg = c,
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

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

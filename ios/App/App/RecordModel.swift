import SwiftUI

// 记录卡片装饰模型（从 UIKit Helpers 移植，历史列表与详情横条共用）
enum PrefKind {
    case excellent, bad, good
}

struct DecoratedRecord {
    let record: [String: Any]
    var id: Int { record["id"] as? Int ?? 0 }
    var name: String { (record["name"] as? String) ?? "" }
    var brand: String { (record["brand_name"] as? String) ?? "" }
    var imagePath: String? { record["image_path"] as? String }
    var repurchase: Int { record["repurchase"] as? Int ?? 0 }
    var freshness: String { FoodFreshness.normalize(record["freshness"]) }
    var prefKind: PrefKind?
    var flavorLabels: [String] = []
    var ingredientLabels: [String] = []

    var displayTitle: AttributedString {
        var s = AttributedString(name.isEmpty ? "未命名" : name)
        s.font = .system(size: 15, weight: .bold)
        if !brand.isEmpty {
            var b = AttributedString(" - \(brand)")
            b.font = .system(size: 13)
            b.foregroundColor = .secondary
            s.append(b)
        }
        return s
    }

    var prefColor: Color? {
        switch prefKind {
        case .excellent: return Theme.excellent
        case .bad: return Theme.bad
        default: return nil
        }
    }
}

@MainActor
enum RecordDecorator {
    static func decorate(_ record: [String: Any]) -> DecoratedRecord {
        var d = DecoratedRecord(record: record)
        if let pref = record["preference"] as? String, let cfg = AppConfig.shared,
           let excellent = cfg.preferences.last, let bad = cfg.preferences.first {
            if pref == excellent.value { d.prefKind = .excellent }
            else if pref == bad.value { d.prefKind = .bad }
            else { d.prefKind = .good }
        }
        if let cfg = AppConfig.shared, let fl = record["flavors"] as? [[String: Any]] {
            // 按分数降序展示（97 的太辣排在 40 的微酸前），50=默认值照旧不显示
            d.flavorLabels = fl.compactMap { f -> (level: Int, label: String)? in
                guard let name = f["name"] as? String, let level = f["level"] as? Int, level != cfg.flavorScale["default"] else { return nil }
                return (level, cfg.flavorLabel(name, level: level))
            }
            .sorted { $0.level > $1.level }
            .map { $0.label }
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

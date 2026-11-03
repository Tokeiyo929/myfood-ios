import Foundation

final class AppConfig {
    static var shared: AppConfig?
    private static var loading: Task<AppConfig, Error>?
    let flavorScale: [String: Int]
    let flavors: [String]
    let preferences: [(value: String, label: String, face: String, level: Int)]
    let defaultPreference: String
    let pageSize: Int
    let maxPageSize: Int
    let imageMaxDimension: Int
    let imageQuality: CGFloat

    init(raw: [String: Any]) throws {
        func invalid() -> APIError { APIError(message: "服务器配置无效，请重试") }
        guard let scale = raw["flavor_scale"] as? [String: Int],
              let minimum = scale["min_level"], let maximum = scale["max_level"],
              let normal = scale["default_level"], let low = scale["low_threshold"],
              let mid = scale["mid_threshold"], let high = scale["high_threshold"],
              minimum <= low, low < mid, mid < high, high <= maximum,
              (minimum...maximum).contains(normal),
              let flavors = raw["flavors"] as? [String], !flavors.isEmpty,
              Set(flavors).count == flavors.count, flavors.allSatisfy({ !$0.isEmpty }),
              let prefs = raw["preferences"] as? [String: [String: Any]], !prefs.isEmpty,
              let good = prefs["good"]?["value"] as? String,
              let pagination = raw["pagination"] as? [String: Int],
              let page = pagination["page_size"], let maxPage = pagination["max_page_size"],
              page > 0, maxPage >= page,
              let image = raw["image"] as? [String: Any],
              let dimension = image["max_dimension"] as? Int, dimension > 0,
              let quality = image["quality"] as? Double, quality > 0, quality <= 1
        else { throw invalid() }
        var options: [(String, String, String, Int)] = []
        for pref in prefs.values {
            guard let value = pref["value"] as? String, !value.isEmpty,
                  let label = pref["label"] as? String, !label.isEmpty,
                  let face = pref["face"] as? String,
                  let level = pref["level"] as? Int else { throw invalid() }
            options.append((value, label, face, level))
        }
        guard options.count >= 2, Set(options.map { $0.0 }).count == options.count,
              Set(options.map { $0.3 }).count == options.count else { throw invalid() }
        flavorScale = ["min": minimum, "default": normal, "max": maximum, "low": low, "mid": mid, "high": high]
        self.flavors = flavors
        preferences = options.sorted { $0.3 < $1.3 }
        defaultPreference = good
        pageSize = page
        maxPageSize = maxPage
        imageMaxDimension = dimension
        imageQuality = CGFloat(quality)
    }

    @MainActor
    static func load() async throws -> AppConfig {
        if let config = shared { return config }
        if let loading { return try await loading.value }
        let task = Task { try AppConfig(raw: await API.getConfig()) }
        loading = task
        defer { loading = nil }
        let config = try await task.value
        shared = config
        return config
    }

    func flavorLabel(_ name: String, level: Int) -> String {
        if level < flavorScale["low"]! { return "不" + name }
        if level < flavorScale["mid"]! { return "微" + name }
        if level < flavorScale["high"]! { return name }
        return "太" + name
    }
}

struct CommentDraft {
    var comments: [String] = []
    var editingIndex: Int?

    mutating func remove(at index: Int) {
        guard comments.indices.contains(index) else { return }
        comments.remove(at: index)
        if let editing = editingIndex {
            editingIndex = editing == index ? nil : editing > index ? editing - 1 : editing
        }
    }

    func applying(_ text: String) throws -> [String] {
        var result = comments
        if let index = editingIndex {
            guard result.indices.contains(index) else { throw APIError(message: "评论已变化，请重新选择") }
            if text.isEmpty { result.remove(at: index) } else { result[index] = text }
        } else if !text.isEmpty { result.append(text) }
        return result
    }
}

@MainActor
final class TrackUploadQueue {
    // shortcut: 待上传点仅存内存；需要进程退出恢复时再增加磁盘队列。
    private(set) var pending: [[String: Any]] = []
    private var uploading: Task<Void, Error>?
    private let send: ([[String: Any]]) async throws -> Void

    init(send: @escaping ([[String: Any]]) async throws -> Void = API.postTrackPoints) { self.send = send }

    func append(_ point: [String: Any]) { pending.append(point) }

    func flush() async throws {
        if let uploading { return try await uploading.value }
        let task = Task { @MainActor in
            while !self.pending.isEmpty {
                let batch = Array(self.pending.prefix(10))
                try await self.send(batch)
                self.pending.removeFirst(batch.count)
            }
        }
        uploading = task
        defer { uploading = nil }
        try await task.value
    }
}

enum RankOrder {
    static func changes(_ list: [[String: Any]], current: [[String: Any]], category: String) -> [(id: Int, rank: [String: Any])] {
        list.enumerated().compactMap { index, food in
            guard let id = food["id"] as? Int,
                  let saved = current.first(where: { ($0["id"] as? Int) == id }) else { return nil }
            var ranks = saved["category_rank"] as? [String: Any] ?? [:]
            guard ranks[category] as? Int != index + 1 else { return nil }
            ranks[category] = index + 1
            return (id, ranks)
        }
    }
}

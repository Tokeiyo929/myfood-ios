import Foundation

// ============ 修改同步日志 ============
// 本机记录每次写操作（建档/改详情/换图/删除/原料/摘抄）及其到远端的状态，仅设置页展示。
// 在线直发成功=已到远端；断网/失败入队的项由 SyncEngine 重放后翻状态。
// status: synced=已到远端 / pending=待上传 / failed=失败（见 error，下次同步成功会翻回 synced）
struct SyncLogEntry: Identifiable {
    let id: String      // 与 PendingMutation.uuid 同值（待上传项），同步引擎据此翻状态；在线直发项为随机 uuid
    let time: Date
    let kind: String    // create | patch | delete | ingredient | quoteCreate | quoteDelete
    let target: String  // 记录名 / 原料名 / 「摘抄」
    let detail: String  // 变更摘要，如 换图 / 评论
    var status: String
    var error: String?

    var kindLabel: String {
        switch kind {
        case "create": return "新建"
        case "patch": return "修改"
        case "delete": return "删除"
        case "ingredient": return "原料"
        case "quoteCreate": return "摘抄"
        case "quoteDelete": return "删摘抄"
        case "conflict": return "冲突"
        default: return kind
        }
    }
}

enum SyncLog {
    private static let lock = NSLock()
    private static let file = "synclog.json"
    private static let limit = 60

    // 最新的在前
    static func entries(limit n: Int = 12) -> [SyncLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(load().prefix(n))
    }

    static func append(kind: String, target: String, detail: String = "", status: String, linkUUID: String? = nil, error: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        let entry = SyncLogEntry(
            id: linkUUID ?? UUID().uuidString,
            time: Date(),
            kind: kind,
            target: target,
            detail: detail,
            status: status,
            error: error
        )
        list.insert(entry, at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
        save(list)
    }

    // SyncEngine 重放完一条：把对应待上传项翻成 synced/failed
    static func mark(uuid: String, status: String, error: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == uuid }) else { return }
        list[i].status = status
        list[i].error = error
        save(list)
    }

    // MARK: 存取（复用 OfflineStore 的落盘目录；日志小，读写皆同步）

    private static func load() -> [SyncLogEntry] {
        guard let raw = OfflineStore.loadJSON(name: file) as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            guard let id = d["id"] as? String, let kind = d["kind"] as? String else { return nil }
            return SyncLogEntry(
                id: id,
                time: Date(timeIntervalSince1970: d["time"] as? Double ?? 0),
                kind: kind,
                target: d["target"] as? String ?? "",
                detail: d["detail"] as? String ?? "",
                status: d["status"] as? String ?? "synced",
                error: d["error"] as? String
            )
        }
    }

    private static func save(_ list: [SyncLogEntry]) {
        let raw: [[String: Any]] = list.map {
            var d: [String: Any] = ["id": $0.id, "time": $0.time.timeIntervalSince1970, "kind": $0.kind, "target": $0.target, "detail": $0.detail, "status": $0.status]
            if let e = $0.error { d["error"] = e }
            return d
        }
        OfflineStore.saveJSON(raw, name: file)
    }
}

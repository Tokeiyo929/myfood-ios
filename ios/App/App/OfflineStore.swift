import Foundation
import CryptoKit
import Network

// ============ 离线能力中枢 ============
// 磁盘缓存（配置/记录/类别/轨迹/图片）+ 离线写操作队列 + 联网自动同步。
// 目标：断网时浏览、搜索、建档、编辑、删除、换图、排名、轨迹查看照常可用；
// 写操作先乐观落本地，恢复联网后由 SyncEngine 按序重放（create 用 client_key 幂等）。
// 所有落盘 JSON 走 JSONSerialization；记录键为主键 id，本地离线新建用负数 id。

struct PendingMutation {
    var uuid = UUID().uuidString
    var kind: String            // create | patch | delete | ingredient
    var serverId: Int?          // patch/delete 目标（服务端 id）
    var clientKey: String?      // create 幂等键；本地记录的 patch 目标，同步 create 成功后被改写为 serverId
    var localId: Int?           // create 对应的本地负数 id
    var name: String?           // ingredient 名称
    var fields: [String: Any]?  // patch 内容
    var record: [String: Any]?  // create 内容（不含 id）
    var localImage: String?     // 待上传本地图（offline:<name>）

    static func create(record: [String: Any], clientKey: String, localId: Int, localImage: String?) -> PendingMutation {
        var m = PendingMutation(kind: "create")
        m.record = record
        m.clientKey = clientKey
        m.localId = localId
        m.localImage = localImage
        return m
    }
    static func patch(serverId: Int, fields: [String: Any]) -> PendingMutation {
        var m = PendingMutation(kind: "patch")
        m.serverId = serverId
        m.fields = fields
        return m
    }
    static func patchLocal(clientKey: String, fields: [String: Any]) -> PendingMutation {
        var m = PendingMutation(kind: "patch")
        m.clientKey = clientKey
        m.fields = fields
        return m
    }
    static func delete(serverId: Int) -> PendingMutation {
        var m = PendingMutation(kind: "delete")
        m.serverId = serverId
        return m
    }
    static func ingredient(_ name: String) -> PendingMutation {
        var m = PendingMutation(kind: "ingredient")
        m.name = name
        return m
    }
    static func quoteCreate(record: [String: Any], clientKey: String, localId: Int) -> PendingMutation {
        var m = PendingMutation(kind: "quoteCreate")
        m.record = record
        m.clientKey = clientKey
        m.localId = localId
        return m
    }
    static func quoteDelete(serverId: Int) -> PendingMutation {
        var m = PendingMutation(kind: "quoteDelete")
        m.serverId = serverId
        return m
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["uuid": uuid, "kind": kind]
        if let serverId { d["serverId"] = serverId }
        if let clientKey { d["clientKey"] = clientKey }
        if let localId { d["localId"] = localId }
        if let name { d["name"] = name }
        if let fields { d["fields"] = fields }
        if let record { d["record"] = record }
        if let localImage { d["localImage"] = localImage }
        return d
    }

    static func from(dict: [String: Any]) -> PendingMutation? {
        guard let uuid = dict["uuid"] as? String, let kind = dict["kind"] as? String else { return nil }
        var m = PendingMutation(uuid: uuid, kind: kind)
        m.serverId = dict["serverId"] as? Int
        m.clientKey = dict["clientKey"] as? String
        m.localId = dict["localId"] as? Int
        m.name = dict["name"] as? String
        m.fields = dict["fields"] as? [String: Any]
        m.record = dict["record"] as? [String: Any]
        m.localImage = dict["localImage"] as? String
        return m
    }
}

enum OfflineStore {
    private static let lock = NSLock()
    private static var dirCache: URL?
    private static var recordsCache: [Int: [String: Any]]?

    // MARK: 目录与 JSON 读写
    // NSLock 不可重入：持锁内部一律走 *Unlocked 版本，公开方法仅做薄封装

    private static func dirUnlocked() -> URL {
        if let dirCache { return dirCache }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyFood", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dirCache = base
        return base
    }

    static var dir: URL {
        lock.lock(); defer { lock.unlock() }
        return dirUnlocked()
    }

    static func saveJSON(_ obj: Any, name: String) {
        lock.lock(); defer { lock.unlock() }
        saveJSONUnlocked(obj, name: name)
    }

    static func loadJSON(name: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return loadJSONUnlocked(name: name)
    }

    private static func saveJSONUnlocked(_ obj: Any, name: String) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: dirUnlocked().appendingPathComponent(name), options: .atomic)
    }

    private static func loadJSONUnlocked(name: String) -> Any? {
        guard let data = try? Data(contentsOf: dirUnlocked().appendingPathComponent(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: 配置 / 类别缓存

    static func saveConfig(_ raw: [String: Any]) { saveJSON(raw, name: "config.json") }
    static func cachedConfig() -> [String: Any]? { loadJSON(name: "config.json") as? [String: Any] }

    static func saveCategories(_ items: [[String: Any]]) { saveJSON(["items": items], name: "categories.json") }
    static func cachedCategories() -> [[String: Any]] {
        (loadJSON(name: "categories.json") as? [String: Any])?["items"] as? [[String: Any]] ?? []
    }

    // MARK: 记录缓存

    private static func records() -> [Int: [String: Any]] {
        if let recordsCache { return recordsCache }
        let raw = loadJSONUnlocked(name: "records.json") as? [String: [String: Any]] ?? [:]
        var out: [Int: [String: Any]] = [:]
        for (key, value) in raw {
            guard let id = Int(key) else { continue }
            out[id] = value
        }
        recordsCache = out
        return out
    }

    private static func persistRecords(_ recs: [Int: [String: Any]]) {
        recordsCache = recs
        var raw: [String: Any] = [:]
        for (id, value) in recs { raw[String(id)] = value }
        saveJSONUnlocked(raw, name: "records.json")
    }

    static func mergeRecords(_ items: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        var recs = records()
        for item in items {
            guard let id = item["id"] as? Int else { continue }
            recs[id] = item
        }
        persistRecords(recs)
    }

    static func upsertRecord(_ record: [String: Any]) { mergeRecords([record]) }

    // 整表重建（手动同步拉取）：保留本地未同步（负数 id）记录
    static func rebuildRecords(_ items: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        let locals = records().values.filter { ($0["id"] as? Int ?? 0) < 0 }
        var byId: [Int: [String: Any]] = [:]
        (locals + items).forEach { r in if let id = r["id"] as? Int { byId[id] = r } }
        persistRecords(byId)
    }

    static func record(id: Int) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return records()[id]
    }

    static func removeRecord(id: Int) {
        lock.lock(); defer { lock.unlock() }
        var recs = records()
        guard recs[id] != nil else { return }
        recs[id] = nil
        persistRecords(recs)
    }

    static func allocateLocalId() -> Int {
        lock.lock(); defer { lock.unlock() }
        let minId = records().keys.min() ?? 0
        return min(minId, 0) - 1
    }

    // 排序镜像服务端：最后修改日期倒序、id 倒序；本地负数 id（未同步新建）视为最新置顶
    static func sortRecords(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let ia = a["id"] as? Int ?? 0
        let ib = b["id"] as? Int ?? 0
        if (ia < 0) != (ib < 0) { return ia < 0 }
        let ma = (a["modify_at"] as? [String])?.last ?? ""
        let mb = (b["modify_at"] as? [String])?.last ?? ""
        if ma != mb { return ma > mb }
        return ia > ib
    }

    static func cachedRecords() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return Array(records().values).sorted(by: sortRecords)
    }

    // 本地搜索镜像服务端 ILIKE 字段：名称 / 品牌 / 原料名
    static func searchRecords(_ query: String) -> [[String: Any]] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = cachedRecords()
        guard !q.isEmpty else { return all }
        return all.filter { r in
            if ((r["name"] as? String) ?? "").lowercased().contains(q) { return true }
            if ((r["brand_name"] as? String) ?? "").lowercased().contains(q) { return true }
            if let ings = r["ingredients"] as? [[String: Any]],
               ings.contains(where: { (($0["name"] as? String) ?? "").lowercased().contains(q) }) { return true }
            return false
        }
    }

    static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func isToday(_ record: [String: Any]) -> Bool {
        (record["modify_at"] as? [String])?.last == todayString()
    }

    // MARK: 轨迹缓存

    static func saveTrackDays(_ days: [[String: Any]]) { saveJSON(["days": days], name: "track-days.json") }
    static func cachedTrackDays() -> [[String: Any]] {
        (loadJSON(name: "track-days.json") as? [String: Any])?["days"] as? [[String: Any]] ?? []
    }
    static func saveTrackPoints(_ points: [[String: Any]], day: String) {
        saveJSON(["points": points], name: "track-\(day).json")
    }
    static func cachedTrackPoints(day: String) -> [[String: Any]] {
        (loadJSON(name: "track-\(day).json") as? [String: Any])?["points"] as? [[String: Any]] ?? []
    }

    // MARK: 图片（远端磁盘缓存 + 离线待传原图）

    private static func imagesDir() -> URL {
        let base = dir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // 离线建档/换图：原图落盘，记录里存 "offline:<文件名>" 占位路径
    static func saveLocalImage(_ data: Data) -> String {
        let name = "local-" + UUID().uuidString + ".jpg"
        try? data.write(to: imagesDir().appendingPathComponent(name), options: .atomic)
        return "offline:" + name
    }

    static func localImageURL(_ path: String) -> URL? {
        guard path.hasPrefix("offline:") else { return nil }
        return imagesDir().appendingPathComponent(String(path.dropFirst("offline:".count)))
    }

    static func localImageData(_ path: String) -> Data? {
        guard let url = localImageURL(path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func removeLocalImage(_ path: String) {
        guard let url = localImageURL(path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // 远端图片磁盘缓存：签名 URL 参数会过期，缓存键用稳定 path
    static func cacheImage(_ data: Data, for url: URL) {
        guard !url.isFileURL else { return }
        try? data.write(to: imagesDir().appendingPathComponent("c-" + sha256Hex(url.path)), options: .atomic)
    }

    static func cachedImageData(for url: URL) -> Data? {
        guard !url.isFileURL else { return nil }
        return try? Data(contentsOf: imagesDir().appendingPathComponent("c-" + sha256Hex(url.path)))
    }

    // MARK: 待同步队列

    private static func pendingList() -> [PendingMutation] {
        let raw = loadJSONUnlocked(name: "pending.json") as? [[String: Any]] ?? []
        return raw.compactMap { PendingMutation.from(dict: $0) }
    }

    private static func savePending(_ list: [PendingMutation]) {
        saveJSONUnlocked(list.map { $0.dict }, name: "pending.json")
    }

    static func pendingMutations() -> [PendingMutation] {
        lock.lock(); defer { lock.unlock() }
        return pendingList()
    }

    static func enqueue(_ mutation: PendingMutation) {
        lock.lock(); defer { lock.unlock() }
        var list = pendingList()
        list.append(mutation)
        savePending(list)
    }

    static func removeMutation(uuid: String) {
        lock.lock(); defer { lock.unlock() }
        var list = pendingList()
        list.removeAll { $0.uuid == uuid }
        savePending(list)
    }

    // create 成功后：把后续指向该本地记录的 patch 改写为服务端 id
    static func resolvePending(clientKey: String, serverId: Int?) {
        lock.lock(); defer { lock.unlock() }
        var list = pendingList()
        for i in list.indices where list[i].clientKey == clientKey && list[i].kind == "patch" {
            list[i].serverId = serverId
            list[i].clientKey = nil
        }
        savePending(list)
    }

    // 本地未同步记录被离线删除：连同 create 队列项与其后续 patch 一起撤销
    // （已改写为服务端 id 的 patch 不受影响——那条记录服务端已存在）
    static func cancelPendingCreate(clientKey: String) {
        lock.lock(); defer { lock.unlock() }
        var list = pendingList()
        list.removeAll {
            ($0.kind == "create" && $0.clientKey == clientKey) || ($0.kind == "patch" && $0.clientKey == clientKey)
        }
        savePending(list)
    }

    static func pendingCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return pendingList().count
    }

    // MARK: 摘抄缓存

    private static var quotesCache: [[String: Any]]?

    private static func sortQuotes(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let ia = a["id"] as? Int ?? 0
        let ib = b["id"] as? Int ?? 0
        if (ia < 0) != (ib < 0) { return ia < 0 } // 本地新档置顶
        if ia != ib { return ia > ib }            // 服务端按创建时间倒序返回，用 id 兜底
        return false
    }

    private static func quotes() -> [[String: Any]] {
        if let quotesCache { return quotesCache }
        let raw = loadJSONUnlocked(name: "quotes.json") as? [[String: Any]] ?? []
        quotesCache = raw
        return raw
    }

    private static func persistQuotes(_ list: [[String: Any]]) {
        quotesCache = list
        saveJSONUnlocked(list, name: "quotes.json")
    }

    static func rebuildQuotes(_ items: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        // 整表重建：保留本地未同步（负数 id）记录
        let locals = quotes().filter { ($0["id"] as? Int ?? 0) < 0 }
        persistQuotes((locals + items).sorted(by: sortQuotes))
    }

    static func mergeQuotes(_ items: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        var byId: [Int: [String: Any]] = [:]
        quotes().forEach { q in byId[q["id"] as? Int ?? 0] = q }
        items.forEach { q in if let id = q["id"] as? Int { byId[id] = q } }
        persistQuotes(byId.values.sorted(by: sortQuotes))
    }

    static func upsertQuote(_ quote: [String: Any]) { mergeQuotes([quote]) }

    static func quote(id: Int) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return quotes().first { ($0["id"] as? Int) == id }
    }

    static func removeQuote(id: Int) {
        lock.lock(); defer { lock.unlock() }
        persistQuotes(quotes().filter { ($0["id"] as? Int) != id })
    }

    static func cachedQuotes() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return quotes()
    }

    static func allocateLocalQuoteId() -> Int {
        lock.lock(); defer { lock.unlock() }
        let minId = quotes().compactMap { $0["id"] as? Int }.min() ?? 0
        return min(minId, 0) - 1
    }

    // 本地未同步摘抄被离线删除：连同 create 队列项一并撤销
    static func cancelPendingQuoteCreate(clientKey: String) {
        lock.lock(); defer { lock.unlock() }
        var list = pendingList()
        list.removeAll { $0.kind == "quoteCreate" && $0.clientKey == clientKey }
        savePending(list)
    }

    // MARK: 测试辅助

    static func wipeAll() {
        lock.lock(); defer { lock.unlock() }
        recordsCache = nil
        quotesCache = []
        try? FileManager.default.removeItem(at: dirUnlocked())
        try? FileManager.default.createDirectory(at: dirUnlocked(), withIntermediateDirectories: true)
    }
}

// 网络不可达（可离线兜底/入队）还是业务错误（不该被缓存/队列掩盖）
func isNetworkError(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff,
             .secureConnectionFailed, .serverCertificateUntrusted:
            return true
        default: return false
        }
    }
    let ns = error as NSError
    return ns.domain == NSURLErrorDomain
}

// ============ 联网状态监听 ============

final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true
    var onReconnect: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                if online { self.onReconnect?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "myfood.network-monitor"))
    }
}

// ============ 同步引擎：恢复联网后按序重放离线队列 ============

enum SyncEngine {
    private static var syncing = false

    @MainActor
    static func drain() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        while true {
            guard let first = OfflineStore.pendingMutations().first else { return }
            do {
                try await apply(first)
                OfflineStore.removeMutation(uuid: first.uuid)
            } catch {
                if isNetworkError(error) { return } // 仍离线：保留队列下次再试
                // 永久错误（4xx 等）：丢弃该条避免堵死队列；本地乐观数据保持原样
                if let localImage = first.localImage { OfflineStore.removeLocalImage(localImage) }
                OfflineStore.removeMutation(uuid: first.uuid)
            }
        }
    }

    @MainActor
    private static func apply(_ m: PendingMutation) async throws {
        switch m.kind {
        case "create":
            var rec = m.record ?? [:]
            var imagePath = rec["image_path"] as? String ?? ""
            var meta = rec["image_metadata"] as? [String: Any] ?? [:]
            if let localPath = m.localImage, let data = OfflineStore.localImageData(localPath) {
                let upload = try await API.uploadImage(jpegData: data)
                imagePath = upload["path"] as? String ?? imagePath
                // 服务端 EXIF 元数据在前，本地补充（拍摄时间/定位）覆盖
                if let exif = upload["metadata"] as? [String: Any] {
                    for (k, v) in exif where meta[k] == nil { meta[k] = v }
                }
            }
            rec["image_path"] = imagePath
            rec["image_metadata"] = meta
            let res = try await API.submitFood(rec)
            let serverId = res["id"] as? Int
            if let localId = m.localId, let sid = serverId {
                var updated = rec
                updated["id"] = sid
                OfflineStore.removeRecord(id: localId)
                OfflineStore.upsertRecord(updated)
                OfflineStore.resolvePending(clientKey: m.clientKey ?? "", serverId: sid)
            }
            if let localPath = m.localImage { OfflineStore.removeLocalImage(localPath) }
        case "patch":
            var fields = m.fields ?? [:]
            if let localPath = m.localImage, let data = OfflineStore.localImageData(localPath) {
                let upload = try await API.uploadImage(jpegData: data)
                var meta = fields["image_metadata"] as? [String: Any] ?? [:]
                if let exif = upload["metadata"] as? [String: Any] {
                    for (k, v) in exif where meta[k] == nil { meta[k] = v }
                }
                fields["image_metadata"] = meta
                fields["image_path"] = upload["path"] as? String ?? ""
            }
            guard let id = m.serverId else { throw APIError(message: "离线队列目标缺失") }
            _ = try await API.updateFoodDetails(id, fields: fields)
            if var rec = OfflineStore.record(id: id) {
                for (k, v) in fields where k != "image_path" || !(v as? String ?? "").hasPrefix("offline:") {
                    rec[k] = v
                }
                OfflineStore.upsertRecord(rec)
            }
            if let localPath = m.localImage { OfflineStore.removeLocalImage(localPath) }
        case "delete":
            guard let id = m.serverId else { throw APIError(message: "离线队列目标缺失") }
            _ = try await API.deleteFood(id)
            OfflineStore.removeRecord(id: id)
        case "ingredient":
            _ = try await API.addIngredient(m.name ?? "")
        case "quoteCreate":
            var rec = m.record ?? [:]
            let res = try await API.createQuote(text: rec["text"] as? String ?? "", note: rec["note"] as? String ?? "", clientKey: m.clientKey ?? "")
            let serverId = res["id"] as? Int
            if let localId = m.localId, let sid = serverId {
                var updated = rec
                updated["id"] = sid
                updated["day"] = OfflineStore.todayString() // 创建即今天；下次整表拉取会用服务端时间
                OfflineStore.removeQuote(id: localId)
                OfflineStore.upsertQuote(updated)
            }
        case "quoteDelete":
            guard let id = m.serverId else { throw APIError(message: "离线队列目标缺失") }
            _ = try await API.deleteQuote(id)
            OfflineStore.removeQuote(id: id)
        default:
            throw APIError(message: "未知离线操作：\(m.kind)")
        }
    }
}

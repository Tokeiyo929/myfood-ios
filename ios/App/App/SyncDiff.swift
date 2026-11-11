import Foundation

// ============ git 式同步 Diff 引擎 ============
// 三方对比模型（对齐 git）：
//   快照 synced.json = 上次同步完成时的远端状态（base）
//   本地 records/quotes 缓存 + 离线队列 = 工作区（ours）
//   暂存 remote.json = 静默拉取的远端现状（theirs，只存不应用，等同 git fetch）
// ↑pendingCount = 本地待推送；↓ = 远端新增/变化/删除；⚠ = 同一条记录两边都改（整条二选一解决）。
// 数据量小（百级记录），全量拉取 + 快照对比即可获得精确语义（快照有、拉取没有 = 远端已删），无需服务端版本号。

struct SyncFieldDiff: Identifiable {
    let key: String      // 字段 key（展示名见 SyncDiff.fieldLabel）
    let local: String
    let remote: String
    var id: String { key }
}

// 记录级冲突（foods；摘抄只有建/删、无编辑，不产生冲突）
struct FoodConflict: Identifiable {
    let id: Int                   // 服务端记录 id
    let name: String
    let localKind: String         // 有修改 | 已删除
    let remoteKind: String
    let fields: [SyncFieldDiff]   // 本地现值 vs 远端现值的差异明细
}

struct SyncDiffState {
    var pendingCount = 0
    var remoteChangedIds: [Int] = []      // 远端新增或有变化的记录
    var remoteDeletedIds: [Int] = []      // 远端已删除的记录
    var remoteQuoteIds: [Int] = []        // 远端新增摘抄
    var remoteQuoteDeletedIds: [Int] = [] // 远端删除摘抄
    var conflicts: [FoodConflict] = []

    var conflictIds: Set<Int> { Set(conflicts.map(\.id)) }
    var remoteChangeCount: Int {
        remoteChangedIds.count + remoteDeletedIds.count + remoteQuoteIds.count + remoteQuoteDeletedIds.count
    }
    var hasDiff: Bool { pendingCount > 0 || remoteChangeCount > 0 || !conflicts.isEmpty }
}

enum SyncDiff {
    enum Resolution { case local, remote }

    private static let snapshotFile = "synced.json"
    private static let stashFile = "remote.json"
    private static let stashMinInterval: TimeInterval = 30
    static var lastStashAt: Date? // 节流：设置页反复进出不重复全量拉取

    // 参与 diff 的记录字段；modify_at/repurchase 是服务端派生（复购计数）、id/client_key 是身份，不比较
    static let foodDiffFields = ["name", "brand_name", "price", "categories", "ingredients",
                                 "flavors", "preference", "worth_it", "comment",
                                 "category_rank", "image_path", "image_metadata"]

    // MARK: 静默拉取远端存暂存（git fetch）；失败静默，保持现有 diff 状态

    @discardableResult
    static func fetchAndStash(force: Bool = false) async -> (foods: [[String: Any]], quotes: [[String: Any]])? {
        if !force, let last = lastStashAt, Date().timeIntervalSince(last) < stashMinInterval { return nil }
        guard let config = try? await AppConfig.load() else { return nil }
        guard let foods = try? await API.getAllFoods(limit: config.maxPageSize),
              let quotes = try? await API.getQuotes() else { return nil }
        let quoteItems = quotes["items"] as? [[String: Any]] ?? []
        initializeSnapshotIfMissing(foods: foods, quotes: quoteItems)
        stashRemote(foods: foods, quotes: quoteItems)
        lastStashAt = Date()
        return (foods, quoteItems)
    }

    // MARK: 快照与暂存存取

    static func hasSnapshot() -> Bool { OfflineStore.loadJSON(name: snapshotFile) != nil }

    // 升级首启迁移：无快照时以当前远端为 base（在途修改仍由离线队列表示，一次性放弃对其的冲突检测）
    static func initializeSnapshotIfMissing(foods: [[String: Any]], quotes: [[String: Any]]) {
        guard !hasSnapshot() else { return }
        rebuildSnapshot(foods: foods, quotes: quotes)
    }

    // 同步完成后以服务端真值重建快照；仍有未推送改动（待重试/冲突待解决）的记录保留旧基线，
    // 否则其冲突基线被覆盖，下次 compute 不再报 ⚠，drain 会静默推平本地改动
    static func rebuildSnapshot(foods: [[String: Any]], quotes: [[String: Any]]) {
        let dirtyFoods = localDirtyFoodIds()
        let dirtyQuotes = localDirtyQuoteIds()
        let prevFoods = snapshotFoods()
        let prevQuotes = snapshotQuotes()
        var f: [String: Any] = [:]
        for r in foods {
            guard let id = r["id"] as? Int else { continue }
            if dirtyFoods.contains(id), let prev = prevFoods[id] { f[String(id)] = prev } else { f[String(id)] = normalizeFood(r) }
        }
        for id in dirtyFoods where f[String(id)] == nil { // 远端已删但本地有未推送改动：保留旧基线，维持 ⚠ 可见
            if let prev = prevFoods[id] { f[String(id)] = prev }
        }
        var q: [String: Any] = [:]
        for r in quotes {
            guard let id = r["id"] as? Int else { continue }
            if dirtyQuotes.contains(id), let prev = prevQuotes[id] { q[String(id)] = prev } else { q[String(id)] = normalizeQuote(r) }
        }
        for id in dirtyQuotes where q[String(id)] == nil {
            if let prev = prevQuotes[id] { q[String(id)] = prev }
        }
        saveSnapshot(foods: f, quotes: q)
    }

    static func stashRemote(foods: [[String: Any]], quotes: [[String: Any]]) {
        // 同步写：runManualSync/compute 紧跟着同步读 stash，write-behind 会读到旧文件
        OfflineStore.saveJSONSync(["time": Date().timeIntervalSince1970, "foods": foods, "quotes": quotes], name: stashFile)
    }

    static func clearStash() {
        try? FileManager.default.removeItem(at: OfflineStore.dir.appendingPathComponent(stashFile))
    }

    // MARK: 规范化比较（图片签名 URL 参数会过期轮换，只比稳定 path）

    static func normalizeImage(_ v: Any) -> Any {
        guard var s = v as? String, !s.isEmpty else { return v }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) } // 剥掉签名参数
        if let scheme = s.range(of: "://") { // 剥 scheme://host 只留 path：签名完整 URL 与上传返回的相对 key 归一可比
            let rest = s[scheme.upperBound...]
            if let slash = rest.firstIndex(of: "/") { s = String(rest[slash...]) }
        }
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }

    static func normalizeFood(_ r: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for k in foodDiffFields {
            guard let v = r[k] else { continue }
            out[k] = k == "image_path" ? normalizeImage(v) : v
        }
        // worth_it 对齐服务端存法（worker worthItValue）：Bool/NSNull/缺失 → "yes"/"no"/""，否则快照与远端表单永不等
        if let b = out["worth_it"] as? Bool {
            out["worth_it"] = b ? "yes" : "no"
        } else if out["worth_it"] == nil || out["worth_it"] is NSNull {
            out["worth_it"] = ""
        }
        return out
    }

    static func normalizeQuote(_ r: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for k in ["text", "note"] { if let v = r[k] { out[k] = v } }
        return out
    }

    static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNull, is NSNull): return true
        case (let x as NSNumber, let y as NSNumber): return x == y || x.doubleValue == y.doubleValue
        case (let x as String, let y as String): return x == y
        case (let x as [Any], let y as [Any]):
            return x.count == y.count && zip(x, y).allSatisfy { jsonEqual($0.0, $0.1) }
        case (let x as [String: Any], let y as [String: Any]):
            return x.count == y.count && x.allSatisfy { key, v in y[key].map { jsonEqual(v, $0) } ?? false }
        default: return false
        }
    }

    static func recordEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard a.count == b.count else { return false }
        return a.allSatisfy { k, v in b[k].map { jsonEqual(v, $0) } ?? false }
    }

    // MARK: 本地脏集（离线队列目标映射回记录 id；负数 id 不会出现在快照/远端，天然无冲突）

    static func localDirtyFoodIds() -> Set<Int> {
        var dirty: Set<Int> = []
        var byKey: [String: Int] = [:]
        for r in OfflineStore.cachedRecords() {
            if let k = r["client_key"] as? String, !k.isEmpty { byKey[k] = r["id"] as? Int ?? 0 }
        }
        for m in OfflineStore.pendingMutations() {
            switch m.kind {
            case "create":
                if let lid = m.localId { dirty.insert(lid) }
                if let k = m.clientKey, let rid = byKey[k] { dirty.insert(rid) }
            case "patch":
                if let sid = m.serverId { dirty.insert(sid) }
                if let k = m.clientKey, let rid = byKey[k] { dirty.insert(rid) }
            case "delete":
                if let sid = m.serverId { dirty.insert(sid) }
            default: break
            }
        }
        return dirty
    }

    static func localDeleteFoodIds() -> Set<Int> {
        Set(OfflineStore.pendingMutations().compactMap { $0.kind == "delete" ? $0.serverId : nil })
    }

    // 摘抄的脏集：quoteCreate（本地负 id + client_key 映射）/ quoteDelete
    static func localDirtyQuoteIds() -> Set<Int> {
        var dirty: Set<Int> = []
        var byKey: [String: Int] = [:]
        for q in OfflineStore.cachedQuotes() {
            if let k = q["client_key"] as? String, !k.isEmpty { byKey[k] = q["id"] as? Int ?? 0 }
        }
        for m in OfflineStore.pendingMutations() {
            switch m.kind {
            case "quoteCreate":
                if let lid = m.localId { dirty.insert(lid) }
                if let k = m.clientKey, let rid = byKey[k] { dirty.insert(rid) }
            case "quoteDelete":
                if let sid = m.serverId { dirty.insert(sid) }
            default: break
            }
        }
        return dirty
    }

    // MARK: 三方对比

    static func compute() -> SyncDiffState {
        var st = SyncDiffState()
        st.pendingCount = OfflineStore.pendingCount()
        guard let stashRaw = OfflineStore.loadJSON(name: stashFile) as? [String: Any],
              stashRaw["foods"] != nil || stashRaw["quotes"] != nil else { return st }
        let stashFoods = stashRaw["foods"] as? [[String: Any]] ?? []
        let stashQuotes = stashRaw["quotes"] as? [[String: Any]] ?? []
        let baseFoods = snapshotFoods()
        let baseQuotes = snapshotQuotes()
        let remoteFoodsById = Dictionary(stashFoods.compactMap { r in (r["id"] as? Int).map { ($0, r) } },
                                         uniquingKeysWith: { _, n in n })
        let recordsById = Dictionary(OfflineStore.cachedRecords().compactMap { r in (r["id"] as? Int).map { ($0, r) } },
                                     uniquingKeysWith: { _, n in n })
        let dirty = localDirtyFoodIds()
        let localDeletes = localDeleteFoodIds()

        var healedFoods: [[String: Any]] = [] // 自愈记录先收集，循环后批量并入快照（逐条全量写曾把主线程卡爆触发 watchdog 击杀）
        for r in stashFoods {
            guard let id = r["id"] as? Int else { continue }
            let norm = normalizeFood(r)
            if let base = baseFoods[id] {
                if !recordEqual(norm, base) {
                    // 三方判定：stash 与本地工作区一致 → 是自己已同步的内容，自愈陈旧快照，不误报 ↓
                    if let local = recordsById[id], recordEqual(norm, normalizeFood(local)) {
                        healedFoods.append(r)
                    } else {
                        st.remoteChangedIds.append(id)
                    }
                }
            } else if let local = recordsById[id], recordEqual(norm, normalizeFood(local)) {
                healedFoods.append(r) // 快照缺该 id 但本地已有同内容 → 自己推送的，补快照
            } else {
                st.remoteChangedIds.append(id) // 远端新增
            }
        }
        for id in baseFoods.keys where remoteFoodsById[id] == nil { st.remoteDeletedIds.append(id) }

        // 冲突 = 本地有未推送改动 ∩ 远端有变化（含删除）；双方都删除不算冲突（意图一致）
        for id in (Set(st.remoteChangedIds).union(st.remoteDeletedIds)).intersection(dirty).sorted() {
            let remote = remoteFoodsById[id]
            let local = recordsById[id]
            let localDeleted = localDeletes.contains(id)
            if localDeleted && remote == nil { continue }
            if local == nil && !localDeleted { continue } // 队列指向已不存在的记录且非删除，无从对比
            var fields: [SyncFieldDiff] = []
            if let remote, let localRec = local { // 本地已删/远端已删时无对等值可比，明细留空，靠 localKind/remoteKind 说明
                let normRemote = normalizeFood(remote)
                let normLocal = normalizeFood(localRec) // 本地侧同样归一，Bool worth_it/相对图片路径才可与远端可比
                for key in foodDiffFields {
                    switch (normLocal[key], normRemote[key]) {
                    case (nil, nil): continue
                    case (nil, let r?): fields.append(SyncFieldDiff(key: key, local: "（无）", remote: display(r)))
                    case (let l?, nil): fields.append(SyncFieldDiff(key: key, local: display(l), remote: "（无）"))
                    case (let l?, let r?):
                        if !jsonEqual(l, r) { fields.append(SyncFieldDiff(key: key, local: display(l), remote: display(r))) }
                    }
                }
            }
            let name = (local?["name"] as? String) ?? (remote?["name"] as? String) ?? ""
            st.conflicts.append(FoodConflict(
                id: id,
                name: name.isEmpty ? "记录 #\(id)" : name,
                localKind: localDeleted ? "已删除" : "有修改",
                remoteKind: remote == nil ? "已删除" : "有修改",
                fields: fields
            ))
        }

        let remoteQuotesById = Dictionary(stashQuotes.compactMap { r in (r["id"] as? Int).map { ($0, r) } },
                                          uniquingKeysWith: { _, n in n })
        let cachedQuotesById = Dictionary(OfflineStore.cachedQuotes().compactMap { q in (q["id"] as? Int).map { ($0, q) } },
                                          uniquingKeysWith: { _, n in n })
        var healedQuotes: [[String: Any]] = []
        for r in stashQuotes {
            guard let id = r["id"] as? Int else { continue }
            let norm = normalizeQuote(r)
            if let base = baseQuotes[id] {
                if !recordEqual(norm, base) {
                    // 同 foods 的三方判定：自己已同步的内容不误报
                    if let local = cachedQuotesById[id], recordEqual(norm, normalizeQuote(local)) {
                        healedQuotes.append(r)
                    } else {
                        st.remoteQuoteIds.append(id)
                    }
                }
            } else if let local = cachedQuotesById[id], recordEqual(norm, normalizeQuote(local)) {
                healedQuotes.append(r)
            } else {
                st.remoteQuoteIds.append(id) // 远端新增
            }
        }
        for id in baseQuotes.keys where remoteQuotesById[id] == nil { st.remoteQuoteDeletedIds.append(id) }
        // 自愈批量落盘：每轮 compute 只做 1-2 次全量序列化写，替代逐条 N 次
        if !healedFoods.isEmpty { snapshotUpsertFoods(healedFoods) }
        if !healedQuotes.isEmpty { snapshotUpsertQuotes(healedQuotes) }
        return st
    }

    // MARK: 应用远端变化（非冲突部分落到本地缓存；冲突项等解决后再动）

    @discardableResult
    static func applyRemoteChanges() -> Int {
        let st = compute()
        let conflicted = st.conflictIds
        guard let stashRaw = OfflineStore.loadJSON(name: stashFile) as? [String: Any] else { return 0 }
        let stashFoods = stashRaw["foods"] as? [[String: Any]] ?? []
        let stashQuotes = stashRaw["quotes"] as? [[String: Any]] ?? []
        var applied = 0

        let changedRaw = stashFoods.filter { r in
            guard let id = r["id"] as? Int else { return false }
            return st.remoteChangedIds.contains(id) && !conflicted.contains(id)
        }
        if !changedRaw.isEmpty { OfflineStore.mergeRecords(changedRaw); applied += changedRaw.count }
        let deletable = st.remoteDeletedIds.filter { !conflicted.contains($0) }
        for id in deletable { OfflineStore.removeRecord(id: id) }
        applied += deletable.count

        let quoteRaw = stashQuotes.filter { r in
            guard let id = r["id"] as? Int else { return false }
            return st.remoteQuoteIds.contains(id)
        }
        if !quoteRaw.isEmpty { OfflineStore.mergeQuotes(quoteRaw); applied += quoteRaw.count }
        for id in st.remoteQuoteDeletedIds { OfflineStore.removeQuote(id: id) }
        applied += st.remoteQuoteDeletedIds.count
        return applied
    }

    // MARK: 冲突解决（整条二选一）

    static func resolve(_ conflict: FoodConflict, choice: Resolution) {
        let targets = OfflineStore.pendingMutations().filter { m in
            switch m.kind {
            case "patch", "delete": return m.serverId == conflict.id
            default: return false
            }
        }
        let stashRaw = OfflineStore.loadJSON(name: stashFile) as? [String: Any]
        let stashFoods = stashRaw?["foods"] as? [[String: Any]] ?? []
        let remote = stashFoods.first { ($0["id"] as? Int) == conflict.id }
        let remoteGone = remote == nil

        switch choice {
        case .remote:
            for m in targets {
                OfflineStore.removeMutation(uuid: m.uuid)
                SyncLog.mark(uuid: m.uuid, status: "cancelled")
            }
            if let remote {
                OfflineStore.upsertRecord(remote) // 覆盖/恢复为远端内容
            } else {
                OfflineStore.removeRecord(id: conflict.id)
            }
            SyncLog.append(kind: "conflict", target: conflict.name,
                           detail: remoteGone ? "采用远端版本（接受删除）" : "采用远端版本", status: "synced")
        case .local:
            // 本地改动保留、队列照常推送；远端已删时把本地修改转为重建（create，原图不保证仍在，不带图）
            if remoteGone {
                for m in targets {
                    OfflineStore.removeMutation(uuid: m.uuid)
                    SyncLog.mark(uuid: m.uuid, status: "cancelled")
                }
                if var rec = OfflineStore.record(id: conflict.id) {
                    rec.removeValue(forKey: "id")
                    rec.removeValue(forKey: "client_key")
                    rec.removeValue(forKey: "image_path")
                    rec.removeValue(forKey: "image_metadata")
                    let key = UUID().uuidString
                    rec["client_key"] = key
                    let mutation = PendingMutation.create(record: rec, clientKey: key, localId: conflict.id, localImage: nil)
                    OfflineStore.enqueue(mutation) // localId=旧服务端 id，同步成功后 removeRecord+换新 id
                    SyncLog.append(kind: "create", target: conflict.name,
                                   detail: "远端已删除，本地版本转为重建（不带图片）", status: "pending", linkUUID: mutation.uuid)
                }
            }
            SyncLog.append(kind: "conflict", target: conflict.name, detail: "采用本地版本", status: "synced")
        }
    }

    // MARK: push 成功后的快照增量更新（防止自己推的内容被误报为"远端更新"）

    static func snapshotUpsertFood(_ rec: [String: Any]) {
        guard let id = rec["id"] as? Int else { return }
        let raw = snapshotRaw()
        var foods = raw["foods"] as? [String: Any] ?? [:]
        foods[String(id)] = normalizeFood(rec)
        saveSnapshot(foods: foods, quotes: raw["quotes"] as? [String: Any] ?? [:])
    }

    // 批量版：compute() 自愈循环专用——一次全量读改写。逐条调用时每条都是
    // "读整个快照+全量 JSONSerialization 校验+同步写盘"，N 条自愈曾把主线程卡过
    // scene-update 的 10s 死线被 watchdog 击杀（crash-nov11.ips 0x8BADF00D）
    static func snapshotUpsertFoods(_ recs: [[String: Any]]) {
        guard !recs.isEmpty else { return }
        let raw = snapshotRaw()
        var foods = raw["foods"] as? [String: Any] ?? [:]
        for rec in recs {
            if let id = rec["id"] as? Int { foods[String(id)] = normalizeFood(rec) }
        }
        saveSnapshot(foods: foods, quotes: raw["quotes"] as? [String: Any] ?? [:])
    }

    static func snapshotUpsertQuotes(_ quotes: [[String: Any]]) {
        guard !quotes.isEmpty else { return }
        let raw = snapshotRaw()
        var q = raw["quotes"] as? [String: Any] ?? [:]
        for quote in quotes {
            if let id = quote["id"] as? Int { q[String(id)] = normalizeQuote(quote) }
        }
        saveSnapshot(foods: raw["foods"] as? [String: Any] ?? [:], quotes: q)
    }

    static func snapshotPatchFood(id: Int, fields: [String: Any]) {
        let raw = snapshotRaw()
        var foods = raw["foods"] as? [String: Any] ?? [:]
        var existing = foods[String(id)] as? [String: Any] ?? [:]
        for (k, v) in normalizeFood(fields) { existing[k] = v }
        foods[String(id)] = existing
        saveSnapshot(foods: foods, quotes: raw["quotes"] as? [String: Any] ?? [:])
    }

    static func snapshotRemoveFood(id: Int) {
        let raw = snapshotRaw()
        var foods = raw["foods"] as? [String: Any] ?? [:]
        foods.removeValue(forKey: String(id))
        saveSnapshot(foods: foods, quotes: raw["quotes"] as? [String: Any] ?? [:])
    }

    static func snapshotUpsertQuote(_ quote: [String: Any]) {
        guard let id = quote["id"] as? Int else { return }
        let raw = snapshotRaw()
        var quotes = raw["quotes"] as? [String: Any] ?? [:]
        quotes[String(id)] = normalizeQuote(quote)
        saveSnapshot(foods: raw["foods"] as? [String: Any] ?? [:], quotes: quotes)
    }

    static func snapshotRemoveQuote(id: Int) {
        let raw = snapshotRaw()
        var quotes = raw["quotes"] as? [String: Any] ?? [:]
        quotes.removeValue(forKey: String(id))
        saveSnapshot(foods: raw["foods"] as? [String: Any] ?? [:], quotes: quotes)
    }

    // MARK: 展示

    static let fieldLabels = ["name": "名称", "brand_name": "品牌", "price": "价格", "categories": "类别",
                              "ingredients": "原料", "flavors": "味道", "preference": "偏好",
                              "worth_it": "值不值", "comment": "评论", "category_rank": "排名",
                              "image_path": "图片", "image_metadata": "图片信息"]

    static func display(_ v: Any) -> String {
        func truncate(_ s: String) -> String { s.count > 80 ? String(s.prefix(80)) + "…" : s }
        switch v {
        case is NSNull: return "（空）"
        case let s as String: return truncate(s.isEmpty ? "（空）" : s)
        case let n as NSNumber:
            let type = String(cString: n.objCType)
            if type == "c" { return n.boolValue ? "是" : "否" }
            return n.doubleValue == Double(n.intValue) ? String(n.intValue) : String(n.doubleValue)
        case let a as [Any]:
            if let named = a as? [[String: Any]], !named.isEmpty, named.allSatisfy({ $0["name"] is String }) {
                return truncate(named.compactMap { $0["name"] as? String }.joined(separator: "、"))
            }
            return truncate(a.map { display($0) }.joined(separator: " / "))
        case let d as [String: Any]:
            return truncate(d.keys.sorted().map { "\($0): \(display(d[$0]!))" }.joined(separator: ", "))
        default:
            return truncate(String(describing: v))
        }
    }

    // MARK: 私有

    private static func snapshotRaw() -> [String: Any] {
        (OfflineStore.loadJSON(name: snapshotFile) as? [String: Any]) ?? [:]
    }

    private static func snapshotFoods() -> [Int: [String: Any]] {
        var out: [Int: [String: Any]] = [:]
        for (k, v) in (snapshotRaw()["foods"] as? [String: Any]) ?? [:] {
            if let id = Int(k), let rec = v as? [String: Any] { out[id] = rec }
        }
        return out
    }

    private static func snapshotQuotes() -> [Int: [String: Any]] {
        var out: [Int: [String: Any]] = [:]
        for (k, v) in (snapshotRaw()["quotes"] as? [String: Any]) ?? [:] {
            if let id = Int(k), let rec = v as? [String: Any] { out[id] = rec }
        }
        return out
    }

    private static func saveSnapshot(foods: [String: Any], quotes: [String: Any]) {
        OfflineStore.saveJSONSync(["foods": foods, "quotes": quotes], name: snapshotFile)
    }
}

// 冲突记录的队列项：同步引擎重放时跳过（留在队列等手动解决）
extension PendingMutation {
    func isConflicted(_ ids: Set<Int>) -> Bool {
        guard !ids.isEmpty else { return false }
        switch kind {
        case "patch", "delete": return serverId.map { ids.contains($0) } ?? false
        default: return false
        }
    }
}

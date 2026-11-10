import SwiftUI

// 设置 tab（原 UIKit SettingsViewController 移植）：手动同步/修改记录/版本
@MainActor
@Observable
final class SettingsViewModel {
    var syncing = false
    var syncStatus = "检查本地与远端的差异…"
    // git 式差异状态：↑本地待推送 / ↓远端更新 / ⚠冲突；无差异时同步按钮置灰
    var diff = SyncDiffState()
    var showResolver = false
    // 构建号 = CI run 号（CI 注入 CFBundleVersion）；远端号来自 worker /api/version（转发 GitHub latest release）
    let currentBuild: Int
    var remoteBuild: Int?
    var versionStatus = "检查中…"

    init() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        currentBuild = Int(raw) ?? 0
    }

    var pendingCount: Int { OfflineStore.pendingCount() }

    // 最近修改及其到远端的状态（SyncLog）
    var logEntries: [SyncLogEntry] = []
    func refreshLog() { logEntries = SyncLog.entries(limit: 10) }

    // 静默检查远端（git fetch：只存暂存不应用，失败静默保持现状），进入设置页时触发
    func refreshDiff() async {
        guard !syncing else { return }
        await SyncDiff.fetchAndStash()
        recompute()
    }

    func recompute() {
        diff = SyncDiff.compute()
        guard !syncing else { return }
        if !diff.conflicts.isEmpty {
            syncStatus = "有 \(diff.conflicts.count) 条记录两边都有修改，需要解决冲突"
        } else if diff.hasDiff {
            syncStatus = "本地与远端存在差异"
        } else {
            syncStatus = "本地与远端一致，无需同步"
        }
    }

    // 手动同步（git pull --rebase && git push）：先拉取远端合并非冲突变化，再排空离线队列推送；
    // 有冲突则停下来等用户逐条解决，完成后以服务端真值重建快照并广播各页刷新
    func runManualSync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            syncStatus = "正在拉取远端数据…"
            let config = try await AppConfig.load()
            let foods = try await API.getAllFoods(limit: config.maxPageSize)
            let quotes = try await API.getQuotes()
            let quoteItems = quotes["items"] as? [[String: Any]] ?? []
            SyncDiff.initializeSnapshotIfMissing(foods: foods, quotes: quoteItems)
            SyncDiff.stashRemote(foods: foods, quotes: quoteItems)
            SyncDiff.lastStashAt = Date()
            let applied = SyncDiff.applyRemoteChanges()
            recompute()
            if !diff.conflicts.isEmpty {
                syncStatus = "有 \(diff.conflicts.count) 条记录两边都有修改，需要解决冲突"
                showResolver = true
                return
            }
            syncStatus = applied > 0 ? "已合并远端 \(applied) 条变化，正在上传本地修改…" : "正在上传本地修改…"
            try await pushAndFinalize()
        } catch {
            syncStatus = "同步失败：\(error.localizedDescription)"
        }
    }

    // 冲突全部解决后续跑：推送 + 最终拉取
    func afterResolved() async {
        guard !syncing, diff.conflicts.isEmpty else { return }
        syncing = true
        defer { syncing = false }
        do {
            syncStatus = "正在上传本地修改…"
            try await pushAndFinalize()
        } catch {
            syncStatus = "同步失败：\(error.localizedDescription)"
        }
    }

    // 冲突解决（整条二选一）；全解完自动继续同步
    func resolve(_ conflict: FoodConflict, choice: SyncDiff.Resolution) {
        SyncDiff.resolve(conflict, choice: choice)
        recompute()
        if diff.conflicts.isEmpty, showResolver {
            showResolver = false
            Task { await afterResolved() }
        }
    }

    // 推送离线队列，再以服务端真值收尾；推送失败也尽力拉取（失败项留队列，状态显示部分失败）
    private func pushAndFinalize() async throws {
        var drainError: Error?
        do { try await SyncEngine.drain() } catch { drainError = error }
        let config = try await AppConfig.load()
        let foods = try await API.getAllFoods(limit: config.maxPageSize)
        let quotes = try await API.getQuotes()
        let quoteItems = quotes["items"] as? [[String: Any]] ?? []
        let cats = try await API.getCategories()
        OfflineStore.rebuildRecords(foods)
        OfflineStore.saveCategories(cats["items"] as? [[String: Any]] ?? [])
        OfflineStore.rebuildQuotes(quoteItems)
        SyncDiff.rebuildSnapshot(foods: foods, quotes: quoteItems)
        SyncDiff.clearStash()
        RemoteImageModel.shared.clearCache() // 图片缓存一并作废，配合广播让可见图重拉
        NotificationCenter.default.post(name: .myfoodDataSynced, object: nil)
        recompute()
        refreshLog() // 重放后待上传项已翻成已到远端/失败
        if let e = drainError {
            syncStatus = "部分上传失败：\(e.localizedDescription)"
        } else {
            syncStatus = "同步完成，本地与远端一致"
        }
    }

    // 检查更新：测试会话跳过（fixture 拦截不到 GitHub 语义，且保持冒烟截图确定）
    func checkVersion() async {
        guard !SmokeTour.enabled, !AutoTest.enabled else {
            versionStatus = "测试构建 \(currentBuild)"
            return
        }
        do {
            let build = try await API.getLatestBuild()
            remoteBuild = build
            if currentBuild == 0 {
                versionStatus = "远端 ipa-\(build)（本地构建号缺失，建议更新）"
            } else if build > currentBuild {
                versionStatus = "远端有新版本 ipa-\(build)，建议更新"
            } else {
                versionStatus = "已是最新版本"
            }
        } catch {
            versionStatus = "远端版本获取失败"
        }
    }
}

struct SettingsView: View {
    @State private var model = SettingsViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                syncCard
                logCard
                versionCard
                Spacer()
            }
            .padding(20)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.recompute()
            model.refreshLog() // 其他页的写操作回来时刷新状态
        }
        .task { await model.refreshDiff() } // 静默拉取远端，刷新 ↑/↓/⚠ 状态
    }

    private var syncCard: some View {
        @Bindable var model = model
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("手动同步").font(.system(size: 15, weight: .bold))
                Text(model.syncStatus).font(.system(size: 13)).foregroundStyle(.secondary)
                if model.diff.hasDiff, !model.syncing {
                    Text(diffSummary)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
            }
            Spacer()
            syncButton
        }
        .padding(14)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $model.showResolver) {
            ConflictResolverSheet(model: model)
        }
    }

    private var diffSummary: String {
        var parts: [String] = []
        if model.diff.pendingCount > 0 { parts.append("↑\(model.diff.pendingCount) 待推送") }
        if model.diff.remoteChangeCount > 0 { parts.append("↓\(model.diff.remoteChangeCount) 远端更新") }
        if !model.diff.conflicts.isEmpty { parts.append("⚠\(model.diff.conflicts.count) 冲突") }
        return parts.joined(separator: " · ")
    }

    // 三态：无差异灰色禁用 / 有差异可同步 / 有冲突先解决
    @ViewBuilder
    private var syncButton: some View {
        if model.syncing {
            pillButton("同步中…", background: Theme.primary.opacity(0.6), action: {})
                .disabled(true)
        } else if !model.diff.conflicts.isEmpty {
            pillButton("解决冲突 (\(model.diff.conflicts.count))", background: Theme.primary) {
                model.showResolver = true
            }
        } else if model.diff.hasDiff {
            pillButton("同步", background: Theme.primary) {
                Task { await model.runManualSync() }
            }
        } else {
            pillButton("已是最新", background: Color(white: 0.85), action: {})
                .disabled(true)
        }
    }

    private func pillButton(_ title: String, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // 修改记录：每次写操作一行，标明是否已到远端数据库
    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("修改记录").font(.system(size: 15, weight: .bold))
            if model.logEntries.isEmpty {
                Text("暂无修改记录").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                ForEach(model.logEntries) { e in logRow(e) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))
    }

    private func logRow(_ e: SyncLogEntry) -> some View {
        var icon: String; var color: Color; var status: String
        switch e.status {
        case "synced": (icon, color, status) = ("checkmark.circle.fill", .green, "已到远端")
        case "pending": (icon, color, status) = ("clock", .orange, "待上传")
        case "failed": (icon, color, status) = ("exclamationmark.circle.fill", .red, "失败")
        default: (icon, color, status) = ("minus.circle", .gray, "已撤销")
        }
        var main = "\(timeText(e.time))  \(e.kindLabel)「\(e.target)」"
        if !e.detail.isEmpty { main += " · \(e.detail)" }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(main).font(.system(size: 13)).foregroundStyle(.primary)
                if let err = e.error {
                    Text(err).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(status).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
        }
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }

    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("版本").font(.system(size: 15, weight: .bold))
            Text(versionLine).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(model.versionStatus).font(.system(size: 13)).foregroundStyle(Theme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))
        .task { await model.checkVersion() }
    }

    private var versionLine: String {
        var parts = ["当前构建 \(model.currentBuild)"]
        if let remote = model.remoteBuild { parts.append("远端 ipa-\(remote)") }
        return parts.joined(separator: " · ")
    }
}

// 冲突解决：逐条整选本地/远端版本，可展开字段差异明细；取消则保留冲突状态稍后再处理
struct ConflictResolverSheet: View {
    let model: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("以下记录本地和远端都有修改，请为每条选择保留哪个版本。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    ForEach(model.diff.conflicts) { conflict in
                        ConflictRow(conflict: conflict) { c, choice in
                            model.resolve(c, choice: choice)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("解决冲突")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

struct ConflictRow: View {
    let conflict: FoodConflict
    let onResolve: (FoodConflict, SyncDiff.Resolution) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Text(conflict.name).font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
                    Spacer()
                    Text("本地\(conflict.localKind) · 远端\(conflict.remoteKind)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if expanded, !conflict.fields.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(conflict.fields) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(SyncDiff.fieldLabels[f.key] ?? f.key)
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Text("本地：\(f.local)").font(.system(size: 12))
                            Text("远端：\(f.remote)").font(.system(size: 12)).foregroundStyle(Theme.primary)
                        }
                    }
                }
                .padding(8)
                .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                Button { onResolve(conflict, .local) } label: {
                    Text("用本地版本")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.primary, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                Button { onResolve(conflict, .remote) } label: {
                    Text("用远端版本")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(12)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 10))
    }
}

import SwiftUI

// 设置 tab（原 UIKit SettingsViewController 移植）：后端/定位说明/手动同步/离线能力
@MainActor
@Observable
final class SettingsViewModel {
    var syncing = false
    var syncStatus = "把离线修改上传，并拉取服务端最新数据"
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

    func syncIfNeededText() {
        syncStatus = pendingCount > 0 ? "有 \(pendingCount) 条离线修改待上传" : "把离线修改上传，并拉取服务端最新数据"
    }

    // 手动同步：先排空离线队列（上传），再拉取服务端最新数据；完成后广播让各页刷新
    func runManualSync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await SyncEngine.drain()
            let config = try await AppConfig.load()
            let foods = try await API.getAllFoods(limit: config.maxPageSize)
            OfflineStore.rebuildRecords(foods)
            let cats = try await API.getCategories()
            OfflineStore.saveCategories(cats["items"] as? [[String: Any]] ?? [])
            let quotes = try await API.getQuotes()
            OfflineStore.rebuildQuotes(quotes["items"] as? [[String: Any]] ?? [])
            RemoteImageModel.shared.clearCache() // 图片缓存一并作废，配合广播让可见图重拉
            NotificationCenter.default.post(name: .myfoodDataSynced, object: nil)
            syncStatus = "同步完成"
            refreshLog() // 重放后待上传项已翻成已到远端/失败
        } catch {
            syncStatus = "同步失败：\(error.localizedDescription)"
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
                infoCard("后端", BASE_URL)
                infoCard("定位说明", "轨迹默认自动记录：启动后请在系统弹窗中选择「允许」，并设为「始终允许」可锁屏持续记录")
                syncCard
                logCard
                versionCard
                infoCard("离线能力", "断网时可浏览缓存数据；建档/编辑/删除/换图/排名/摘抄会本地保存，恢复联网后自动同步")
                Spacer()
            }
            .padding(20)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.syncIfNeededText()
            model.refreshLog() // 其他页的写操作回来时刷新状态
        }
    }

    private var syncCard: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("手动同步").font(.system(size: 15, weight: .bold))
                Text(model.syncStatus).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.runManualSync() }
            } label: {
                Text(model.syncing ? "同步中…" : "同步")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.primary, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.syncing)
        }
        .padding(14)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))
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

    private func infoCard(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .bold))
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))
    }
}

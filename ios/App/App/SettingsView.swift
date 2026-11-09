import SwiftUI

// 设置 tab（原 UIKit SettingsViewController 移植）：后端/定位说明/手动同步/离线能力
@MainActor
@Observable
final class SettingsViewModel {
    var syncing = false
    var syncStatus = "把离线修改上传，并拉取服务端最新数据"

    var pendingCount: Int { OfflineStore.pendingCount() }

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
            NotificationCenter.default.post(name: .myfoodDataSynced, object: nil)
            syncStatus = "同步完成"
        } catch {
            syncStatus = "同步失败：\(error.localizedDescription)"
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
                infoCard("离线能力", "断网时可浏览缓存数据；建档/编辑/删除/换图/排名/摘抄会本地保存，恢复联网后自动同步")
                Spacer()
            }
            .padding(20)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.syncIfNeededText() }
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

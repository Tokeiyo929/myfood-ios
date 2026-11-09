import SwiftUI

// 摘抄 tab（原 UIKit QuotesViewController 移植）：好词好句，离线增删、联网自动同步
@MainActor
@Observable
final class QuotesViewModel {
    var quotes: [[String: Any]] = []
    var input = ""
    var loaded = false
    var needsLoad = true
    var toast: String?

    func onAppear() {
        guard needsLoad else { return }
        needsLoad = false
        Task { await load() }
    }

    func load() async {
        do {
            let r = try await API.getQuotes()
            let items = r["items"] as? [[String: Any]] ?? []
            OfflineStore.rebuildQuotes(items)
            reloadFromCache()
            loaded = true
        } catch {
            guard isNetworkError(error) else { loaded = true; toast = error.localizedDescription; return }
            let cached = OfflineStore.cachedQuotes()
            if !cached.isEmpty {
                reloadFromCache()
                loaded = true
                toast = "离线数据（可能不是最新）"
            } else {
                loaded = true
                toast = "加载失败，请检查网络"
            }
        }
    }

    private func reloadFromCache() {
        quotes = OfflineStore.cachedQuotes()
    }

    func save() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { toast = "先写点什么"; return }
        Task {
            let clientKey = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + "-" + String(Int.random(in: 0..<1_000_000), radix: 36)
            do {
                let res = try await API.createQuote(text: text, note: "", clientKey: clientKey)
                let id = res["id"] as! Int
                OfflineStore.upsertQuote(["id": id, "text": text, "note": "", "day": OfflineStore.todayString()])
                SyncLog.append(kind: "quoteCreate", target: String(text.prefix(12)), status: "synced")
                input = ""
                reloadFromCache()
                toast = "已保存"
            } catch {
                guard isNetworkError(error) else {
                    SyncLog.append(kind: "quoteCreate", target: String(text.prefix(12)), status: "failed", error: error.localizedDescription)
                    toast = error.localizedDescription
                    return
                }
                // 断网摘抄：本地负数 id 记录 + 入队，恢复联网自动上传
                let localId = OfflineStore.allocateLocalQuoteId()
                OfflineStore.upsertQuote(["id": localId, "text": text, "note": "", "day": OfflineStore.todayString(), "client_key": clientKey])
                let payload: [String: Any] = ["text": text, "note": "", "client_key": clientKey]
                let uuid = OfflineStore.enqueue(.quoteCreate(record: payload, clientKey: clientKey, localId: localId))
                SyncLog.append(kind: "quoteCreate", target: String(text.prefix(12)), status: "pending", linkUUID: uuid)
                input = ""
                reloadFromCache()
                toast = "已离线保存，联网后自动同步"
            }
        }
    }

    func delete(_ quote: [String: Any]) {
        guard let id = quote["id"] as? Int else { return }
        let label = String((quote["text"] as? String ?? "").prefix(12))
        if id < 0 {
            guard let key = quote["client_key"] as? String else { return }
            for uuid in OfflineStore.cancelPendingQuoteCreate(clientKey: key) {
                SyncLog.mark(uuid: uuid, status: "cancelled")
            }
            OfflineStore.removeQuote(id: id)
            reloadFromCache()
            toast = "已删除"
            return
        }
        Task {
            do {
                _ = try await API.deleteQuote(id)
                SyncLog.append(kind: "quoteDelete", target: label, status: "synced")
                OfflineStore.removeQuote(id: id)
            } catch {
                guard isNetworkError(error) else {
                    SyncLog.append(kind: "quoteDelete", target: label, status: "failed", error: error.localizedDescription)
                    toast = error.localizedDescription
                    return
                }
                let uuid = OfflineStore.enqueue(.quoteDelete(serverId: id))
                SyncLog.append(kind: "quoteDelete", target: label, status: "pending", linkUUID: uuid)
                OfflineStore.removeQuote(id: id)
                toast = "已离线删除，联网后同步"
            }
            reloadFromCache()
        }
    }
}

struct QuotesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.quotes
        VStack(spacing: 0) {
            List {
                if vm.quotes.isEmpty {
                    Text(vm.loaded ? "还没有摘抄，记下第一句吧" : "加载中…")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.quotes.indices, id: \.self) { idx in
                    let q = vm.quotes[idx]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(q["text"] as? String ?? "")
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(q["day"] as? String ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { vm.delete(q) } label: { Text("删除") }
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $vm.input)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60, maxHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.85)))
                    if vm.input.isEmpty {
                        Text("记下一句打动你的话…").font(.system(size: 14)).foregroundStyle(Color(.placeholderText)).padding(10)
                    }
                }
                Button { vm.save() } label: {
                    Text("保存")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 60)
                        .background(Theme.primary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .padding(.top, 4)
        }
        .navigationTitle("摘抄")
        .navigationBarTitleDisplayMode(.inline)
        .toast($vm.toast)
        .onAppear { vm.onAppear() }
        .onReceive(NotificationCenter.default.publisher(for: .myfoodDataSynced)) { _ in
            Task { await vm.load() }
        }
    }
}

import SwiftUI
import PhotosUI

// 历史 tab：搜索 + 分页卡片列表 + 拍照/相册快速建档（原 UIKit HistoryViewController 移植）
@MainActor
@Observable
final class HistoryViewModel {
    var records: [DecoratedRecord] = []
    var search = ""
    var page = 1
    var hasMore = true
    var loading = false
    var loaded = false
    var needsRefresh = true
    var toast: String?
    var showingCamera = false
    var showingPhotoPicker = false
    var pickedItem: PhotosPickerItem?
    var smokeAddState = "idle"
    var recordIDs: [Int] { records.map { $0.id } }
    private var searchTask: Task<Void, Never>?
    private var generation = 0

    func onSearchChange(_ text: String) {
        search = text // VM 自包含：直接调用（冒烟/自测）与输入绑定两条路径都生效
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await loadRecords(reset: true)
        }
    }

    func onAppear() {
        guard needsRefresh else { return }
        needsRefresh = false
        Task { await loadRecords(reset: true) }
    }

    func loadRecords(reset: Bool) async {
        if !reset && loading { return }
        generation += 1
        let requestGeneration = generation
        let query = search
        loading = true
        let reqPage = reset ? 1 : page + 1
        defer {
            if requestGeneration == generation { loading = false }
        }
        var limit = 10
        do {
            let config = try await AppConfig.load()
            limit = config.pageSize
            let r = try await API.getFoods(page: reqPage, limit: limit, search: query)
            guard requestGeneration == generation else { return }
            let items = r["items"] as! [[String: Any]]
            let total = r["total"] as! Int
            OfflineStore.mergeRecords(items)
            apply(items: items, reset: reset, reqPage: reqPage, total: total)
            loaded = true
        } catch {
            guard requestGeneration == generation else { return }
            guard isNetworkError(error) else { toast = error.localizedDescription; return }
            // 断网兜底：本地缓存过滤 + 本地分页
            let cached = OfflineStore.searchRecords(query)
            let slice = Array(cached.dropFirst((reqPage - 1) * limit).prefix(limit))
            guard !cached.isEmpty else { toast = error.localizedDescription; return }
            apply(items: slice, reset: reset, reqPage: reqPage, total: cached.count)
            loaded = true
            toast = "离线数据（可能不是最新）"
        }
    }

    private func apply(items: [[String: Any]], reset: Bool, reqPage: Int, total: Int) {
        let decorated = items.map { RecordDecorator.decorate($0) }
        records = reset ? decorated : records + decorated
        page = reqPage
        hasMore = records.count < total
    }

    func loadMoreIfNeeded(_ record: DecoratedRecord) {
        guard hasMore, !loading, record.id == records.last?.id else { return }
        Task { await loadRecords(reset: false) }
    }

    // MARK: 快速建档（拍照/相册）：上传与定位并行；断网走本地建档队列

    func handlePickedItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        pickedItem = nil
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                quickAdd(image: image)
            }
        }
    }

    func quickAdd(image: UIImage) {
        toast = "上传中…"
        smokeAddState = "running"
        Task {
            do {
                let config = try await AppConfig.load()
                guard let jpeg = image.resized(maxDimension: CGFloat(config.imageMaxDimension))
                    .jpegData(compressionQuality: config.imageQuality) else { throw APIError(message: "图片编码失败") }
                async let uploadTask = API.uploadImage(jpegData: jpeg)
                async let locTask = LocationOnce.fetch()
                let loc = await locTask
                var meta: [String: Any] = ["taken_at": nowTakenAt()]
                if let loc {
                    meta["latitude"] = loc.lat
                    meta["longitude"] = loc.lng
                }
                var record: [String: Any] = [
                    "name": "", "brand_name": "", "price": NSNull(), "categories": [], "ingredients": [], "flavors": [],
                    "preference": config.defaultPreference, "comment": [],
                    "image_metadata": meta,
                    "client_key": UUID().uuidString,
                ]
                do {
                    let upload = try await uploadTask
                    if let exif = upload["metadata"] as? [String: Any] {
                        meta.merge(exif) { local, _ in local }
                    }
                    record["image_path"] = upload["path"] as! String
                    record["image_metadata"] = meta
                    _ = try await API.submitFood(record)
                } catch {
                    guard isNetworkError(error) else { throw error }
                    offlineAdd(jpeg: jpeg, record: record)
                    return
                }
                toast = "已保存"
                await loadRecords(reset: true)
                smokeAddState = "saved"
            } catch {
                smokeAddState = "failed: \(error.localizedDescription)"
                toast = error.localizedDescription
            }
        }
    }

    // 断网建档：原图落盘 + 本地负数 id 记录（置顶展示）+ 入队；上传用 client_key 幂等
    private func offlineAdd(jpeg: Data, record: [String: Any]) {
        let imagePath = OfflineStore.saveLocalImage(jpeg)
        let clientKey = record["client_key"] as! String
        let localId = OfflineStore.allocateLocalId()
        var payload = record
        payload["image_path"] = imagePath
        OfflineStore.enqueue(.create(record: payload, clientKey: clientKey, localId: localId, localImage: imagePath))
        var localRecord = payload
        localRecord["id"] = localId
        localRecord["modify_at"] = [OfflineStore.todayString()]
        OfflineStore.upsertRecord(localRecord)
        smokeAddState = "offline-saved"
        toast = "已离线保存，联网后自动同步"
        reloadFromCache()
    }

    private func reloadFromCache() {
        let cached = OfflineStore.searchRecords(search)
        let limit = AppConfig.shared?.pageSize ?? 10
        apply(items: Array(cached.prefix(limit)), reset: true, reqPage: 1, total: cached.count)
        loaded = true
    }

    // 冒烟巡访用：不经过相册 UI，直接走 quickAdd 全流程（fixture 服务端）
    func smokeQuickAdd() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
        quickAdd(image: renderer.image { UIColor.systemRed.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 40, height: 40)) })
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var vm = app.history
        NavigationStack(path: $app.historyPath) {
            VStack(spacing: 0) {
                searchField
                recordList
            }
            .background(Theme.listBackground)
            .navigationTitle("历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("从相册选") { vm.showingPhotoPicker = true }.font(.system(size: 15))
                    Button("拍照") { vm.showingCamera = true }.font(.system(size: 15))
                }
            }
            .navigationDestination(for: Int.self) { recordId in
                DetailView(recordId: recordId)
            }
            .toast($vm.toast)
            .onAppear { vm.onAppear() }
            .onChange(of: vm.search) { _, newValue in vm.onSearchChange(newValue) }
            .photosPicker(isPresented: $vm.showingPhotoPicker, selection: $vm.pickedItem, matching: .images)
            .onChange(of: vm.pickedItem) { _, item in vm.handlePickedItem(item) }
            .fullScreenCover(isPresented: $vm.showingCamera) {
                CameraPicker { image in vm.quickAdd(image: image) }
                    .ignoresSafeArea()
            }
        }
    }

    private var searchField: some View {
        @Bindable var vm = app.history
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索名称/品牌", text: $vm.search)
                .font(.system(size: 15))
            if !vm.search.isEmpty {
                Button { vm.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var recordList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if app.history.records.isEmpty {
                    Text(app.history.loading ? "加载中…" : "暂无记录")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
                ForEach(app.history.records, id: \.id) { record in
                    NavigationLink(value: record.id) {
                        RecordCardView(record: record)
                    }
                    .buttonStyle(.plain)
                    .onAppear { app.history.loadMoreIfNeeded(record) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .refreshable { await app.history.loadRecords(reset: true) }
        .scrollDismissesKeyboard(.interactively)
    }
}

// UIImage 压缩（原 UIImage ext 移植）
extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let m = max(size.width, size.height)
        guard m > maxDimension, size.width > 0, size.height > 0 else { return self }
        let scale = maxDimension / m
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

// 系统相机（SwiftUI 无相机原生组件；仅此一处系统封装，相册已用 PhotosPicker）
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

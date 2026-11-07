import SwiftUI
import Vision

// 详情页（原 UIKit DetailViewController + OcrViewController 移植）：
// 图片横条（今日记录，点选切换/长按换图）+ 基本信息编辑 + 味道轮盘 + 偏好条
// + 评论（增删改）+ 原料 chips + 保存/删除 + 语音 + OCR 划选
@MainActor
@Observable
final class DetailViewModel {
    var recordId = 0
    var loaded = false
    var needsLoad = false
    var toast: String?
    var saving = false

    // 表单态
    var name = ""
    var brandName = ""
    var priceOrig = ""
    var priceDisc = ""
    var currentRepurchase = 0
    var prevRecordLabel = ""
    var worthIt = "" // "" / "yes" / "no"
    var selectedCategory = ""
    var categorySearch = ""
    var categorySuggestions: [String] = []
    var ingredients: [[String: Any]] = []
    var ingredientSearch = ""
    var ingredientAmount = ""
    var comments: [String] = []
    var editingCommentIndex: Int?
    var commentInput = ""
    var flavorLevels: [String: Int] = [:]
    var currentPref: (value: String, label: String, face: String, level: Int)?
    var recording = false

    // 横条
    var stripRecords: [[String: Any]] = []
    var allCategories: [String] = []

    // 相册/相机/OCR
    var showingPhotoPicker = false
    var showingCamera = false
    var pickedItem: PhotosPickerItem?
    var cameraMode: CameraMode = .replace
    var ocrVM: OCRViewModel?
    var ocrPresented = false

    enum CameraMode { case replace, ocr }

    var canSave: Bool { loaded && !saving && currentPref != nil }
    var worthDisplay: (yes: Bool, no: Bool) { (worthIt == "yes", worthIt == "no") }

    private var voiceBase = ""
    let voice = VoiceManager()
    private var draft = CommentDraft()

    func flavorName(_ name: String, level: Int) -> String {
        guard let c = AppConfig.shared else { return name }
        return Self.flavorLabel(name, level: level, scale: c.flavorScale)
    }

    static func flavorLabel(_ name: String, level: Int, scale: [String: Int]) -> String {
        guard let low = scale["low"], let mid = scale["mid"], let high = scale["high"] else { return name }
        if level < low { return "不" + name }
        if level < mid { return "微" + name }
        if level < high { return name }
        return "太" + name
    }

    func open(recordId: Int) {
        guard self.recordId != recordId || !loaded else { return }
        self.recordId = recordId
        loaded = false
        needsLoad = true
    }

    func onAppear() {
        guard needsLoad else { return }
        needsLoad = false
        Task { await loadAll() }
        voice.onText = { [weak self] text in
            guard let self else { return }
            commentInput = voiceBase + text
        }
        voice.onFail = { [weak self] msg in
            guard let self else { return }
            recording = false
            toast = msg
        }
        voice.onRecordingChange = { [weak self] rec in self?.recording = rec }
    }

    func stopVoice() {
        voice.stop()
        recording = false
    }

    // MARK: - 数据

    func loadAll() async {
        var strip: [[String: Any]] = []
        var cats: [[String: Any]] = []
        var haveStrip = false
        var haveCats = false
        do {
            let config = try await AppConfig.load()
            strip = try await API.getAllFoods(limit: config.maxPageSize, today: true)
            haveStrip = true
            if !strip.contains(where: { ($0["id"] as? Int) == recordId }) {
                strip.insert(try await API.getFoodById(recordId), at: 0)
            }
            OfflineStore.mergeRecords(strip)
            let c = try await API.getCategories()
            cats = (c["items"] as? [[String: Any]]) ?? []
            haveCats = true
            OfflineStore.saveCategories(cats)
        } catch {}
        let haveRecord = strip.contains(where: { ($0["id"] as? Int) == recordId })
        if !haveStrip || !haveCats || !haveRecord {
            // 断网兜底：今天缓存 + 目标记录 + 类别缓存
            var cached = OfflineStore.cachedRecords().filter { OfflineStore.isToday($0) }
            if let rec = OfflineStore.record(id: recordId),
               !cached.contains(where: { ($0["id"] as? Int) == recordId }) {
                cached.insert(rec, at: 0)
            }
            if cached.contains(where: { ($0["id"] as? Int) == recordId }) {
                strip = cached
                cats = OfflineStore.cachedCategories()
                haveStrip = true
                haveCats = true
            }
        }
        guard haveStrip, haveCats else {
            toast = "加载失败，请检查网络"
            return
        }
        stripRecords = strip
        allCategories = cats.compactMap { $0["name"] as? String }
        fill(stripRecords.first { ($0["id"] as? Int) == recordId })
        loaded = true
    }

    private func fill(_ f: [String: Any]?) {
        guard let f else { toast = "加载失败"; return }
        name = f["name"] as? String ?? ""
        brandName = f["brand_name"] as? String ?? ""
        let price = f["price"] as? [Any?]
        priceOrig = (price?.count ?? 0) > 0 ? num(price?[0]) : ""
        priceDisc = (price?.count ?? 0) > 1 ? num(price?[1]) : ""
        currentRepurchase = f["repurchase"] as? Int ?? 0
        prevRecordLabel = Self.prevRecordLabel(f["modify_at"] as? [String])
        worthIt = Self.parseWorth(f["worth_it"])
        selectedCategory = (f["categories"] as? [String])?.first ?? ""
        ingredients = f["ingredients"] as? [[String: Any]] ?? []
        draft = CommentDraft(comments: f["comment"] as? [String] ?? [])
        editingCommentIndex = nil
        commentInput = ""
        categorySearch = ""
        categorySuggestions = []
        if let c = AppConfig.shared {
            flavorLevels = [:]
            c.flavors.forEach { flavorLevels[$0] = c.flavorScale["default"]! }
            if let fl = f["flavors"] as? [[String: Any]] {
                fl.forEach { fv in
                    if let name = fv["name"] as? String, let lv = fv["level"] as? Int { flavorLevels[name] = lv }
                }
            }
            let prefVal = f["preference"] as? String
            currentPref = c.preferences.first { $0.value == prefVal }
            if currentPref == nil { toast = "偏好值无效，请重新选择" }
        }
    }

    private func num(_ v: Any?) -> String {
        guard let n = v as? NSNumber else { return "" }
        return n.stringValue
    }

    // 可测：worker 存的是 "yes"/"no" 字符串，兼容历史 bool/NSNumber
    static func parseWorth(_ v: Any?) -> String {
        if let s = v as? String { return s == "yes" || s == "true" ? "yes" : s == "no" || s == "false" ? "no" : "" }
        if let b = v as? Bool { return b ? "yes" : "no" }
        if let n = v as? NSNumber { return n.boolValue ? "yes" : "no" }
        return ""
    }

    static func prevRecordLabel(_ modifyAt: [String]?) -> String {
        guard let m = modifyAt, m.count >= 2 else { return "" }
        let base = m[m.count - 2]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: base) else { return base }
        let cal = Calendar.current
        let diff = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        if diff == 1 { return "上次记录：\(base) (昨天)" }
        if diff == 2 { return "上次记录：\(base) (前天)" }
        return "上次记录：\(base)"
    }

    // MARK: - 横条切换 / 类别 / 原料

    func selectRecord(_ id: Int) {
        guard id != recordId else { return }
        recordId = id
        fill(stripRecords.first { ($0["id"] as? Int) == id })
    }

    func onCategorySearch(_ q: String) {
        categorySearch = q
        let selected = selectedCategory
        categorySuggestions = q.isEmpty ? [] : allCategories.filter { $0 != selected && $0.lowercased().contains(q.lowercased()) }.prefix(8).map { $0 }
    }

    func pickCategory(_ name: String) {
        selectedCategory = name
        categorySearch = ""
        categorySuggestions = []
    }

    var ingredientPreview: (name: String, amount: String)? {
        let n = ingredientSearch.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        return (n, ingredientAmount)
    }

    func confirmIngredient() {
        guard let p = ingredientPreview else { return }
        doConfirmIngredient(named: p.name, amount: p.amount.isEmpty ? nil : NSNumber(value: Double(p.amount) ?? 0))
    }

    func doConfirmIngredient(named n: String, amount: NSNumber?) {
        Task {
            do {
                do {
                    _ = try await API.addIngredient(n)
                } catch {
                    // 全局原料词典入队离线补传；记录字段本身照常追加
                    guard isNetworkError(error) else { throw error }
                    OfflineStore.enqueue(.ingredient(n))
                    toast = "已离线保存，联网后自动同步"
                }
                var item: [String: Any] = ["name": n]
                if let a = amount { item["amount"] = a }
                ingredients.append(item)
                ingredientSearch = ""
                ingredientAmount = ""
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    func removeIngredient(_ name: String) {
        if let idx = ingredients.firstIndex(where: { ($0["name"] as? String) == name }) {
            ingredients.remove(at: idx)
        }
    }

    // MARK: - 评论

    func editComment(_ idx: Int) {
        guard comments.indices.contains(idx) else { return }
        commentInput = comments[idx]
        editingCommentIndex = idx
    }

    func deleteComment(_ idx: Int) {
        guard comments.indices.contains(idx) else { return }
        let deletingEdited = editingCommentIndex == idx
        draft.remove(at: idx)
        comments = draft.comments
        if deletingEdited {
            commentInput = ""
            editingCommentIndex = nil
        }
    }

    // MARK: - 保存（镜像服务端 PATCH 语义；断网入队+乐观更新）

    func saveDetail() {
        guard canSave, let f = stripRecords.first(where: { ($0["id"] as? Int) == recordId }), let c = AppConfig.shared else { return }
        guard let preference = currentPref?.value else { toast = "请选择有效偏好"; return }
        let text = commentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let newComments: [String]
        do { newComments = try draft.applying(text) }
        catch { toast = error.localizedDescription; return }

        let flavors: [[String: Any]] = c.flavors.map { ["name": $0, "level": flavorLevels[$0]!] }
        var price: Any = NSNull()
        let o = priceOrig.trimmingCharacters(in: .whitespaces)
        let dsc = priceDisc.trimmingCharacters(in: .whitespaces)
        if !o.isEmpty || !dsc.isEmpty {
            var orig: Any = NSNull()
            var disc: Any = NSNull()
            if !o.isEmpty {
                guard let ov = Double(o), ov >= 0 else { toast = "价格无效"; return }
                orig = NSNumber(value: ov)
            }
            if !dsc.isEmpty {
                guard let dv = Double(dsc), dv >= 0 else { toast = "价格无效"; return }
                disc = NSNumber(value: dv)
            }
            price = [orig, disc]
        }
        let fields: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "brand_name": brandName.trimmingCharacters(in: .whitespaces),
            "price": price,
            "categories": selectedCategory.isEmpty ? [] : [selectedCategory],
            "ingredients": ingredients,
            "flavors": flavors,
            "preference": preference,
            "worth_it": worthIt == "" ? NSNull() : NSNumber(value: worthIt == "yes"),
            "comment": newComments,
        ]
        let id = f["id"] as! Int
        saving = true
        Task {
            defer { saving = false }
            // 本地未同步记录：不发网络请求，直接入队（create 同步成功后自动改写为服务端 id）
            if id < 0 {
                if let key = f["client_key"] as? String {
                    OfflineStore.enqueue(.patchLocal(clientKey: key, fields: fields))
                }
                applyLocalSave(fields, base: f, newComments: newComments)
                toast = "已离线保存，联网后自动同步"
                return
            }
            do {
                _ = try await API.updateFoodDetails(id, fields: fields)
                applyLocalSave(fields, base: f, newComments: newComments)
                toast = "保存成功"
            } catch {
                guard isNetworkError(error) else { toast = error.localizedDescription; return }
                // 断网保存：入队 + 本地乐观更新（含 modify_at/复购，镜像服务端 PATCH 行为）
                OfflineStore.enqueue(.patch(serverId: id, fields: fields))
                applyLocalSave(fields, base: f, newComments: newComments)
                toast = "已离线保存，联网后自动同步"
            }
        }
    }

    // 保存后的本地应用（在线/离线共用）：刷新表单态 + 横条 + 磁盘缓存
    private func applyLocalSave(_ fields: [String: Any], base f: [String: Any], newComments: [String]) {
        comments = newComments
        editingCommentIndex = nil
        commentInput = ""
        var updated = f
        for (k, v) in fields { updated[k] = v }
        var dates = updated["modify_at"] as? [String] ?? []
        let today = OfflineStore.todayString()
        if dates.last != today { dates.append(today) }
        updated["modify_at"] = dates
        updated["repurchase"] = max(0, dates.count - 1)
        OfflineStore.upsertRecord(updated)
        currentRepurchase = updated["repurchase"] as? Int ?? 0
        prevRecordLabel = Self.prevRecordLabel(updated["modify_at"] as? [String])
        if let i = stripRecords.firstIndex(where: { ($0["id"] as? Int) == updated["id"] as? Int }) {
            for (k, v) in fields { stripRecords[i][k] = v }
        }
        refreshDependents()
    }

    func deleteCurrent() {
        let id = recordId
        Task {
            do {
                _ = try await API.deleteFood(id)
                OfflineStore.removeRecord(id: id)
                toast = "已删除"
                markDeletedAndPop()
            } catch {
                guard isNetworkError(error) else { toast = error.localizedDescription; return }
                if id > 0 {
                    OfflineStore.enqueue(.delete(serverId: id))
                    OfflineStore.removeRecord(id: id)
                } else if let key = stripRecords.first(where: { ($0["id"] as? Int) == id })?["client_key"] as? String {
                    OfflineStore.cancelPendingCreate(clientKey: key)
                    OfflineStore.removeRecord(id: id)
                }
                toast = "已离线删除，联网后同步"
                markDeletedAndPop()
            }
        }
    }

    private func markDeletedAndPop() {
        stripRecords.removeAll { ($0["id"] as? Int) == recordId }
        loaded = false
        needsLoad = false
        recordId = 0
        refreshDependents()
        AppModel.shared.historyPath.removeAll()
    }

    private func refreshDependents() {
        AppModel.shared.history.needsRefresh = true
        AppModel.shared.foodMap.needsRefresh = true
    }

    // MARK: - 换图（横条长按）：在线上传 / 断网落盘入队

    func replaceImage(_ image: UIImage) {
        let id = recordId
        Task {
            var jpeg: Data?
            do {
                let config = try await AppConfig.load()
                guard let data = image.resized(maxDimension: CGFloat(config.imageMaxDimension))
                    .jpegData(compressionQuality: config.imageQuality) else { throw APIError(message: "图片编码失败") }
                jpeg = data
                var meta: [String: Any] = ["taken_at": nowTakenAt()]
                if let loc = await LocationOnce.fetch() {
                    meta["latitude"] = loc.lat
                    meta["longitude"] = loc.lng
                }
                if id < 0 {
                    replaceOffline(data, meta: meta)
                    return
                }
                let upload = try await API.uploadImage(jpegData: data)
                var upMeta = upload["metadata"] as? [String: Any] ?? [:]
                if let taken = meta["taken_at"] { upMeta["taken_at"] = taken }
                if let lat = meta["latitude"] { upMeta["latitude"] = lat }
                if let lng = meta["longitude"] { upMeta["longitude"] = lng }
                _ = try await API.updateFoodDetails(id, fields: ["image_path": upload["path"] as! String, "image_metadata": upMeta])
                applyImagePath(upload["path"] as! String, meta: upMeta)
                toast = "已更换"
            } catch {
                guard isNetworkError(error), let data = jpeg else {
                    toast = error.localizedDescription
                    return
                }
                var meta: [String: Any] = ["taken_at": nowTakenAt()]
                if let loc = await LocationOnce.fetch() {
                    meta["latitude"] = loc.lat
                    meta["longitude"] = loc.lng
                }
                replaceOffline(data, meta: meta)
            }
        }
    }

    private func replaceOffline(_ data: Data, meta: [String: Any]) {
        let path = OfflineStore.saveLocalImage(data)
        let fields: [String: Any] = ["image_path": path, "image_metadata": meta]
        let id = recordId
        if id > 0 {
            OfflineStore.enqueue(.patch(serverId: id, fields: fields))
        } else if let key = stripRecords.first(where: { ($0["id"] as? Int) == id })?["client_key"] as? String {
            OfflineStore.enqueue(.patchLocal(clientKey: key, fields: fields))
        }
        applyImagePath(path, meta: meta)
        toast = "已离线更换，联网后同步"
    }

    private func applyImagePath(_ path: String, meta: [String: Any]) {
        if var rec = OfflineStore.record(id: recordId) {
            rec["image_path"] = path
            rec["image_metadata"] = meta
            OfflineStore.upsertRecord(rec)
        }
        if let i = stripRecords.firstIndex(where: { ($0["id"] as? Int) == recordId }) {
            stripRecords[i]["image_path"] = path
            stripRecords[i]["image_metadata"] = meta
        }
        refreshDependents()
    }

    // MARK: - OCR（Vision 端内识别 → 字格划选）

    func handlePickedItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        pickedItem = nil
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                cameraMode == .ocr ? presentOcr(image: image) : replaceImage(image)
            }
        }
    }

    func presentOcr(image: UIImage) {
        let vm = OCRViewModel(image: image)
        vm.onApplyName = { [weak self] t in self?.name = t }
        vm.onApplyBrand = { [weak self] t in self?.brandName = t }
        vm.onApplyIngredient = { [weak self] t in self?.doConfirmIngredient(named: t, amount: nil) }
        ocrVM = vm
        ocrPresented = true
    }

    // SmokeTour 用：合成一张大字白底图直接打开 OCR 面板（Vision zh-Hans 可稳定识别）
    func smokePresentOcr() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300))
        let img = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 96), .foregroundColor: UIColor.black]
            ("美食日记" as NSString).draw(at: CGPoint(x: 90, y: 90), withAttributes: attrs)
        }
        presentOcr(image: img)
    }

    func closeOcr() {
        ocrVM = nil
        ocrPresented = false
    }

    // MARK: - 语音

    func startVoice() {
        voiceBase = commentInput
        voice.start()
    }

    func stopVoice() {
        voice.stop()
        recording = false
    }

    // MARK: - 偏好（偏好条拖动回调）

    func setPrefLevel(_ level: Int) {
        guard let c = AppConfig.shared, !c.preferences.isEmpty else { return }
        currentPref = c.preferences.min(by: { abs($0.level - level) < abs($1.level - level) })
    }

    func resetFlavors() {
        guard let c = AppConfig.shared else { return }
        c.flavors.forEach { flavorLevels[$0] = c.flavorScale["default"]! }
    }
}

// MARK: - OCR 划选面板（原 OcrViewController 移植，Vision 端内识别）

@MainActor
@Observable
final class OCRViewModel {
    let image: UIImage
    var chars: [String] = []
    var picked: Set<Int> = []
    var target = 0 // 0 产品名 1 品牌 2 原料
    var recognized = false
    var statusText = "识别中…"
    var onApplyName: ((String) -> Void)?
    var onApplyBrand: ((String) -> Void)?
    var onApplyIngredient: ((String) -> Void)?
    private var strokeMode: Bool?
    private var lastHit: Int?

    var builtText: String {
        chars.enumerated().filter { picked.contains($0.offset) }.map { $0.element }.joined()
    }
    static let targetNames = ["产品名", "品牌", "原料"]

    init(image: UIImage) {
        self.image = image
        Task { await recognize() }
    }

    func recognize() async {
        let format = UIGraphicsImageRendererFormat.default()
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let upright = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        guard let cg = upright.cgImage else { finishRecognition([]); return }
        let texts: [String] = await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                continuation.resume(returning: obs.compactMap { $0.topCandidates(1).first?.string })
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans"]
            request.usesLanguageCorrection = true
            DispatchQueue.global().async {
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do { try handler.perform([request]) }
                catch { continuation.resume(returning: []) }
            }
        }
        finishRecognition(texts)
    }

    private func finishRecognition(_ texts: [String]) {
        var items: [String] = []
        for t in texts { for ch in t { items.append(String(ch)) } }
        guard !items.isEmpty else {
            statusText = "未识别到文字"
            return
        }
        chars = items
        recognized = true
        statusText = "共\(items.count)个字，按住划选"
    }

    // 划选：起点定 on，滑过区域连续选中（移植 ocrTouchStart/Move/End 的 line continuity）
    func touchStarted(_ idx: Int) {
        strokeMode = true
        lastHit = nil
        setHit(idx)
    }

    func touchMoved(_ idx: Int) {
        guard let mode = strokeMode else { return }
        if let last = lastHit {
            let lo = min(last, idx), hi = max(last, idx)
            for i in lo...hi { setHit(i, on: mode) }
        } else {
            setHit(idx, on: mode)
        }
        lastHit = idx
    }

    func touchEnded() {
        strokeMode = nil
        lastHit = nil
    }

    private func setHit(_ idx: Int, on: Bool? = nil) {
        guard chars.indices.contains(idx) else { return }
        if on == true { picked.insert(idx) }
        else if on == false { picked.remove(idx) }
        else if picked.contains(idx) { picked.remove(idx) }
        else { picked.insert(idx) }
    }

    func apply() {
        let text = builtText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch target {
        case 0: onApplyName?(text)
        case 1: onApplyBrand?(text)
        default: onApplyIngredient?(text)
        }
    }
}

// MARK: - 详情视图

struct DetailView: View {
    @Environment(AppModel.self) private var app
    @State private var showDeleteConfirm = false

    var body: some View {
        @Bindable var vm = app.detail
        Group {
            if app.detail.loaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        stripSection
                        basicSection
                        flavorSection
                        commentSection
                        ingredientSection
                        actionSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.onDrag)
                .onTapGesture { hideKeyboard() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .toast($vm.toast)
        .onAppear { vm.onAppear() }
        .onDisappear { vm.stopVoice() }
        .confirmationDialog("确定要删除这条记录吗？此操作不可恢复", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { vm.deleteCurrent() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("从相册选择") { vm.cameraMode = .replace; vm.showingPhotoPicker = true }
                    Button("拍照") { vm.cameraMode = .replace; vm.showingCamera = true }
                } label: { Image(systemName: "camera") }
            }
        }
        .photosPicker(isPresented: $vm.showingPhotoPicker, selection: $vm.pickedItem, matching: .images)
        .onChange(of: vm.pickedItem) { _, item in vm.handlePickedItem(item) }
        .fullScreenCover(isPresented: $vm.showingCamera) {
            CameraPicker { image in
                vm.cameraMode == .ocr ? vm.presentOcr(image: image) : vm.replaceImage(image)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $vm.ocrPresented) {
            if let ocr = vm.ocrVM {
                OCRPanelView(ocr: ocr) { vm.closeOcr() }
                    .presentationBackground(.black.opacity(0.6))
            }
        }
    }

    private var stripSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(app.detail.todayStrip, id: \.id) { rec in
                    let id = rec["id"] as? Int ?? 0
                    VStack(spacing: 3) {
                        RemoteImage(path: rec["image_path"] as? String)
                            .frame(width: 96, height: 90)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(id == app.detail.recordId ? Theme.primary : .clear, lineWidth: 2)
                            )
                        Text((rec["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未命名")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .frame(width: 96)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { app.detail.selectRecord(id) }
                    .contextMenu {
                        Button("从相册选择") { app.detail.cameraMode = .replace; app.detail.showingPhotoPicker = true }
                        Button("拍照") { app.detail.cameraMode = .replace; app.detail.showingCamera = true }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var basicSection: some View {
        @Bindable var vm = app.detail
        return section("基本信息") {
            HStack {
                Spacer()
                Button {
                    vm.cameraMode = .ocr
                    vm.showingPhotoPicker = true
                } label: {
                    Text("📷 OCR识别")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.primary.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
            field("产品名称", text: $vm.name)
            field("品牌", text: $vm.brandName)
            HStack(spacing: 8) {
                field("原价", text: $vm.priceOrig, number: true)
                field("折扣价(选填)", text: $vm.priceDisc, number: true)
            }
            HStack(spacing: 8) {
                Text("值不值得").font(.system(size: 14, weight: .bold))
                Button {
                    vm.worthIt = vm.worthIt == "yes" ? "" : "yes"
                } label: {
                    Text("值").font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(vm.worthDisplay.yes ? Theme.primary : Color(white: 0.94), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(vm.worthDisplay.yes ? Color.white : Theme.primary)
                }
                .buttonStyle(.plain)
                Button {
                    vm.worthIt = vm.worthIt == "no" ? "" : "no"
                } label: {
                    Text("不值").font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(vm.worthDisplay.no ? Theme.bad : Color(white: 0.94), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(vm.worthDisplay.no ? Color.white : Theme.bad)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            HStack(spacing: 6) {
                Text("复购").font(.system(size: 14, weight: .bold))
                Text("\(vm.currentRepurchase) 次").font(.system(size: 14))
                Spacer()
                Text(vm.prevRecordLabel).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            field("搜索产品类别", text: $vm.categorySearch)
                .onChange(of: vm.categorySearch) { _, q in vm.onCategorySearch(q) }
            if !vm.categorySuggestions.isEmpty {
                FlowChips(items: vm.categorySuggestions) { vm.pickCategory($0) }
            }
            if !vm.selectedCategory.isEmpty {
                ChipView(text: "✕ \(vm.selectedCategory)") { vm.selectedCategory = "" }
            }
        }
    }

    private var flavorSection: some View {
        section("味道与偏好") {
            HStack(alignment: .top, spacing: 12) {
                FlavorWheelView(levels: Binding(
                    get: { app.detail.flavorLevels },
                    set: { app.detail.flavorLevels = $0 }
                ), onLevelChange: { name, level in
                    app.detail.flavorLevels[name] = level
                })
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 180)
                PreferenceTrackView(
                    selectedLevel: app.detail.currentPref?.level,
                    onLevel: { app.detail.setPrefLevel($0) }
                )
                .frame(maxWidth: 130)
                .frame(height: 170)
            }
            Button("↻ 重置") { app.detail.resetFlavors() }
                .font(.system(size: 14))
                .foregroundStyle(Theme.primary)
                .frame(maxWidth: .infinity)
                .buttonStyle(.plain)
        }
    }

    private var commentSection: some View {
        @Bindable var vm = app.detail
        return section("评论") {
            ForEach(vm.comments.indices, id: \.self) { idx in
                HStack(alignment: .top, spacing: 8) {
                    Text("· " + vm.comments[idx])
                        .font(.system(size: 14))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { vm.editComment(idx) }
                    Button("删除") { vm.deleteComment(idx) }
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $vm.commentInput)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.85)))
                    if vm.commentInput.isEmpty {
                        Text("添加评论").font(.system(size: 14)).foregroundStyle(.placeholderText).padding(10)
                    }
                }
                VoiceButtonView(recording: vm.recording, onStart: { vm.startVoice() }, onEnd: { vm.stopVoice() })
            }
            Button {
                vm.saveDetail()
            } label: {
                Text(vm.editingCommentIndex == nil ? "保存评论" : "完成编辑")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(Theme.primary, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private var ingredientSection: some View {
        @Bindable var vm = app.detail
        return section("原料") {
            HStack(spacing: 8) {
                field("原料", text: $vm.ingredientSearch)
                field("含量%", text: $vm.ingredientAmount, number: true)
                    .frame(width: 90)
            }
            if let p = vm.ingredientPreview {
                Button("＋ 确认添加：\(p.name)\(p.amount.isEmpty ? "" : " (\(p.amount)%)") {
                    vm.confirmIngredient()
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
                .buttonStyle(.plain)
            }
            FlowChips(items: vm.ingredients.compactMap { i -> String? in
                guard let n = i["name"] as? String else { return nil }
                if let a = i["amount"] as? NSNumber { return "✕ \(n)(\(a.intValue)%)" }
                if let a = i["amount"] as? String, !a.isEmpty { return "✕ \(n)(\(a)%)" }
                return "✕ \(n)"
            }, action: { text in
                vm.removeIngredient(text.replacingOccurrences(of: "✕ ", with: "").components(separatedBy: "(").first ?? "")
            })
        }
    }

    private var actionSection: some View {
        HStack(spacing: 12) {
            Button { app.detail.saveDetail() } label: {
                Text("保存")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Theme.primary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(app.detail.saving)
            Button { showDeleteConfirm = true } label: {
                Text("删除")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .bold))
            content()
        }
    }

    private func field(_ ph: String, text: Binding<String>, number: Bool = false) -> some View {
        TextField(ph, text: text)
            .font(.system(size: 14))
            .keyboardType(number ? .numbersAndPunctuation : .default)
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.88)))
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - OCR 面板视图

struct OCRPanelView: View {
    let ocr: OCRViewModel
    var onClose: () -> Void
    @State private var lastHit: Int?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                HStack {
                    Text("在图上点选文字").font(.system(size: 16, weight: .bold))
                    Spacer()
                    Button("完成") { ocr.apply(); onClose() }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.primary)
                }
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        Button(OCRViewModel.targetNames[i]) { ocr.target = i }
                            .font(.system(size: 13))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(ocr.target == i ? Theme.primary : Color(white: 0.94), in: Capsule())
                            .foregroundStyle(ocr.target == i ? Color.white : Theme.primary)
                    }
                    Spacer()
                }
                Text(ocr.statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("已选：\(ocr.builtText.isEmpty ? "（空）" : ocr.builtText)")
                    .font(.system(size: 14)).foregroundStyle(Theme.primary)
                HStack {
                    Spacer()
                    Button("＋添加") { ocr.apply() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Theme.primary, in: Capsule())
                    Button("清空") { ocr.picked.removeAll() }
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .overlay(Capsule().stroke(Color.red.opacity(0.5)))
                }
                charGrid
            }
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // 字格网格：拖动划选（触摸点 → 格子序号），点按切换单字
    private var charGrid: some View {
        GeometryReader { geo in
            let columns = 8
            let spacing: CGFloat = 4
            let cellW = (geo.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let cellH = cellW + 8
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellW), spacing: spacing), count: columns), spacing: spacing) {
                ForEach(ocr.chars.indices, id: \.self) { idx in
                    Text(ocr.chars[idx])
                        .font(.system(size: 17))
                        .frame(width: cellW, height: cellH)
                        .background(ocr.picked.contains(idx) ? Theme.primary.opacity(0.25) : Color.white, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.85)))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let idx = hitIndex(location: g.location, width: geo.size.width, columns: columns, cellW: cellW, cellH: cellH, spacing: spacing, count: ocr.chars.count)
                        guard let idx else { return }
                        if lastHit == nil {
                            ocr.touchStarted(idx)
                            lastHit = idx
                        } else if idx != lastHit {
                            ocr.touchMoved(idx)
                            lastHit = idx
                        }
                    }
                    .onEnded { _ in ocr.touchEnded(); lastHit = nil }
            )
        }
    }

    private func hitIndex(location: CGPoint, width: CGFloat, columns: Int, cellW: CGFloat, cellH: CGFloat, spacing: CGFloat, count: Int) -> Int? {
        let col = Int(location.x / (cellW + spacing))
        let row = Int(location.y / (cellH + spacing))
        guard col >= 0, col < columns, row >= 0 else { return nil }
        let idx = row * columns + col
        return idx < count ? idx : nil
    }
}

// MARK: - 语音按钮（原 VoiceButton 移植）

struct VoiceButtonView: View {
    let recording: Bool
    var onStart: () -> Void
    var onEnd: () -> Void

    var body: some View {
        Text("🎤")
            .font(.system(size: 20))
            .frame(width: 44, height: 44)
            .background(recording ? Color.red.opacity(0.5) : Color(white: 0.94), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !recording { onStart() } }
                    .onEnded { _ in onEnd() }
            )
    }
}

// MARK: - 味道轮盘（Canvas 移植 FlavorWheelView 绘制与拖动数学）

struct FlavorWheelView: View {
    @Binding var levels: [String: Int]
    var onLevelChange: (String, Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, _ in
                guard let c = AppConfig.shared, !c.flavors.isEmpty else { return }
                let scale = c.flavorScale
                let cx = size.width / 2, cy = size.height / 2
                let r = min(size.width, size.height) * 0.34
                let n = c.flavors.count
                var pts: [(name: String, level: Int, x: CGFloat, y: CGFloat, angle: CGFloat)] = []
                for (i, v) in c.flavors.enumerated() {
                    let a = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi * 2 / CGFloat(n)
                    pts.append((v, levels[v] ?? 0, cx + cos(a) * r, cy + sin(a) * r, a))
                }
                var frame = Path()
                frame.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
                for p in pts.dropFirst() { frame.addLine(to: CGPoint(x: p.x, y: p.y)) }
                frame.closeSubpath()
                ctx.stroke(frame, with: .color(Color(red: 0.85, green: 0.78, blue: 1.0)), lineWidth: 1)
                for p in pts {
                    var spoke = Path()
                    spoke.move(to: CGPoint(x: cx, y: cy))
                    spoke.addLine(to: CGPoint(x: p.x, y: p.y))
                    ctx.stroke(spoke, with: .color(Color(red: 0.90, green: 0.87, blue: 0.94)), lineWidth: 1)
                }
                let maxLv = CGFloat(scale["max"]!), minLv = CGFloat(scale["min"]!)
                var data = Path()
                for (i, p) in pts.enumerated() {
                    let dist = r * (CGFloat(p.level) - minLv) / (maxLv - minLv)
                    let pt = CGPoint(x: cx + cos(p.angle) * dist, y: cy + sin(p.angle) * dist)
                    if i == 0 { data.move(to: pt) } else { data.addLine(to: pt) }
                }
                data.closeSubpath()
                ctx.fill(data, with: .color(Theme.primary.opacity(0.25)))
                ctx.stroke(data, with: .color(Theme.primary), lineWidth: 1.5)
                for p in pts {
                    let dist = r * (CGFloat(p.level) - minLv) / (maxLv - minLv)
                    let hp = CGPoint(x: cx + cos(p.angle) * dist, y: cy + sin(p.angle) * dist)
                    ctx.fill(Path(ellipseIn: CGRect(x: hp.x - 5, y: hp.y - 5, width: 10, height: 10)), with: .color(Theme.primary))
                    let lr = r * 1.35
                    let lp = CGPoint(x: cx + cos(p.angle) * lr, y: cy + sin(p.angle) * lr)
                    let text = DetailViewModel.flavorLabel(p.name, level: p.level, scale: scale)
                    ctx.draw(Text(text).font(.system(size: 11)).foregroundColor(.darkGray), at: lp)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard let c = AppConfig.shared, !c.flavors.isEmpty else { return }
                        let scale = c.flavorScale
                        let p = g.location
                        let cx = size.width / 2, cy = size.height / 2
                        let r = min(size.width, size.height) * 0.34
                        // 命中最近轴（移植 nearestAxis）
                        let touchAngle = atan2(p.y - cy, p.x - cx)
                        var best = 0
                        var bestDiff = CGFloat.greatestFiniteMagnitude
                        for (i, name) in c.flavors.enumerated() {
                            let a = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi * 2 / CGFloat(c.flavors.count)
                            var diff = touchAngle - a
                            while diff > .pi { diff -= 2 * .pi }
                            while diff < -.pi { diff += 2 * .pi }
                            if abs(diff) < bestDiff { bestDiff = abs(diff); best = i }
                        }
                        // 投影长度映射回 level（移植 updateLevel）
                        let a = -CGFloat.pi / 2 + CGFloat(best) * CGFloat.pi * 2 / CGFloat(c.flavors.count)
                        let proj = (p.x - cx) * cos(a) + (p.y - cy) * sin(a)
                        guard r > 0 else { return }
                        let maxLv = CGFloat(scale["max"]!), minLv = CGFloat(scale["min"]!)
                        let lv = Int(round(proj / r * (maxLv - minLv))) + scale["min"]!
                        let clamped = max(scale["min"]!, min(scale["max"]!, lv))
                        levels[c.flavors[best]] = clamped
                        onLevelChange(c.flavors[best], clamped)
                    }
            )
        }
    }
}

// MARK: - 偏好竖条（拖动选偏好；移植 PreferenceTrack 交互）

struct PreferenceTrackView: View {
    let selectedLevel: Int?
    var onLevel: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let options = AppConfig.shared?.preferences ?? []
            let minL = options.first?.level ?? 0
            let maxL = options.last?.level ?? 100
            let sel = options.first { $0.level == selectedLevel }
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.94))
                if let sel {
                    let pct = CGFloat(sel.level - minL) / CGFloat(maxL - minL)
                    Rectangle()
                        .fill(Theme.primary.opacity(0.25))
                        .frame(height: max(0, min(1, pct)) * geo.size.height)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    VStack {
                        Text(sel.face).font(.system(size: 24))
                        Spacer()
                        Text(sel.label).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.primary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard options.count >= 2 else { return }
                        let ratio = max(0, min(1, 1 - g.location.y / geo.size.height))
                        onLevel(Int(round(CGFloat(minL) + ratio * CGFloat(maxL - minL))))
                    }
            )
        }
        .overlay {
            if selectedLevel == nil {
                Text("请选择").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.primary)
            }
        }
    }
}

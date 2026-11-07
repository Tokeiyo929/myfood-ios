import UIKit

// 详情页（对齐小程序 detail 页）：
// 图片横条（今日记录，点选切换/长按换图）+ 基本信息编辑 + 味道轮盘 + 偏好条
// + 评论（增删改）+ 原料（搜索+含量+chips）+ 保存/删除
class DetailViewController: UIViewController, UITextFieldDelegate, UITextViewDelegate {
    private var foodId: Int
    private var food: [String: Any]?
    private var stripRecords: [[String: Any]] = []   // 横条数据（今日记录）

    // 编辑状态
    private var flavorLevels: [String: Int] = [:]
    private var ingredients: [[String: Any]] = []
    var onChanged: (() -> Void)?
    private var saving = false
    private(set) var loaded = false
    private var draft = CommentDraft()
    private var selectedCategory = ""
    private var worthIt = ""            // "" / "yes" / "no"
    private var currentPref: (value: String, label: String, face: String, level: Int)?
    private var allCategories: [String] = []
    private var currentRepurchase = 0

    // UI
    private let scrollView = DetailScrollView()
    private let stack = UIStackView()
    private let stripCollection: UICollectionView
    private var wheelView: FlavorWheelView!
    private var resetBtn: UIButton!
    private var prefTrack: PreferenceTrack!
    private var nameField: UITextField!
    private var brandField: UITextField!
    private var origField: UITextField!
    private var discField: UITextField!
    private var worthYesBtn: UIButton!
    private var worthNoBtn: UIButton!
    private var repurchaseLabel: UILabel!
    private var prevRecordLabel: UILabel!
    private var catField: UITextField!
    private var catSuggestStack: UIStackView!
    private var catChipsStack: UIStackView!
    private var ingNameField: UITextField!
    private var ingAmountField: UITextField!
    private var ingPreviewLabel: UILabel!
    private var ingChipsStack: UIStackView!
    private var commentStack: UIStackView!
    private var commentInput: UITextView!
    private var commentPlaceholder = UILabel()
    private var voiceBtn: VoiceButton!
    private var voiceBase = ""

    init(foodId: Int) {
        self.foodId = foodId
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 96, height: 116)
        layout.minimumLineSpacing = 8
        stripCollection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .onDrag
        scrollView.delaysContentTouches = false
        view.addSubview(scrollView)
        dismissKeyboardOnBackgroundTap() // 点空白处收起键盘（名称/价格/类别/评论等所有输入框）
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -32),
        ])
        buildUI()
        Task { await loadAll() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        VoiceManager.shared.attach(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        VoiceManager.shared.detach(self)
    }

    // MARK: - 构建 UI

    private func buildUI() {
        // 图片横条
        stripCollection.backgroundColor = .clear
        stripCollection.delegate = self
        stripCollection.dataSource = self
        stripCollection.register(StripCell.self, forCellWithReuseIdentifier: "strip")
        stripCollection.showsHorizontalScrollIndicator = false
        stripCollection.heightAnchor.constraint(equalToConstant: 122).isActive = true
        stack.addArrangedSubview(stripCollection)

        // 基本信息
        let basic = section("基本信息")
        let ocrBtn = UIButton(type: .system)
        ocrBtn.setTitle("📷 OCR识别", for: .normal)
        ocrBtn.setTitleColor(Theme.primary, for: .normal)
        ocrBtn.titleLabel?.font = .systemFont(ofSize: 13)
        ocrBtn.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        ocrBtn.layer.cornerRadius = 6
        ocrBtn.layer.borderWidth = 1
        ocrBtn.layer.borderColor = Theme.primary.withAlphaComponent(0.5).cgColor
        ocrBtn.addTarget(self, action: #selector(startOcrFlow), for: .touchUpInside)
        let ocrRow = UIStackView(arrangedSubviews: [spacer(), ocrBtn])
        ocrRow.axis = .horizontal
        basic.addArrangedSubview(ocrRow)
        nameField = field("产品名称")
        brandField = field("品牌")
        origField = field("原价", number: true)
        discField = field("折扣价(选填)", number: true)
        let priceRow = UIStackView(arrangedSubviews: [origField, discField])
        priceRow.axis = .horizontal
        priceRow.spacing = 8
        priceRow.distribution = .fillEqually

        worthYesBtn = worthBtn("值", tag: 1)
        worthNoBtn = worthBtn("不值", tag: 2)
        let worthRow = UIStackView(arrangedSubviews: [inlineLabel("值不值得"), worthYesBtn, worthNoBtn, spacer()])
        worthRow.axis = .horizontal
        worthRow.spacing = 8

        repurchaseLabel = UILabel()
        repurchaseLabel.font = .systemFont(ofSize: 14)
        prevRecordLabel = UILabel()
        prevRecordLabel.font = .systemFont(ofSize: 12)
        prevRecordLabel.textColor = .secondaryLabel
        let repRow = UIStackView(arrangedSubviews: [inlineLabel("复购"), repurchaseLabel, spacer(), prevRecordLabel])
        repRow.axis = .horizontal
        repRow.spacing = 6

        catField = field("搜索产品类别")
        catField.delegate = self
        catSuggestStack = chipsStack()
        catChipsStack = chipsStack()
        basic.addArrangedSubview(nameField)
        basic.addArrangedSubview(brandField)
        basic.addArrangedSubview(priceRow)
        basic.addArrangedSubview(worthRow)
        basic.addArrangedSubview(repRow)
        basic.addArrangedSubview(catField)
        basic.addArrangedSubview(catSuggestStack)
        basic.addArrangedSubview(catChipsStack)
        stack.addArrangedSubview(basic)

        // 味道与偏好
        let flavor = section("味道与偏好")
        wheelView = FlavorWheelView()
        wheelView.translatesAutoresizingMaskIntoConstraints = false
        wheelView.heightAnchor.constraint(equalTo: wheelView.widthAnchor).isActive = true
        resetBtn = UIButton(type: .system)
        resetBtn.setTitle("↻ 重置", for: .normal)
        resetBtn.setTitleColor(Theme.primary, for: .normal)
        resetBtn.addTarget(self, action: #selector(resetFlavors), for: .touchUpInside)
        prefTrack = PreferenceTrack()
        prefTrack.translatesAutoresizingMaskIntoConstraints = false
        prefTrack.heightAnchor.constraint(equalToConstant: 170).isActive = true
        prefTrack.onLevel = { [weak self] level in self?.setPrefLevel(level) }
        let flavorRow = UIStackView(arrangedSubviews: [wheelView, prefTrack])
        flavorRow.axis = .horizontal
        flavorRow.spacing = 12
        flavorRow.distribution = .fillEqually
        flavor.addArrangedSubview(flavorRow)
        flavor.addArrangedSubview(resetBtn)
        stack.addArrangedSubview(flavor)

        // 评论
        let commentSection = section("评论")
        commentStack = UIStackView()
        commentStack.axis = .vertical
        commentStack.spacing = 6
        commentInput = UITextView()
        commentInput.font = .systemFont(ofSize: 14)
        commentInput.layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
        commentInput.layer.borderWidth = 1
        commentInput.layer.cornerRadius = 8
        commentInput.translatesAutoresizingMaskIntoConstraints = false
        commentInput.delegate = self
        commentPlaceholder.text = "添加评论"
        commentPlaceholder.font = .systemFont(ofSize: 14)
        commentPlaceholder.textColor = .placeholderText
        commentPlaceholder.isUserInteractionEnabled = false
        commentPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        commentInput.addSubview(commentPlaceholder)
        NSLayoutConstraint.activate([
            commentPlaceholder.topAnchor.constraint(equalTo: commentInput.topAnchor, constant: 8),
            commentPlaceholder.leadingAnchor.constraint(equalTo: commentInput.leadingAnchor, constant: 6),
            commentInput.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        let commentSave = UIButton(type: .system)
        commentSave.setTitle("保存评论", for: .normal)
        commentSave.backgroundColor = Theme.primary
        commentSave.setTitleColor(.white, for: .normal)
        commentSave.layer.cornerRadius = 8
        commentSave.translatesAutoresizingMaskIntoConstraints = false
        commentSave.heightAnchor.constraint(equalToConstant: 36).isActive = true
        commentSave.addTarget(self, action: #selector(saveDetail), for: .touchUpInside)
        voiceBtn = VoiceButton()
        voiceBtn.onStart = { [weak self] in
            guard let self else { return }
            voiceBase = commentInput.text ?? ""
            VoiceManager.shared.start()
        }
        voiceBtn.onEnd = { [weak self] in
            self?.voiceBtn.setRecording(false)
            VoiceManager.shared.stop()
        }
        voiceBtn.widthAnchor.constraint(equalToConstant: 44).isActive = true
        voiceBtn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let commentRow = UIStackView(arrangedSubviews: [commentInput, voiceBtn])
        commentRow.axis = .horizontal
        commentRow.spacing = 8
        commentRow.alignment = .bottom
        commentSection.addArrangedSubview(commentStack)
        commentSection.addArrangedSubview(commentRow)
        commentSection.addArrangedSubview(commentSave)
        stack.addArrangedSubview(commentSection)

        // 原料
        let ing = section("原料")
        ingNameField = field("原料")
        ingNameField.delegate = self
        ingAmountField = field("含量%", number: true)
        ingAmountField.delegate = self
        ingAmountField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let ingRow = UIStackView(arrangedSubviews: [ingNameField, ingAmountField])
        ingRow.axis = .horizontal
        ingRow.spacing = 8
        ingPreviewLabel = UILabel()
        ingPreviewLabel.font = .systemFont(ofSize: 13)
        ingPreviewLabel.textColor = Theme.primary
        let tap = UITapGestureRecognizer(target: self, action: #selector(confirmIngredient))
        ingPreviewLabel.addGestureRecognizer(tap)
        ingPreviewLabel.isUserInteractionEnabled = true
        ingChipsStack = chipsStack()
        ing.addArrangedSubview(ingRow)
        ing.addArrangedSubview(ingPreviewLabel)
        ing.addArrangedSubview(ingChipsStack)
        stack.addArrangedSubview(ing)

        // 动作
        let save = button("保存", style: "primary", action: #selector(saveDetail))
        let del = button("删除", style: "danger", action: #selector(deleteTapped))
        let btns = UIStackView(arrangedSubviews: [save, del])
        btns.axis = .horizontal
        btns.spacing = 12
        btns.distribution = .fillEqually
        stack.addArrangedSubview(btns)

    }

    // MARK: - 数据

    private func loadAll() async {
        var strip: [[String: Any]] = []
        var cats: [[String: Any]] = []
        var haveStrip = false
        var haveCats = false
        do {
            let config = try await AppConfig.load()
            strip = try await API.getAllFoods(limit: config.maxPageSize, today: true)
            haveStrip = true
            if !strip.contains(where: { ($0["id"] as? Int) == foodId }) {
                strip.insert(try await API.getFoodById(foodId), at: 0)
            }
            OfflineStore.mergeRecords(strip)
            let c = try await API.getCategories()
            cats = (c["items"] as? [[String: Any]]) ?? []
            haveCats = true
            OfflineStore.saveCategories(cats)
        } catch {}
        let haveRecord = strip.contains(where: { ($0["id"] as? Int) == foodId })
        if !haveStrip || !haveCats || !haveRecord {
            // 断网兜底：今天缓存 + 目标记录 + 类别缓存
            var cached = OfflineStore.cachedRecords().filter { OfflineStore.isToday($0) }
            if let rec = OfflineStore.record(id: foodId),
               !cached.contains(where: { ($0["id"] as? Int) == foodId }) {
                cached.insert(rec, at: 0)
            }
            if cached.contains(where: { ($0["id"] as? Int) == foodId }) {
                strip = cached
                cats = OfflineStore.cachedCategories()
                haveStrip = true
                haveCats = true
            }
        }
        guard haveStrip, haveCats else {
            let retry = UIButton(type: .system)
            retry.setTitle("加载失败，点此重试", for: .normal)
            retry.addAction(UIAction { [weak self, weak retry] _ in
                retry?.removeFromSuperview()
                Task { await self?.loadAll() }
            }, for: .touchUpInside)
            stack.addArrangedSubview(retry)
            Toast.show("加载失败，请检查网络", view)
            return
        }
        stripRecords = strip
        allCategories = cats.compactMap { $0["name"] as? String }
        food = stripRecords.first { ($0["id"] as? Int) == foodId }
        fill()
    }

    private func fill() {
        guard let f = food else {
            let l = UILabel(); l.text = "加载失败"; stack.addArrangedSubview(l); return
        }
        nameField.text = f["name"] as? String ?? ""
        brandField.text = f["brand_name"] as? String ?? ""
        let price = f["price"] as? [Any?]
        origField.text = (price?.count ?? 0) > 0 ? num(price?[0]) : ""
        discField.text = (price?.count ?? 0) > 1 ? num(price?[1]) : ""
        currentRepurchase = f["repurchase"] as? Int ?? 0
        repurchaseLabel.text = "\(currentRepurchase) 次"
        prevRecordLabel.text = Self.prevRecordLabel(f["modify_at"] as? [String])
        worthIt = worthStr(f["worth_it"])
        updateWorthButtons()
        selectedCategory = (f["categories"] as? [String])?.first ?? ""
        ingredients = f["ingredients"] as? [[String: Any]] ?? []
        draft.comments = f["comment"] as? [String] ?? []
        draft.editingIndex = nil
        commentInput.text = ""
        commentPlaceholder.isHidden = false
        ingNameField.text = ""
        ingAmountField.text = ""
        ingPreviewLabel.text = ""
        catField.text = ""
        catSuggestStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        renderCategory()
        renderIngredients()
        renderComments()

        // 味道 + 偏好
        if let c = AppConfig.shared {
            flavorLevels = [:]
            c.flavors.forEach { flavorLevels[$0] = c.flavorScale["default"]! }
            if let fl = f["flavors"] as? [[String: Any]] {
                fl.forEach { fv in
                    if let name = fv["name"] as? String, let lv = fv["level"] as? Int { flavorLevels[name] = lv }
                }
            }
            wheelView.configure(flavors: c.flavors, scale: c.flavorScale, levels: flavorLevels)
            wheelView.onLevelChange = { [weak self] name, level in
                self?.flavorLevels[name] = level
            }
            let prefVal = f["preference"] as? String
            currentPref = c.preferences.first { $0.value == prefVal }
            if currentPref == nil { Toast.show("偏好值无效，请重新选择", view) }
            prefTrack.configure(options: c.preferences, selected: currentPref)
        }
        stripCollection.reloadData()
        scrollStripToSelected()
        loaded = true
    }

    private func worthStr(_ v: Any?) -> String {
        Self.parseWorth(v)
    }

    // 可测：worker 存的是 "yes"/"no" 字符串，兼容历史 bool/NSNumber
    static func parseWorth(_ v: Any?) -> String {
        if let s = v as? String { return s == "yes" || s == "true" ? "yes" : s == "no" || s == "false" ? "no" : "" }
        if let b = v as? Bool { return b ? "yes" : "no" }
        if let n = v as? NSNumber { return n.boolValue ? "yes" : "no" }
        return ""
    }

    // MARK: - 手势：轮盘/偏好滑条自己消费拖动，页面不跟滚

    // 可测：返回 true = 该视图自己接管触摸，scrollView 不取消（不滚动）
    static func gestureOwnsTouch(_ v: UIView?) -> Bool {
        var cur: UIView? = v
        while let w = cur {
            if w is FlavorWheelView || w is PreferenceTrack { return true }
            cur = w.superview
        }
        return false
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

    private func num(_ v: Any?) -> String {
        guard let n = v as? NSNumber else { return "" }
        return n.stringValue
    }

    // MARK: - 图片横条

    private func selectRecord(_ id: Int) {
        guard let rec = stripRecords.first(where: { ($0["id"] as? Int) == id }) else { return }
        foodId = id
        food = rec
        fill()
    }

    private func pickReplace(source: UIImagePickerController.SourceType) {
        guard UIImagePickerController.isSourceTypeAvailable(source) else { Toast.show("来源不可用", view); return }
        pickingForOcr = false
        let p = UIImagePickerController()
        p.sourceType = source
        p.delegate = self
        present(p, animated: true)
    }

    // MARK: - OCR（对齐小程序 📷 OCR识别 → 相册/拍照 → 字格划选）

    private var pickingForOcr = false

    @objc private func startOcrFlow() {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "从相册选择", style: .default) { _ in self.ocrPick(source: .photoLibrary) })
        alert.addAction(UIAlertAction(title: "拍照", style: .default) { _ in self.ocrPick(source: .camera) })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = alert.popoverPresentationController { pop.sourceView = view }
        present(alert, animated: true)
    }

    private func ocrPick(source: UIImagePickerController.SourceType) {
        guard UIImagePickerController.isSourceTypeAvailable(source) else { Toast.show("来源不可用", view); return }
        pickingForOcr = true
        let p = UIImagePickerController()
        p.sourceType = source
        p.delegate = self
        present(p, animated: true)
    }

    private func presentOcr(_ image: UIImage) {
        let ocr = OcrViewController(image: image)
        ocr.onName = { [weak self] t in self?.nameField.text = t }
        ocr.onBrand = { [weak self] t in self?.brandField.text = t }
        ocr.onIngredient = { [weak self] t in self?.doConfirmIngredient(named: t, amount: nil) }
        present(ocr, animated: false)
    }

    // SmokeTour 用：合成一张大字白底图直接打开 OCR 面板（Vision zh-Hans 可稳定识别）
    private(set) var smokeOcrController: OcrViewController?
    func smokePresentOcr() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300))
        let img = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 96), .foregroundColor: UIColor.black]
            ("美食日记" as NSString).draw(at: CGPoint(x: 90, y: 90), withAttributes: attrs)
        }
        let ocr = OcrViewController(image: img)
        present(ocr, animated: false)
        smokeOcrController = ocr
    }

    private func doConfirmIngredient(named n: String, amount: NSNumber?) {
        Task {
            do {
                do {
                    _ = try await API.addIngredient(n)
                } catch {
                    // 全局原料词典入队离线补传；记录字段本身照常追加
                    guard isNetworkError(error) else { throw error }
                    OfflineStore.enqueue(.ingredient(n))
                }
                var item: [String: Any] = ["name": n]
                if let a = amount { item["amount"] = a }
                ingredients.append(item)
                ingNameField.text = ""
                ingAmountField.text = ""
                ingPreviewLabel.text = ""
                renderIngredients()
            } catch {
                DispatchQueue.main.async { Toast.show(error.localizedDescription, self.view) }
            }
        }
    }

    private func uploadReplace(_ image: UIImage) {
        guard let id = food?["id"] as? Int else { return }
        Toast.show("上传中…", view)
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
                // 本地未同步记录：不发网络请求，直接入队（create 同步成功后自动改写目标）
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
                food?["image_path"] = upload["path"]
                if let i = stripRecords.firstIndex(where: { ($0["id"] as? Int) == id }) {
                    stripRecords[i]["image_path"] = upload["path"]
                }
                if let rec = food { OfflineStore.upsertRecord(rec) }
                DispatchQueue.main.async {
                    self.onChanged?()
                    Toast.show("已更换", self.view)
                    self.stripCollection.reloadData()
                }
            } catch {
                guard isNetworkError(error), let data = jpeg else {
                    DispatchQueue.main.async { Toast.show(error.localizedDescription, self.view) }
                    return
                }
                // 断网换图：原图落盘占位 + 入队（同步时先传图再 PATCH）
                var meta: [String: Any] = ["taken_at": nowTakenAt()]
                if let loc = await LocationOnce.fetch() {
                    meta["latitude"] = loc.lat
                    meta["longitude"] = loc.lng
                }
                replaceOffline(data, meta: meta)
            }
        }
    }

    // 断网/本地记录换图共用：原图落盘占位 + 入队 + 本地展示更新
    private func replaceOffline(_ data: Data, meta: [String: Any]) {
        let path = OfflineStore.saveLocalImage(data)
        let fields: [String: Any] = ["image_path": path, "image_metadata": meta]
        let id = food?["id"] as? Int ?? 0
        if id > 0 {
            OfflineStore.enqueue(.patch(serverId: id, fields: fields))
        } else if let key = food?["client_key"] as? String {
            OfflineStore.enqueue(.patchLocal(clientKey: key, fields: fields))
        }
        food?["image_path"] = path
        if let i = stripRecords.firstIndex(where: { ($0["id"] as? Int) == id }) {
            stripRecords[i]["image_path"] = path
        }
        if let rec = food { OfflineStore.upsertRecord(rec) }
        onChanged?()
        Toast.show("已离线更换，联网后同步", view)
        stripCollection.reloadData()
    }

    private func scrollStripToSelected() {
        let idx = stripRecords.firstIndex { ($0["id"] as? Int) == foodId }
        guard let idx else { return }
        stripCollection.scrollToItem(at: IndexPath(item: idx, section: 0), at: .centeredHorizontally, animated: false)
    }

    // MARK: - 类别

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let cur = (textField.text ?? "") as NSString
        let newText = cur.replacingCharacters(in: range, with: string)
        if textField == catField {
            renderCategorySuggestions(query: newText)
        } else if textField == ingNameField || textField == ingAmountField {
            DispatchQueue.main.async { self.renderIngredientPreview() }
        }
        return true
    }

    private func renderCategorySuggestions(query: String) {
        catSuggestStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !query.isEmpty else { return }
        let matches = allCategories.filter { $0 != selectedCategory && $0.lowercased().contains(query.lowercased()) }
        matches.prefix(8).forEach { name in
            let b = chipButton(name)
            b.addAction(UIAction { [weak self] _ in
                self?.selectedCategory = name
                self?.catField.text = ""
                self?.catSuggestStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
                self?.renderCategory()
            }, for: .touchUpInside)
            catSuggestStack.addArrangedSubview(b)
        }
    }

    private func renderCategory() {
        catChipsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !selectedCategory.isEmpty else { return }
        let b = chipButton("✕ \(selectedCategory)")
        b.addAction(UIAction { [weak self] _ in
            self?.selectedCategory = ""
            self?.renderCategory()
        }, for: .touchUpInside)
        catChipsStack.addArrangedSubview(b)
    }

    // MARK: - 原料

    private func renderIngredientPreview() {
        let n = (ingNameField.text ?? "").trimmingCharacters(in: .whitespaces)
        if n.isEmpty { ingPreviewLabel.text = ""; return }
        let a = ingAmountField.text ?? ""
        ingPreviewLabel.text = a.isEmpty ? "＋ 确认添加：\(n)" : "＋ 确认添加：\(n) (\(a)%)"
    }

    @objc private func confirmIngredient() {
        let n = (ingNameField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let amount: NSNumber? = (ingAmountField.text?.isEmpty == false) ? NSNumber(value: Double(ingAmountField.text!) ?? 0) : nil
        doConfirmIngredient(named: n, amount: amount)
    }

    private func renderIngredients() {
        ingChipsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        ingredients.enumerated().forEach { idx, item in
            guard let n = item["name"] as? String else { return }
            var text = n
            if let a = item["amount"] as? NSNumber { text += "(\(a.intValue)%)" }
            else if let a = item["amount"] as? String, !a.isEmpty { text += "(\(a)%)" }
            let b = chipButton("✕ \(text)")
            b.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.ingredients.remove(at: idx)
                self.renderIngredients()
            }, for: .touchUpInside)
            ingChipsStack.addArrangedSubview(b)
        }
    }

    // MARK: - 评论

    private func renderComments() {
        commentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        draft.comments.enumerated().forEach { idx, text in
            let row = UIStackView(arrangedSubviews: [])
            row.axis = .horizontal
            row.spacing = 8
            let lb = UILabel()
            lb.text = "· " + text
            lb.font = .systemFont(ofSize: 14)
            lb.numberOfLines = 0
            lb.backgroundColor = UIColor(white: 0.95, alpha: 1)
            lb.layer.cornerRadius = 8
            lb.clipsToBounds = true
            lb.tag = idx
            let edit = UITapGestureRecognizer(target: self, action: #selector(editComment(_:)))
            lb.addGestureRecognizer(edit)
            lb.isUserInteractionEnabled = true
            let del = UIButton(type: .system)
            del.setTitle("删除", for: .normal)
            del.setTitleColor(.systemRed, for: .normal)
            del.titleLabel?.font = .systemFont(ofSize: 13)
            del.tag = idx
            del.addTarget(self, action: #selector(deleteComment(_:)), for: .touchUpInside)
            lb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(lb)
            row.addArrangedSubview(del)
            commentStack.addArrangedSubview(row)
        }
    }

    @objc private func editComment(_ g: UITapGestureRecognizer) {
        let idx = g.view?.tag ?? -1
        guard idx >= 0, idx < draft.comments.count else { return }
        commentInput.text = draft.comments[idx]
        draft.editingIndex = idx
        commentPlaceholder.isHidden = true
        commentInput.becomeFirstResponder()
    }

    @objc private func deleteComment(_ sender: UIButton) {
        let idx = sender.tag
        let alert = UIAlertController(title: "删除评论", message: "确定要删除这条评论吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            guard self.draft.comments.indices.contains(idx) else { return }
            let deletingEdited = self.draft.editingIndex == idx
            self.draft.remove(at: idx)
            if deletingEdited {
                self.commentInput.text = ""
                self.commentPlaceholder.isHidden = false
            }
            self.renderComments()
        })
        present(alert, animated: true)
    }

    func textViewDidChange(_ textView: UITextView) {
        if textView === commentInput {
            commentPlaceholder.isHidden = !(textView.text?.isEmpty ?? true)
        }
    }

    // MARK: - 偏好 / 值不值得 / 味道

    private func setPrefLevel(_ level: Int) {
        guard let c = AppConfig.shared, !c.preferences.isEmpty else { return }
        let pref = c.preferences.min(by: { abs($0.level - level) < abs($1.level - level) })!
        currentPref = pref
        prefTrack.updateSelected(pref)
    }

    private func updateWorthButtons() {
        worthYesBtn.backgroundColor = worthIt == "yes" ? Theme.primary : UIColor(white: 0.94, alpha: 1)
        worthYesBtn.setTitleColor(worthIt == "yes" ? .white : Theme.primary, for: .normal)
        worthNoBtn.backgroundColor = worthIt == "no" ? Theme.bad : UIColor(white: 0.94, alpha: 1)
        worthNoBtn.setTitleColor(worthIt == "no" ? .white : Theme.bad, for: .normal)
    }

    @objc private func worthTapped(_ sender: UIButton) {
        worthIt = sender.tag == 1 ? (worthIt == "yes" ? "" : "yes") : (worthIt == "no" ? "" : "no")
        updateWorthButtons()
    }

    @objc private func resetFlavors() {
        guard let c = AppConfig.shared else { return }
        c.flavors.forEach { flavorLevels[$0] = c.flavorScale["default"]! }
        wheelView.setLevels(flavorLevels)
    }

    // MARK: - 保存 / 删除

    @objc private func saveDetail() {
        guard loaded, !saving, let f = food, let c = AppConfig.shared else { return }
        guard let preference = currentPref?.value else { Toast.show("请选择有效偏好", view); return }
        let text = commentInput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newComments: [String]
        do { newComments = try draft.applying(text) }
        catch { Toast.show(error.localizedDescription, view); return }

        let flavors: [[String: Any]] = c.flavors.map { ["name": $0, "level": flavorLevels[$0]!] }
        var price: Any = NSNull()
        let o = origField.text!.trimmingCharacters(in: .whitespaces)
        let dsc = discField.text!.trimmingCharacters(in: .whitespaces)
        if !o.isEmpty || !dsc.isEmpty {
            var orig: Any = NSNull()
            var disc: Any = NSNull()
            if !o.isEmpty {
                guard let ov = Double(o), ov >= 0 else { Toast.show("价格无效", view); return }
                orig = NSNumber(value: ov)
            }
            if !dsc.isEmpty {
                guard let dv = Double(dsc), dv >= 0 else { Toast.show("价格无效", view); return }
                disc = NSNumber(value: dv)
            }
            price = [orig, disc]
        }
        let fields: [String: Any] = [
            "name": nameField.text!.trimmingCharacters(in: .whitespaces),
            "brand_name": brandField.text!.trimmingCharacters(in: .whitespaces),
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
        view.isUserInteractionEnabled = false
        Task {
            defer { saving = false; view.isUserInteractionEnabled = true }
            // 本地未同步记录：不发网络请求，直接入队（create 同步成功后自动改写为服务端 id）
            if id < 0 {
                if let key = f["client_key"] as? String {
                    OfflineStore.enqueue(.patchLocal(clientKey: key, fields: fields))
                }
                applyLocalSave(fields, base: f, newComments: newComments)
                Toast.show("已离线保存，联网后自动同步", view)
                return
            }
            Toast.show("保存中…", view)
            do {
                _ = try await API.updateFoodDetails(id, fields: fields)
                applyLocalSave(fields, base: f, newComments: newComments)
                onChanged?()
                DispatchQueue.main.async {
                    Toast.show("保存成功", self.view)
                    self.stripCollection.reloadData()
                }
            } catch {
                guard isNetworkError(error) else {
                    DispatchQueue.main.async { Toast.show(error.localizedDescription, self.view) }
                    return
                }
                // 断网保存：入队 + 本地乐观更新（含 modify_at/复购，镜像服务端 PATCH 行为）
                OfflineStore.enqueue(.patch(serverId: id, fields: fields))
                applyLocalSave(fields, base: f, newComments: newComments)
                onChanged?()
                DispatchQueue.main.async {
                    Toast.show("已离线保存，联网后自动同步", self.view)
                    self.stripCollection.reloadData()
                }
            }
        }
    }

    // 保存后的本地应用（在线/离线共用）：刷新表单态 + strip + 磁盘缓存
    private func applyLocalSave(_ fields: [String: Any], base f: [String: Any], newComments: [String]) {
        draft.comments = newComments
        draft.editingIndex = nil
        commentInput.text = ""
        commentPlaceholder.isHidden = false
        renderComments()
        var updated = f
        for (k, v) in fields { updated[k] = v }
        var dates = updated["modify_at"] as? [String] ?? []
        let today = OfflineStore.todayString()
        if dates.last != today { dates.append(today) }
        updated["modify_at"] = dates
        updated["repurchase"] = max(0, dates.count - 1)
        OfflineStore.upsertRecord(updated)
        food = updated
        if let i = stripRecords.firstIndex(where: { ($0["id"] as? Int) == updated["id"] as? Int }) {
            for (k, v) in fields { stripRecords[i][k] = v }
        }
        stripCollection.reloadData()
    }

    @objc private func deleteTapped() {
        let alert = UIAlertController(title: "确认删除", message: "确定要删除这条记录吗？此操作不可恢复", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            Task {
                // 本地未同步记录：直接撤销 create 队列，不发送网络请求
                if self.foodId < 0 {
                    if let key = self.food?["client_key"] as? String {
                        OfflineStore.cancelPendingCreate(clientKey: key)
                    }
                    OfflineStore.removeRecord(id: self.foodId)
                    self.onChanged?()
                    Toast.show("已删除", self.view)
                    self.navigationController?.popViewController(animated: true)
                    return
                }
                do {
                    _ = try await API.deleteFood(self.foodId)
                    OfflineStore.removeRecord(id: self.foodId)
                    self.onChanged?()
                    self.navigationController?.popViewController(animated: true)
                } catch {
                    guard isNetworkError(error) else { Toast.show(error.localizedDescription, self.view); return }
                    // 断网删除：本地移除 + 入队
                    OfflineStore.enqueue(.delete(serverId: self.foodId))
                    OfflineStore.removeRecord(id: self.foodId)
                    self.onChanged?()
                    Toast.show("已离线删除，联网后同步", self.view)
                    self.navigationController?.popViewController(animated: true)
                }
            }
        })
        present(alert, animated: true)
    }

    // MARK: - 组件工厂

    private func section(_ title: String) -> UIStackView {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 8
        let lb = UILabel()
        lb.text = title
        lb.font = .boldSystemFont(ofSize: 15)
        s.addArrangedSubview(lb)
        return s
    }

    private func field(_ ph: String, number: Bool = false) -> UITextField {
        let f = UITextField()
        f.placeholder = ph
        f.borderStyle = .roundedRect
        f.font = .systemFont(ofSize: 14)
        f.heightAnchor.constraint(equalToConstant: 40).isActive = true
        if number { f.keyboardType = .numbersAndPunctuation }
        return f
    }

    private func inlineLabel(_ t: String) -> UILabel {
        let l = UILabel()
        l.text = t
        l.font = .boldSystemFont(ofSize: 14)
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }

    private func spacer() -> UIView { UIView() }

    private func worthBtn(_ title: String, tag: Int) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 14)
        b.tag = tag
        b.layer.cornerRadius = 8
        b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        b.addTarget(self, action: #selector(worthTapped(_:)), for: .touchUpInside)
        return b
    }

    private func chipsStack() -> UIStackView {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 6
        return s
    }

    private func chipButton(_ text: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 12)
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        b.layer.cornerRadius = 12
        b.layer.borderWidth = 1
        b.layer.borderColor = Theme.primary.withAlphaComponent(0.5).cgColor
        b.setTitleColor(Theme.primary, for: .normal)
        // 单个 chip 时 stack 会把它拉满整行宽（视觉测试暴露），拥抱内容保持胶囊形
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func button(_ title: String, style: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        b.layer.cornerRadius = 10
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        if style == "primary" {
            b.backgroundColor = Theme.primary
            b.setTitleColor(.white, for: .normal)
        } else {
            b.backgroundColor = UIColor(white: 0.95, alpha: 1)
            b.setTitleColor(.systemRed, for: .normal)
        }
        return b
    }
}

// MARK: - 图片横条 collection

extension DetailViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        stripRecords.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "strip", for: indexPath) as! StripCell
        let rec = stripRecords[indexPath.item]
        cell.bind(name: (rec["name"] as? String) ?? "未命名",
                  imagePath: rec["image_path"] as? String, selected: (rec["id"] as? Int) == foodId)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = stripRecords[indexPath.item]["id"] as? Int else { return }
        selectRecord(id)
    }

    // 长按换图（相册/拍照）
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [
                UIAction(title: "从相册选择", image: UIImage(systemName: "photo")) { _ in self.pickReplace(source: .photoLibrary) },
                UIAction(title: "拍照", image: UIImage(systemName: "camera")) { _ in self.pickReplace(source: .camera) },
            ])
        })
    }
}

class StripCell: UICollectionViewCell {
    private let imgView = UIImageView()
    private let nameLb = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imgView.contentMode = .scaleAspectFill
        imgView.clipsToBounds = true
        imgView.layer.cornerRadius = 10
        imgView.backgroundColor = UIColor(white: 0.93, alpha: 1)
        imgView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imgView)
        nameLb.font = .systemFont(ofSize: 11)
        nameLb.textAlignment = .center
        nameLb.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLb)
        NSLayoutConstraint.activate([
            imgView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imgView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imgView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imgView.heightAnchor.constraint(equalToConstant: 90),
            nameLb.topAnchor.constraint(equalTo: imgView.bottomAnchor, constant: 3),
            nameLb.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameLb.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func bind(name: String, imagePath: String?, selected: Bool) {
        nameLb.text = name
        layer.borderWidth = selected ? 2 : 0
        layer.borderColor = selected ? Theme.primary.cgColor : nil
        layer.cornerRadius = 10
        ImageLoader.shared.load(API.imageUrl(imagePath), into: imgView)
    }
}

// MARK: - 味道轮盘（对齐小程序 canvas 轮盘，拖动调分）

class FlavorWheelView: UIView {
    private var flavors: [String] = []
    private var scale: [String: Int]?
    private var levels: [String: Int] = [:]
    private var draggingAxis: Int = -1
    var onLevelChange: ((String, Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(flavors: [String], scale: [String: Int], levels: [String: Int]) {
        self.flavors = flavors
        self.scale = scale
        self.levels = levels
        setNeedsDisplay()
    }

    func setLevels(_ lv: [String: Int]) {
        levels = lv
        setNeedsDisplay()
    }

    private func label(_ name: String, level: Int) -> String {
        guard let s = scale else { return name }
        if level < s["low"]! { return "不" + name }
        if level < s["mid"]! { return "微" + name }
        if level < s["high"]! { return name }
        return "太" + name
    }

    override func draw(_ rect: CGRect) {
        guard !flavors.isEmpty, let scale, let ctx = UIGraphicsGetCurrentContext() else { return }
        let cx = rect.midX, cy = rect.midY
        let r = min(rect.width, rect.height) * 0.34
        let maxLv = CGFloat(scale["max"]!)
        let pts: [(String, Int, CGPoint, CGFloat)] = flavors.enumerated().map { i, v in
            let a = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi * 2 / CGFloat(flavors.count)
            let p = CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
            return (v, levels[v] ?? 0, p, a)
        }
        // 外框
        ctx.setStrokeColor(UIColor(red: 0xd9/255, green: 0xc7/255, blue: 0xff/255, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.addLines(between: pts.map { $0.2 })
        ctx.closePath()
        ctx.strokePath()
        // 辐条
        ctx.setStrokeColor(UIColor(red: 0xe5/255, green: 0xdf/255, blue: 0xf0/255, alpha: 1).cgColor)
        pts.forEach { p in
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: p.2)
        }
        ctx.strokePath()
        // 数据多边形
        let dataPts = pts.map { v -> CGPoint in
            let dist = r * CGFloat(v.1 - scale["min"]!) / (maxLv - CGFloat(scale["min"]!))
            return CGPoint(x: cx + cos(v.3) * dist, y: cy + sin(v.3) * dist)
        }
        ctx.addLines(between: dataPts)
        ctx.closePath()
        ctx.setFillColor(UIColor(red: 47/255.0, green: 107/255.0, blue: 79/255.0, alpha: 0.25).cgColor)
        ctx.setLineWidth(1.5)
        ctx.fillPath()
        ctx.setStrokeColor(Theme.primary.cgColor)
        ctx.addLines(between: dataPts)
        ctx.closePath()
        ctx.strokePath()
        // 手柄 + 标签
        pts.enumerated().forEach { i, p in
            let dist = r * CGFloat(p.1 - scale["min"]!) / (maxLv - CGFloat(scale["min"]!))
            let hp = CGPoint(x: cx + cos(p.3) * dist, y: cy + sin(p.3) * dist)
            ctx.setFillColor(Theme.primary.cgColor)
            ctx.fillEllipse(in: CGRect(x: hp.x - 5, y: hp.y - 5, width: 10, height: 10))
            let lr = r * 1.35
            let lp = CGPoint(x: cx + cos(p.3) * lr, y: cy + sin(p.3) * lr)
            let text = label(p.0, level: p.1) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: draggingAxis == i ? Theme.primary : UIColor.darkGray,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: lp.x - size.width / 2, y: lp.y - size.height / 2), withAttributes: attrs)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        draggingAxis = nearestAxis(t.location(in: self))
        if draggingAxis >= 0 { updateLevel(at: t.location(in: self)) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard draggingAxis >= 0, let t = touches.first else { return }
        updateLevel(at: t.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        draggingAxis = -1
        setNeedsDisplay()
    }

    private func nearestAxis(_ p: CGPoint) -> Int {
        guard !flavors.isEmpty else { return -1 }
        let touchAngle = atan2(p.y - bounds.midY, p.x - bounds.midX)
        var best = 0
        var bestDiff = CGFloat.greatestFiniteMagnitude
        for i in 0..<flavors.count {
            let a = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi * 2 / CGFloat(flavors.count)
            var diff = touchAngle - a
            while diff > .pi { diff -= 2 * .pi }
            while diff < -.pi { diff += 2 * .pi }
            if abs(diff) < bestDiff { bestDiff = abs(diff); best = i }
        }
        return best
    }

    private func updateLevel(at p: CGPoint) {
        guard draggingAxis >= 0, draggingAxis < flavors.count, let s = scale else { return }
        let a = -CGFloat.pi / 2 + CGFloat(draggingAxis) * CGFloat.pi * 2 / CGFloat(flavors.count)
        let r = min(bounds.width, bounds.height) * 0.34
        let proj = (p.x - bounds.midX) * cos(a) + (p.y - bounds.midY) * sin(a)
        let maxLv = CGFloat(s["max"]!)
        guard r > 0 else { return }
        let lv = Int(round(proj / r * (maxLv - CGFloat(s["min"]!)))) + s["min"]!
        let clamped = max(s["min"]!, min(s["max"]!, lv))
        levels[flavors[draggingAxis]] = clamped
        onLevelChange?(flavors[draggingAxis], clamped)
        setNeedsDisplay()
    }
}

// MARK: - 偏好竖条（拖动选偏好）

class PreferenceTrack: UIView {
    private var options: [(value: String, label: String, face: String, level: Int)] = []
    private var selected: (value: String, label: String, face: String, level: Int)?
    var onLevel: ((Int) -> Void)?
    private let fillView = UIView()
    private let thumbView = UIView()
    private let faceLabel = UILabel()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.94, alpha: 1)
        layer.cornerRadius = 8
        clipsToBounds = true
        fillView.backgroundColor = Theme.primary.withAlphaComponent(0.25)
        addSubview(fillView)
        thumbView.backgroundColor = Theme.primary
        thumbView.bounds.size = CGSize(width: 18, height: 18)
        thumbView.layer.cornerRadius = 9
        addSubview(thumbView)
        faceLabel.font = .systemFont(ofSize: 24)
        faceLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(faceLabel)
        nameLabel.font = .boldSystemFont(ofSize: 13)
        nameLabel.textColor = Theme.primary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            faceLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            faceLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(options: [(value: String, label: String, face: String, level: Int)], selected: (value: String, label: String, face: String, level: Int)?) {
        self.options = options
        self.selected = selected
        layoutForSelection()
    }

    func updateSelected(_ p: (value: String, label: String, face: String, level: Int)) {
        selected = p
        layoutForSelection()
    }

    private func layoutForSelection() {
        guard let sel = selected, options.count >= 2, bounds.height > 0 else {
            fillView.frame = .zero
            thumbView.isHidden = true
            faceLabel.text = ""
            nameLabel.text = "请选择"
            return
        }
        thumbView.isHidden = false
        let minL = options.first!.level
        let maxL = options.last!.level
        let pct = CGFloat(sel.level - minL) / CGFloat(maxL - minL)
        let fillH = pct * bounds.height
        fillView.frame = CGRect(x: 0, y: bounds.height - fillH, width: bounds.width, height: fillH)
        thumbView.center = CGPoint(x: bounds.midX, y: bounds.height - fillH)
        faceLabel.text = sel.face
        nameLabel.text = sel.label
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutForSelection()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touch(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touch(touches) }

    private func touch(_ touches: Set<UITouch>) {
        guard let t = touches.first, options.count >= 2 else { return }
        let p = t.location(in: self)
        let ratio = max(0, min(1, 1 - p.y / bounds.height))
        let minL = options.first!.level
        let maxL = options.last!.level
        onLevel?(Int(round(CGFloat(minL) + ratio * CGFloat(maxL - minL))))
    }
}

// MARK: - 语音输入

extension DetailViewController: VoiceReceiver {
    func voiceDidStop() { voiceBtn.setRecording(false) }
    func voiceDidStart() {
        voiceBtn.setRecording(true)
    }
    func voiceDidRecognize(_ text: String, isFinal: Bool) {
        commentInput.text = voiceBase + text
        commentPlaceholder.isHidden = !(commentInput.text?.isEmpty ?? true)
    }
    func voiceDidFail(_ msg: String) {
        voiceBtn.setRecording(false)
        Toast.show(msg, view)
    }
}

// MARK: - 换图 picker

extension DetailViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let img = info[.originalImage] as? UIImage else { return }
        if pickingForOcr { presentOcr(img) } else { uploadReplace(img) }
    }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
}

final class DetailScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        !DetailViewController.gestureOwnsTouch(view) && super.touchesShouldCancel(in: view)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer,
           DetailViewController.gestureOwnsTouch(hitTest(gestureRecognizer.location(in: self), with: nil)) { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

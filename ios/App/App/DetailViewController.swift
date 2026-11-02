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
    private var comments: [String] = []
    private var editingCommentIndex: Int?
    private var selectedCategory = ""
    private var worthIt = ""            // "" / "yes" / "no"
    private var currentPref: (value: Int, label: String, face: String, level: Int)?
    private var allCategories: [String] = []
    private var currentRepurchase = 0

    // UI
    private let scrollView = UIScrollView()
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
        view.addSubview(scrollView)
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
        VoiceManager.shared.ensurePermission()
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
            if !VoiceManager.shared.start() { Toast.show("语音功能不可用", view) }
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

        worthYesBtn.addTarget(self, action: #selector(worthTapped(_:)), for: .touchUpInside)
        worthNoBtn.addTarget(self, action: #selector(worthTapped(_:)), for: .touchUpInside)
    }

    // MARK: - 数据

    private func loadAll() async {
        let config = await AppConfig.load()
        do {
            let limit = config?.maxPageSize ?? 100
            let r = try await API.getFoods(page: 1, limit: limit, today: true)
            stripRecords = r["items"] as? [[String: Any]] ?? []
        } catch { stripRecords = [] }
        if !stripRecords.contains(where: { ($0["id"] as? Int) == foodId }) {
            if let f = try? await API.getFoodById(foodId) { stripRecords.insert(f, at: 0) }
        }
        if let cats = try? await API.getCategories(), let items = cats["items"] as? [[String: Any]] {
            allCategories = items.compactMap { $0["name"] as? String }
        }
        food = stripRecords.first { ($0["id"] as? Int) == foodId }
        if food == nil, let f = try? await API.getFoodById(foodId) { food = f }
        DispatchQueue.main.async { self.fill() }
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
        comments = f["comment"] as? [String] ?? []
        editingCommentIndex = nil
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
            let prefVal = f["preference"] as? Int
            currentPref = c.preferences.first { $0.value == prefVal } ?? c.preferences.first
            prefTrack.configure(options: c.preferences, selected: currentPref)
        }
        stripCollection.reloadData()
        scrollStripToSelected()
    }

    private func worthStr(_ v: Any?) -> String {
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

    private func num(_ v: Any?) -> String {
        guard let n = v as? NSNumber else { return "" }
        return n.stringValue
    }

    // MARK: - 图片横条

    private func selectRecord(_ id: Int) {
        foodId = id
        if let rec = stripRecords.first(where: { ($0["id"] as? Int) == id }) {
            food = rec
            fill()
        } else {
            Task {
                if let f = try? await API.getFoodById(id) {
                    food = f
                    DispatchQueue.main.async { self.fill() }
                }
            }
        }
    }

    private func pickReplace(source: UIImagePickerController.SourceType) {
        guard UIImagePickerController.isSourceTypeAvailable(source) else { Toast.show("来源不可用", view); return }
        let p = UIImagePickerController()
        p.sourceType = source
        p.delegate = self
        present(p, animated: true)
    }

    private func uploadReplace(_ image: UIImage) {
        guard let id = food?["id"] as? Int else { return }
        Toast.show("上传中…", view)
        Task {
            do {
                let jpeg = image.resized(maxDimension: CGFloat(AppConfig.shared?.imageMaxDimension ?? 320))
                    .jpegData(compressionQuality: AppConfig.shared?.imageQuality ?? 0.8) ?? Data()
                let upload = try await API.uploadImage(jpegData: jpeg)
                var meta = upload["metadata"] as? [String: Any] ?? [:]
                meta["taken_at"] = RecordViewController.nowTakenAt()
                _ = try await API.updateFoodDetails(id, fields: ["image_path": upload["path"] as? String ?? "", "image_metadata": meta])
                food?["image_path"] = upload["path"]
                if let i = stripRecords.firstIndex(where: { ($0["id"] as? Int) == id }) {
                    stripRecords[i]["image_path"] = upload["path"]
                }
                DispatchQueue.main.async {
                    Toast.show("已更换", self.view)
                    self.stripCollection.reloadData()
                }
            } catch {
                DispatchQueue.main.async { Toast.show(error.localizedDescription, self.view) }
            }
        }
    }

    private func scrollStripToSelected() {
        let idx = stripRecords.firstIndex { ($0["id"] as? Int) == foodId }
        guard let idx, stripRecords.count > 0 else { return }
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
        Task {
            do {
                _ = try await API.addIngredient(n)
                var item: [String: Any] = ["name": n]
                if let a = amount { item["amount"] = a }
                ingredients.append(item)
                ingNameField.text = ""
                ingAmountField.text = ""
                DispatchQueue.main.async {
                    self.renderIngredients()
                    self.ingPreviewLabel.text = ""
                }
            } catch {
                DispatchQueue.main.async { Toast.show(error.localizedDescription, self.view) }
            }
        }
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
        comments.enumerated().forEach { idx, text in
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
        guard idx >= 0, idx < comments.count else { return }
        commentInput.text = comments[idx]
        editingCommentIndex = idx
        commentPlaceholder.isHidden = true
        commentInput.becomeFirstResponder()
    }

    @objc private func deleteComment(_ sender: UIButton) {
        let idx = sender.tag
        let alert = UIAlertController(title: "删除评论", message: "确定要删除这条评论吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            self.comments.remove(at: idx)
            if self.editingCommentIndex == idx {
                self.editingCommentIndex = nil
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
        guard let f = food, let c = AppConfig.shared else { return }
        // 评论合并（编辑中 → 替换/删空，否则追加）
        let text = commentInput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = editingCommentIndex {
            if text.isEmpty { comments.remove(at: idx) } else { comments[idx] = text }
            editingCommentIndex = nil
        } else if !text.isEmpty {
            comments.append(text)
        }
        commentInput.text = ""
        commentPlaceholder.isHidden = false
        renderComments()

        let flavors = c.flavors.compactMap { name -> [String: Any]? in
            guard let lv = flavorLevels[name], lv > (c.flavorScale["min"] ?? 0) else { return nil }
            return ["name": name, "level": lv]
        }
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
            "preference": currentPref?.value ?? (f["preference"] as? Int ?? 60),
            "worth_it": worthIt == "" ? NSNull() : NSNumber(value: worthIt == "yes"),
            "comment": comments,
        ]
        let id = f["id"] as! Int
        Toast.show("保存中…", view)
        Task {
            do {
                _ = try await API.updateFoodDetails(id, fields: fields)
                var updated = f
                for (k, v) in fields { updated[k] = v }
                food = updated
                if let i = stripRecords.firstIndex(where: { ($0["id"] as? Int) == id }) {
                    for (k, v) in fields { stripRecords[i][k] = v }
                }
                DispatchQueue.main.async {
                    Toast.show("保存成功", self.view)
                    self.stripCollection.reloadData()
                }
            } catch {
                DispatchQueue.main.async { Toast.show(error.localizedDescription, self.view) }
            }
        }
    }

    @objc private func deleteTapped() {
        let alert = UIAlertController(title: "确认删除", message: "确定要删除这条记录吗？此操作不可恢复", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            Task {
                _ = try? await API.deleteFood(self.foodId)
                DispatchQueue.main.async { self.navigationController?.popViewController(animated: true) }
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
        if let p = imagePath, let url = API.imageUrl(p) {
            ImageLoader.shared.load(url, into: imgView)
        } else {
            imgView.image = UIImage(systemName: "photo")
        }
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
        guard !flavors.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
        let cx = rect.midX, cy = rect.midY
        let r = min(rect.width, rect.height) * 0.34
        let maxLv = CGFloat(scale?["max"] ?? 5)
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
            let dist = r * CGFloat(v.1) / maxLv
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
            let dist = r * CGFloat(p.1) / maxLv
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
        let maxLv = CGFloat(s["max"] ?? 5)
        let lv = Int(round(proj / r * maxLv))
        let clamped = max(s["min"] ?? 0, min(s["max"] ?? 5, lv))
        levels[flavors[draggingAxis]] = clamped
        onLevelChange?(flavors[draggingAxis], clamped)
        setNeedsDisplay()
    }
}

// MARK: - 偏好竖条（拖动选偏好）

class PreferenceTrack: UIView {
    private var options: [(value: Int, label: String, face: String, level: Int)] = []
    private var selected: (value: Int, label: String, face: String, level: Int)?
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
        fillView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fillView)
        thumbView.backgroundColor = Theme.primary
        thumbView.layer.cornerRadius = 9
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbView)
        faceLabel.font = .systemFont(ofSize: 24)
        faceLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(faceLabel)
        nameLabel.font = .boldSystemFont(ofSize: 13)
        nameLabel.textColor = Theme.primary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            fillView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fillView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fillView.bottomAnchor.constraint(equalTo: bottomAnchor),
            thumbView.centerXAnchor.constraint(equalTo: centerXAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 18),
            thumbView.heightAnchor.constraint(equalToConstant: 18),
            faceLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            faceLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(options: [(value: Int, label: String, face: String, level: Int)], selected: (value: Int, label: String, face: String, level: Int)?) {
        self.options = options
        self.selected = selected
        layoutForSelection()
    }

    func updateSelected(_ p: (value: Int, label: String, face: String, level: Int)) {
        selected = p
        layoutForSelection()
    }

    private func layoutForSelection() {
        guard let sel = selected, options.count >= 2, bounds.height > 0 else { return }
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
    func voiceDidStart() {
        DispatchQueue.main.async { self.voiceBtn.setRecording(true) }
    }
    func voiceDidRecognize(_ text: String, isFinal: Bool) {
        DispatchQueue.main.async {
            self.commentInput.text = self.voiceBase + text
            self.commentPlaceholder.isHidden = !(self.commentInput.text?.isEmpty ?? true)
        }
    }
    func voiceDidFail(_ msg: String) {
        DispatchQueue.main.async {
            self.voiceBtn.setRecording(false)
            Toast.show(msg, self.view)
        }
    }
}

// MARK: - 换图 picker

extension DetailViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let img = info[.originalImage] as? UIImage else { return }
        uploadReplace(img)
    }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
}

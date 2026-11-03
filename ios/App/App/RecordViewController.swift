import UIKit
import CoreLocation

// 记录 tab：今日记录 + 拍照/相册快速保存（对齐小程序 records 页）
// 上传元数据对齐 compressAndUpload：taken_at + latitude/longitude
// （小程序取 gcj02 坐标，iOS 只能取 WGS84 原始定位，国内存在偏移，已知差异）
class RecordViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var onRecordsChanged: (() -> Void)?
    func markNeedsRefresh() { needsRefresh = true }
    private var table: UITableView!
    private var records: [[String: Any]] = []
    private var config: AppConfig?
    private var needsRefresh = true
    private(set) var loaded = false

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "记录"
        table = UITableView(frame: .zero, style: .plain)
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.register(RecordCardCell.self, forCellReuseIdentifier: "rcard")
        table.rowHeight = 76
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let album = UIBarButtonItem(title: "从相册选", style: .plain, target: self, action: #selector(pickAlbum))
        let camera = UIBarButtonItem(title: "拍照", style: .plain, target: self, action: #selector(pickCamera))
        navigationItem.rightBarButtonItems = [album, camera]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if needsRefresh { needsRefresh = false; Task { await loadToday() } }
    }

    private func loadToday() async {
        loaded = false
        do {
            let config = try await AppConfig.load()
            self.config = config
            records = try await API.getAllFoods(limit: config.maxPageSize, today: true)
            loaded = true
            table.reloadData()
        } catch {
            needsRefresh = true
            Toast.show(error.localizedDescription, view)
        }
    }

    @objc private func pickAlbum() { pick(source: .photoLibrary) }
    @objc private func pickCamera() { pick(source: .camera) }

    private func pick(source: UIImagePickerController.SourceType) {
        guard config != nil else {
            Task {
                do { config = try await AppConfig.load(); pick(source: source) }
                catch { Toast.show(error.localizedDescription, view) }
            }
            return
        }
        guard UIImagePickerController.isSourceTypeAvailable(source) else { Toast.show("来源不可用", view); return }
        let p = UIImagePickerController()
        p.sourceType = source
        p.delegate = self
        present(p, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let img = info[.originalImage] as? UIImage else { return }
        Toast.show("上传中…", view)
        Task {
            do {
                // 缩放到最大边长 + JPEG 压缩（对齐小程序 compressAndUpload 规则）
                let config = try await AppConfig.load()
                guard let jpeg = img.resized(maxDimension: CGFloat(config.imageMaxDimension))
                    .jpegData(compressionQuality: config.imageQuality) else { throw APIError(message: "图片编码失败") }
                let upload = try await API.uploadImage(jpegData: jpeg)
                var meta = upload["metadata"] as? [String: Any] ?? [:]
                meta["taken_at"] = Self.nowTakenAt()
                if let loc = await LocationOnce.fetch() {
                    meta["latitude"] = loc.lat
                    meta["longitude"] = loc.lng
                }
                let record: [String: Any] = [
                    "name": "", "brand_name": "", "price": NSNull(), "categories": [], "ingredients": [], "flavors": [],
                    "preference": config.defaultPreference,
                    "comment": [],
                    "image_path": upload["path"] as! String,
                    "image_metadata": meta,
                    "client_key": String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + "-" + String(Int.random(in: 0..<1_000_000), radix: 36),
                ]
                _ = try await API.submitFood(record)
                onRecordsChanged?()
                Toast.show("已保存", view)
                await loadToday()
            } catch {
                DispatchQueue.main.async { Toast.show(error.localizedDescription, self.view) }
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }

    static func nowTakenAt() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: table
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.isEmpty ? 1 : records.count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        config.map { "上传图片最大边长 \($0.imageMaxDimension) 像素" }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if records.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "rempty") ?? UITableViewCell(style: .default, reuseIdentifier: "rempty")
            var cfg = cell.defaultContentConfiguration()
            cfg.text = "今天还没有记录"
            cfg.textProperties.alignment = .center
            cell.contentConfiguration = cfg
            cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "rcard") as! RecordCardCell
        cell.bind(records[indexPath.row])
        cell.onComment = { [weak self] id in self?.openComment(id) }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !records.isEmpty else { return }
        guard let id = records[indexPath.row]["id"] as? Int else { return }
        let d = DetailViewController(foodId: id)
        d.onChanged = { [weak self] in self?.needsRefresh = true; self?.onRecordsChanged?() }
        navigationController?.pushViewController(d, animated: true)
    }

    // MARK: 评论面板（对齐 records 页 openComment 弹层）

    private func openComment(_ id: Int) {
        guard let rec = records.first(where: { ($0["id"] as? Int) == id }) else { return }
        let comments = rec["comment"] as? [String] ?? []
        let panel = CommentPanelController(foodId: id, comments: comments)
        panel.onSaved = { [weak self] in
            self?.onRecordsChanged?()
            Task { await self?.loadToday() }
        }
        present(UINavigationController(rootViewController: panel), animated: true)
    }
}

// 记录卡片：图 + 名称 + 时间 + 评论N次 + 评论按钮
final class RecordCardCell: UITableViewCell {
    var onComment: ((Int) -> Void)?
    private var foodId = 0
    private let card = UIView()
    private let imgView = UIImageView()
    private let nameLabel = UILabel()
    private let timeLabel = UILabel()
    private let commentBtn = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        card.backgroundColor = .white
        card.layer.cornerRadius = 12
        card.layer.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        imgView.contentMode = .scaleAspectFill
        imgView.clipsToBounds = true
        imgView.layer.cornerRadius = 10
        imgView.backgroundColor = UIColor(white: 0.93, alpha: 1)
        imgView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(imgView)

        nameLabel.font = .boldSystemFont(ofSize: 15)
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = .secondaryLabel

        commentBtn.setTitleColor(Theme.primary, for: .normal)
        commentBtn.titleLabel?.font = .systemFont(ofSize: 13)
        commentBtn.backgroundColor = Theme.primary.withAlphaComponent(0.08)
        commentBtn.layer.cornerRadius = 12
        commentBtn.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        commentBtn.addAction(UIAction(handler: { [weak self] _ in
            guard let self else { return }
            self.onComment?(self.foodId)
        }), for: .touchUpInside)

        let info = UIStackView(arrangedSubviews: [nameLabel, timeLabel])
        info.axis = .vertical
        info.spacing = 4
        info.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(info)
        card.addSubview(commentBtn)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            imgView.widthAnchor.constraint(equalToConstant: 56),
            imgView.heightAnchor.constraint(equalToConstant: 56),
            imgView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            imgView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            info.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 12),
            info.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            commentBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            commentBtn.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            commentBtn.leadingAnchor.constraint(greaterThanOrEqualTo: info.trailingAnchor, constant: 8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func bind(_ rec: [String: Any]) {
        foodId = rec["id"] as? Int ?? 0
        let n = rec["name"] as? String ?? ""
        nameLabel.text = n.isEmpty ? "未命名" : n
        let t = (rec["image_metadata"] as? [String: Any])?["taken_at"] as? String ?? ""
        timeLabel.text = String(t.prefix(16))
        let comments = rec["comment"] as? [String] ?? []
        commentBtn.setTitle("💬 \(comments.count)", for: .normal)
        ImageLoader.shared.load(API.imageUrl(rec["image_path"] as? String), into: imgView)
    }
}

// 评论面板：评论列表 + 输入（🎤 语音）+ 保存（对齐 records 页评论弹层 + voice.js）
final class CommentPanelController: UIViewController, UITableViewDataSource, UITextViewDelegate, VoiceReceiver {
    var onSaved: (() -> Void)?
    private let foodId: Int
    private var comments: [String]
    private let table = UITableView()
    private let input = UITextView()
    private let placeholder = UILabel()
    private let voiceBtn = VoiceButton()
    private var voiceBase = ""

    init(foodId: Int, comments: [String]) {
        self.foodId = foodId
        self.comments = comments
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "评论"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(closePanel))

        table.dataSource = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cmt")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 40
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)

        input.delegate = self
        input.font = .systemFont(ofSize: 14)
        input.layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
        input.layer.borderWidth = 1
        input.layer.cornerRadius = 8
        input.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(input)
        placeholder.text = "添加评论"
        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        input.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 8),
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 6),
            input.heightAnchor.constraint(equalToConstant: 60),
        ])
        placeholder.isHidden = !input.text.isEmpty

        voiceBtn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            voiceBtn.widthAnchor.constraint(equalToConstant: 44),
            voiceBtn.heightAnchor.constraint(equalToConstant: 44),
        ])
        voiceBtn.onStart = { [weak self] in
            guard let self else { return }
            self.voiceBase = self.input.text ?? ""
            VoiceManager.shared.start()
        }
        voiceBtn.onEnd = { VoiceManager.shared.stop() }

        let inputRow = UIStackView(arrangedSubviews: [input, voiceBtn])
        inputRow.axis = .horizontal
        inputRow.alignment = .bottom
        inputRow.spacing = 8
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputRow)

        let save = UIButton(type: .system)
        save.setTitle("保存评论", for: .normal)
        save.setTitleColor(.white, for: .normal)
        save.backgroundColor = Theme.primary
        save.layer.cornerRadius = 10
        save.titleLabel?.font = .boldSystemFont(ofSize: 15)
        save.translatesAutoresizingMaskIntoConstraints = false
        save.addTarget(self, action: #selector(saveComment), for: .touchUpInside)
        view.addSubview(save)

        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: inputRow.topAnchor, constant: -8),
            inputRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            inputRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            inputRow.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -8),
            save.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            save.widthAnchor.constraint(equalToConstant: 180),
            save.heightAnchor.constraint(equalToConstant: 44),
            save.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        VoiceManager.shared.attach(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        VoiceManager.shared.detach(self)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        comments.isEmpty ? 1 : comments.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cmt")!
        if comments.isEmpty {
            var cfg = cell.defaultContentConfiguration()
            cfg.text = "还没有评论"
            cfg.textProperties.alignment = .center
            cfg.textProperties.color = .secondaryLabel
            cell.contentConfiguration = cfg
            return cell
        }
        var cfg = cell.defaultContentConfiguration()
        cfg.text = "· " + comments[indexPath.row]
        cfg.textProperties.numberOfLines = 0
        cell.contentConfiguration = cfg
        return cell
    }

    func textViewDidChange(_ textView: UITextView) { placeholder.isHidden = !textView.text.isEmpty }

    @objc private func closePanel() { dismiss(animated: true) }

    @objc private func saveComment() {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { Toast.show("请输入评论", view); return }
        let newComments = comments + [text]
        Task {
            do {
                _ = try await API.addComment(foodId, comment: newComments)
                await MainActor.run {
                    comments = newComments
                    input.text = ""
                    placeholder.isHidden = false
                    table.reloadData()
                    Toast.show("已评论", view)
                    onSaved?()
                }
            } catch {
                await MainActor.run { Toast.show(error.localizedDescription, view) }
            }
        }
    }

    // MARK: VoiceReceiver（SFSpeech 结果为累计文本，拼接在基串后）

    func voiceDidStop() { voiceBtn.setRecording(false) }
    func voiceDidStart() {
        voiceBtn.setRecording(true)
    }
    func voiceDidRecognize(_ text: String, isFinal: Bool) {
        input.text = voiceBase + text
        placeholder.isHidden = !(input.text?.isEmpty ?? true)
    }
    func voiceDidFail(_ msg: String) {
        voiceBtn.setRecording(false)
        Toast.show(msg, view)
    }
}

// 一次性定位（对齐 wx.getLocation；iOS 为 WGS84 原始坐标）
@MainActor
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    struct Result { let lat: Double; let lng: Double }
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<Result?, Never>?
    private var requested = false

    static func fetch() async -> Result? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }
        let locator = LocationOnce()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                locator.cont = continuation
                locator.manager.delegate = locator
                locator.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                if Task.isCancelled { locator.finish(nil) }
                else { locator.authorize() }
            }
        }, onCancel: { Task { @MainActor in locator.finish(nil) } })
    }

    private func authorize() {
        guard cont != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if !requested { requested = true; manager.requestLocation() }
        default: finish(nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { authorize() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last.map { Result(lat: $0.coordinate.latitude, lng: $0.coordinate.longitude) })
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }

    private func finish(_ result: Result?) {
        let continuation = cont
        cont = nil
        manager.delegate = nil
        manager.stopUpdatingLocation()
        continuation?.resume(returning: result)
    }
}

extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let m = max(size.width, size.height)
        guard m > maxDimension else { return self }
        let scale = maxDimension / m
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

final class Toast {
    static func show(_ text: String, _ view: UIView?) {
        guard let v = view else { return }
        let lb = UILabel()
        lb.text = text
        lb.font = .systemFont(ofSize: 14)
        lb.textColor = .white
        lb.backgroundColor = UIColor(white: 0, alpha: 0.75)
        lb.textAlignment = .center
        lb.layer.cornerRadius = 8
        lb.clipsToBounds = true
        lb.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(lb)
        NSLayoutConstraint.activate([
            lb.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            lb.bottomAnchor.constraint(equalTo: v.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            lb.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            lb.heightAnchor.constraint(equalToConstant: 36),
        ])
        UIView.animate(withDuration: 0.25, delay: 1.2, options: [], animations: { lb.alpha = 0 }) { _ in lb.removeFromSuperview() }
    }
}

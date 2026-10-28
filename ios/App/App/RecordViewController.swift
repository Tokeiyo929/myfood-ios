import UIKit

// 记录 tab：今日记录 + 拍照/相册快速保存
class RecordViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private var table: UITableView!
    private var records: [[String: Any]] = []
    private var config: [String: Any]?

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
        table.rowHeight = 72
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
        loadConfigAndToday()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadToday()
    }

    private func loadConfigAndToday() {
        Task {
            if config == nil {
                config = try? await API.getConfig()
            }
            await loadToday()
        }
    }

    private func loadToday() {
        Task {
            do {
                let limit = (config?["pagination"] as? [String: Any])?["max_page_size"] as? Int ?? 50
                let r = try await API.getFoods(page: 1, limit: limit, today: true)
                records = r["items"] as? [[String: Any]] ?? []
                DispatchQueue.main.async { self.table.reloadData() }
            } catch {}
        }
    }

    @objc private func pickAlbum() { pick(source: .photoLibrary) }
    @objc private func pickCamera() { pick(source: .camera) }

    private func pick(source: UIImagePickerController.SourceType) {
        guard config != nil else { Toast.show("配置加载中", view); return }
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
                // 缩放到最大 320 边 + JPEG 压缩（对齐小程序规则）
                let jpeg = img.resized(maxDimension: 320).jpegData(compressionQuality: 0.8) ?? Data()
                let upload = try await API.uploadImage(jpegData: jpeg)
                var meta = upload["metadata"] as? [String: Any] ?? [:]
                meta["taken_at"] = Self.nowTakenAt()
                let record: [String: Any] = [
                    "name": "", "brand_name": "", "price": NSNull(), "categories": [], "ingredients": [], "flavors": [],
                    "preference": (config?["preferences"] as? [String: Any])?["good"] as? Int ?? 60,
                    "comment": [],
                    "image_path": upload["path"] as? String ?? "",
                    "image_metadata": meta,
                    "client_key": "\(Int(Date().timeIntervalSince1970 * 1000), radix: 36)-\(Int.random(in: 0..<1_000_000), radix: 36)",
                ]
                _ = try await API.submitFood(record)
                DispatchQueue.main.async {
                    Toast.show("已保存", self.view)
                    self.loadToday()
                }
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
        if records.isEmpty { return 1 }
        return records.count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "上传中图片已压缩为320边长缩略图"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        if records.isEmpty {
            cell.textLabel?.text = "今天还没有记录"
            cell.detailTextLabel?.text = "右上角拍照或从相册选"
            return cell
        }
        let rec = records[indexPath.row]
        cell.textLabel?.text = (rec["name"] as? String) ?? "未命名"
        let t = (rec["taken_at"] as? String) ?? (rec["create_at"] as? String) ?? ""
        cell.detailTextLabel?.text = String(t.prefix(16)).replacingOccurrences(of: ":", with: ":", options: [], range: t.range(of: "^\\d{4}:\\d{2}:\\d{2}", options: .regularExpression))
        cell.imageView?.image = nil
        if let path = rec["image_path"] as? String, let url = API.imageUrl(path) {
            let task = URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data else { return }
                DispatchQueue.main.async {
                    if let img = UIImage(data: data) { cell.imageView?.image = img }
                    tableView.reloadRows(at: [indexPath], with: .none)
                }
            }
            task.resume()
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !records.isEmpty else { return }
        guard let id = records[indexPath.row]["id"] as? Int else { return }
        let d = DetailViewController(foodId: id)
        navigationController?.pushViewController(d, animated: true)
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
        lb.layer.padding(10)
        UIView.animate(withDuration: 0.25, delay: 1.2, options: [], animations: { lb.alpha = 0 }) { _ in lb.removeFromSuperview() }
    }
}

extension CALayer {
    func padding(_ p: CGFloat) {}
}

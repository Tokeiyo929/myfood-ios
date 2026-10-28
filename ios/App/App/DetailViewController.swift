import UIKit

// 详情页：图片 + 字段 + 评论 + 编辑/删除
class DetailViewController: UIViewController {
    private let foodId: Int
    private var food: [String: Any]?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    init(foodId: Int) {
        self.foodId = foodId
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
        ])
        load()
    }

    private func load() {
        Task {
            food = try? await API.getFoodById(foodId)
            DispatchQueue.main.async { self.render() }
        }
    }

    private func row(_ label: String, _ value: String) -> UIView {
        let l = UILabel()
        l.text = label
        l.font = .boldSystemFont(ofSize: 14)
        l.setContentHuggingPriority(.required, for: .horizontal)
        let v = UILabel()
        v.text = value
        v.font = .systemFont(ofSize: 14)
        v.textColor = .secondaryLabel
        v.numberOfLines = 0
        let s = UIStackView(arrangedSubviews: [l, v])
        s.axis = .horizontal
        s.spacing = 12
        return s
    }

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let f = food else {
            let l = UILabel(); l.text = "加载失败"; stack.addArrangedSubview(l); return
        }
        let name = UILabel()
        name.text = (f["name"] as? String) ?? "未命名"
        name.font = .boldSystemFont(ofSize: 22)
        stack.addArrangedSubview(name)

        let t = (f["taken_at"] as? String) ?? (f["create_at"] as? String) ?? ""
        let meta = UILabel()
        meta.text = t
        meta.font = .systemFont(ofSize: 13)
        meta.textColor = .secondaryLabel
        stack.addArrangedSubview(meta)

        if let path = f["image_path"] as? String, let url = API.imageUrl(path) {
            let imgView = UIImageView()
            imgView.contentMode = .scaleAspectFill
            imgView.clipsToBounds = true
            imgView.layer.cornerRadius = 12
            imgView.heightAnchor.constraint(equalToConstant: 220).isActive = true
            stack.addArrangedSubview(imgView)
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data else { return }
                DispatchQueue.main.async { imgView.image = UIImage(data: data) }
            }.resume()
        }

        if let price = f["price"] as? [Any?] {
            let parts = price.map { p -> String in
                if let n = p as? NSNumber { return "\(n)" }
                return "—"
            }
            stack.addArrangedSubview(row("价格", parts.joined(separator: " / ")))
        }
        if let brand = f["brand_name"] as? String, !brand.isEmpty {
            stack.addArrangedSubview(row("品牌", brand))
        }
        if let cats = f["categories"] as? [String], !cats.isEmpty {
            stack.addArrangedSubview(row("类别", cats.joined(separator: "、")))
        }
        if let ing = f["ingredients"] as? [[String: Any]], !ing.isEmpty {
            let txt = ing.compactMap { i -> String? in
                guard let n = i["name"] as? String else { return nil }
                if let a = i["amount"] as? String, !a.isEmpty { return "\(n)(\(a))" }
                return n
            }.joined(separator: "、")
            stack.addArrangedSubview(row("原料", txt))
        }

        if let comments = f["comment"] as? [String], !comments.isEmpty {
            let title = UILabel()
            title.text = "评论"
            title.font = .boldSystemFont(ofSize: 15)
            stack.addArrangedSubview(title)
            for c in comments {
                let l = UILabel()
                l.text = c
                l.font = .systemFont(ofSize: 14)
                l.numberOfLines = 0
                l.backgroundColor = UIColor(white: 0.95, alpha: 1)
                l.layer.cornerRadius = 8
                stack.addArrangedSubview(l)
            }
        }

        let btns = UIStackView(arrangedSubviews: [
            self.button("编辑", style: "primary", action: #selector(self.editTapped)),
            self.button("删除", style: "danger", action: #selector(self.deleteTapped)),
        ])
        btns.axis = .horizontal
        btns.spacing = 12
        btns.distribution = .fillEqually
        stack.addArrangedSubview(btns)
    }

    @objc private func editTapped() {
        guard let f = food else { return }
        navigationController?.pushViewController(EditViewController(food: f, onSaved: { [weak self] in
            self?.load()
        }), animated: true)
    }

    @objc private func deleteTapped() {
        let alert = UIAlertController(title: nil, message: "确定删除这条记录吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            Task {
                try? await API.deleteFood(self.foodId)
                DispatchQueue.main.async { self.navigationController?.popViewController(animated: true) }
            }
        })
        present(alert, animated: true)
    }

    private func button(_ title: String, style: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        b.layer.cornerRadius = 10
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        if style == "primary" {
            b.backgroundColor = UIColor(red: 0.4, green: 0.31, blue: 0.56, alpha: 1)
            b.setTitleColor(.white, for: .normal)
        } else if style == "danger" {
            b.backgroundColor = UIColor(white: 0.95, alpha: 1)
            b.setTitleColor(.systemRed, for: .normal)
        } else {
            b.backgroundColor = UIColor(white: 0.95, alpha: 1)
        }
        return b
    }
}

// 编辑页
class EditViewController: UIViewController {
    private let food: [String: Any]
    private let onSaved: () -> Void
    private let stack = UIStackView()
    private var nameField: UITextField!
    private var brandField: UITextField!
    private var origField: UITextField!
    private var discField: UITextField!
    private var catsField: UITextField!

    init(food: [String: Any], onSaved: @escaping () -> Void) {
        self.food = food
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
        title = "编辑"
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        nameField = field("食物名称", value: food["name"] as? String)
        brandField = field("品牌", value: food["brand_name"] as? String)
        let price = food["price"] as? [Any?]
        origField = field("原价", value: num(price?.count ?? 0 > 0 ? price?[0] : nil))
        discField = field("折扣价", value: num(price?.count ?? 0 > 1 ? price?[1] : nil))
        catsField = field("类别(逗号分隔)", value: (food["categories"] as? [String])?.joined(separator: ","))
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(brandField)
        stack.addArrangedSubview(origField)
        stack.addArrangedSubview(discField)
        stack.addArrangedSubview(catsField)
        let save = UIButton(type: .system)
        save.setTitle("保存", for: .normal)
        save.backgroundColor = UIColor(red: 0.4, green: 0.31, blue: 0.56, alpha: 1)
        save.setTitleColor(.white, for: .normal)
        save.layer.cornerRadius = 10
        save.heightAnchor.constraint(equalToConstant: 44).isActive = true
        save.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        stack.addArrangedSubview(save)
    }

    private func num(_ v: Any?) -> String {
        guard let n = v as? NSNumber else { return "" }
        return n.stringValue
    }

    private func field(_ ph: String, value: String?) -> UITextField {
        let f = UITextField()
        f.placeholder = ph
        f.text = value ?? ""
        f.borderStyle = .roundedRect
        f.font = .systemFont(ofSize: 15)
        f.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return f
    }

    @objc private func saveTapped() {
        func nullableNumber(_ s: String) -> Any { s.isEmpty ? NSNull() : NSNumber(value: Double(s) ?? 0) }
        let cats = catsField.text!.split(whereSeparator: { ",，、".contains($0) }).map(String.init).filter { !$0.isEmpty }
        let fields: [String: Any] = [
            "name": nameField.text!.trimmingCharacters(in: .whitespaces),
            "brand_name": brandField.text!.trimmingCharacters(in: .whitespaces),
            "price": [nullableNumber(origField.text!.trimmingCharacters(in: .whitespaces)),
                       nullableNumber(discField.text!.trimmingCharacters(in: .whitespaces))],
            "categories": cats,
        ]
        Task {
            do { _ = try await API.updateFoodDetails(food["id"] as! Int, fields: fields)
                DispatchQueue.main.async {
                    self.onSaved()
                    self.navigationController?.popViewController(animated: true)
                }
            } catch {
                DispatchQueue.main.async { Toast.show(error.localizedDescription, self.view) }
            }
        }
    }
}

import UIKit

// 设置 tab：极简，只显示后端地址和说明
class SettingsViewController: UIViewController {
    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        func card(_ t: String, _ s: String) -> UIView {
            let box = UIView()
            box.backgroundColor = UIColor(white: 0.96, alpha: 1)
            box.layer.cornerRadius = 12
            let title = UILabel()
            title.text = t
            title.font = .boldSystemFont(ofSize: 15)
            let sub = UILabel()
            sub.text = s
            sub.font = .systemFont(ofSize: 13)
            sub.textColor = .secondaryLabel
            sub.numberOfLines = 0
            let col = UIStackView(arrangedSubviews: [title, sub])
            col.axis = .vertical
            col.spacing = 4
            col.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
                col.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
                col.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
                col.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            ])
            return box
        }

        stack.addArrangedSubview(card("后端", BASE_URL))
        stack.addArrangedSubview(card("定位说明", "开始记录后请在系统提示中选择「允许」并设为「始终允许」，锁屏也能持续记录轨迹"))

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }
}

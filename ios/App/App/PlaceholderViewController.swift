import UIKit

// 更多 tab：占位页（凑对称五 tab），后续可替换为真实功能页
class PlaceholderViewController: UIViewController {
    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "更多"
        let label = UILabel()
        label.text = "敬请期待"
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

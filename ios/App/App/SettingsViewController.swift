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
        stack.addArrangedSubview(card("定位说明", "轨迹默认自动记录：启动后请在系统弹窗中选择「允许」，并设为「始终允许」可锁屏持续记录"))

        // 离线同步状态：有待同步数据时展示数量，可手动立即同步
        let pending = OfflineStore.pendingCount()
        if pending > 0 {
            let syncCard = card("离线同步", "有 \(pending) 条修改待同步，联网后自动上传")
            let syncBtn = UIButton(type: .system)
            syncBtn.setTitle("立即同步", for: .normal)
            syncBtn.setTitleColor(Theme.primary, for: .normal)
            syncBtn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            syncBtn.layer.cornerRadius = 8
            syncBtn.layer.borderWidth = 1
            syncBtn.layer.borderColor = Theme.primary.withAlphaComponent(0.5).cgColor
            syncBtn.addAction(UIAction { _ in
                syncBtn.setTitle("同步中…", for: .normal)
                Task {
                    await SyncEngine.drain()
                    syncBtn.setTitle(OfflineStore.pendingCount() > 0 ? "仍有待同步项" : "已同步", for: .normal)
                }
            }, for: .touchUpInside)
            syncCard.addSubview(syncBtn)
            syncBtn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                syncBtn.trailingAnchor.constraint(equalTo: syncCard.trailingAnchor, constant: -14),
                syncBtn.centerYAnchor.constraint(equalTo: syncCard.centerYAnchor),
            ])
            stack.addArrangedSubview(syncCard)
        }
        stack.addArrangedSubview(card("离线能力", "断网时可浏览缓存数据；建档/编辑/删除/换图/排名会本地保存，恢复联网后自动同步"))

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }
}

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

        // 手动同步：上传离线队列 + 拉取服务端最新数据（记录/类别/摘抄/配置）
        let syncBox = UIView()
        syncBox.backgroundColor = UIColor(white: 0.96, alpha: 1)
        syncBox.layer.cornerRadius = 12
        let syncTitle = UILabel()
        syncTitle.text = "手动同步"
        syncTitle.font = .boldSystemFont(ofSize: 15)
        let syncSub = UILabel()
        syncSub.font = .systemFont(ofSize: 13)
        syncSub.textColor = .secondaryLabel
        syncSub.numberOfLines = 0
        let syncCol = UIStackView(arrangedSubviews: [syncTitle, syncSub])
        syncCol.axis = .vertical
        syncCol.spacing = 4
        syncCol.translatesAutoresizingMaskIntoConstraints = false
        syncBox.addSubview(syncCol)
        let syncBtn = UIButton(type: .system)
        syncBtn.setTitle("同步", for: .normal)
        syncBtn.setTitleColor(.white, for: .normal)
        syncBtn.backgroundColor = Theme.primary
        syncBtn.titleLabel?.font = .boldSystemFont(ofSize: 14)
        syncBtn.layer.cornerRadius = 8
        syncBtn.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        syncBtn.addAction(UIAction { [weak self] _ in
            guard syncBtn.isEnabled else { return }
            syncBtn.isEnabled = false
            syncBtn.setTitle("同步中…", for: .normal)
            Task {
                await self?.runManualSync()
                let pending = OfflineStore.pendingCount()
                syncBtn.isEnabled = true
                syncBtn.setTitle("同步", for: .normal)
                syncSub.text = pending > 0 ? "仍有 \(pending) 条待上传，可再试" : "已同步完成"
            }
        }, for: .touchUpInside)
        syncBox.addSubview(syncBtn)
        syncBtn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            syncCol.topAnchor.constraint(equalTo: syncBox.topAnchor, constant: 12),
            syncCol.leadingAnchor.constraint(equalTo: syncBox.leadingAnchor, constant: 14),
            syncCol.bottomAnchor.constraint(equalTo: syncBox.bottomAnchor, constant: -12),
            syncCol.trailingAnchor.constraint(equalTo: syncBtn.leadingAnchor, constant: -10),
            syncBtn.trailingAnchor.constraint(equalTo: syncBox.trailingAnchor, constant: -14),
            syncBtn.centerYAnchor.constraint(equalTo: syncBox.centerYAnchor),
        ])
        syncSub.text = OfflineStore.pendingCount() > 0 ? "有 \(OfflineStore.pendingCount()) 条离线修改待上传" : "把离线修改上传，并拉取服务端最新数据"
        stack.addArrangedSubview(syncBox)
        stack.addArrangedSubview(card("离线能力", "断网时可浏览缓存数据；建档/编辑/删除/换图/排名/摘抄会本地保存，恢复联网后自动同步"))

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    // 手动同步：先排空离线队列（上传），再拉取服务端最新数据；完成后广播让各页刷新
    private func runManualSync() async {
        await SyncEngine.drain()
        do {
            let config = try await AppConfig.load()
            let foods = try await API.getAllFoods(limit: config.maxPageSize)
            OfflineStore.rebuildRecords(foods)
            let cats = try await API.getCategories()
            OfflineStore.saveCategories(cats["items"] as? [[String: Any]] ?? [])
            let quotes = try await API.getQuotes()
            OfflineStore.rebuildQuotes(quotes["items"] as? [[String: Any]] ?? [])
            AppConfig.shared = config
            NotificationCenter.default.post(name: .myfoodDataSynced, object: nil)
            Toast.show("同步完成", view)
        } catch {
            Toast.show("拉取最新数据失败：\(error.localizedDescription)", view)
        }
    }
}

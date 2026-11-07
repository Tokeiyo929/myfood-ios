import UIKit

// 好词好句摘抄页（原「更多」占位页）：记录喜欢的句子，支持离线增删、联网自动同步
class QuotesViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
    private var table: UITableView!
    private var quoteInput: UITextView!
    private var placeholderLabel: UILabel!
    private var saveBtn: UIButton!
    private var statusLabel: UILabel!
    private var quotes: [[String: Any]] = []
    private var needsRefresh = true
    private(set) var loaded = false

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
        dismissKeyboardOnBackgroundTap() // 点空白处收起键盘
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "摘抄"
        buildUI()
        // 手动同步（设置页）完成后，回到本页自动刷新
        NotificationCenter.default.addObserver(forName: .myfoodDataSynced, object: nil, queue: .main) { [weak self] _ in
            self?.needsRefresh = true
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if needsRefresh { needsRefresh = false; load() }
    }

    private func buildUI() {
        statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        table = UITableView(frame: .zero, style: .plain)
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        table.keyboardDismissMode = .onDrag
        table.register(QuoteCardCell.self, forCellReuseIdentifier: "qcard")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 90
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(refresh), for: .valueChanged)
        table.refreshControl = rc

        quoteInput = UITextView()
        quoteInput.font = .systemFont(ofSize: 14)
        quoteInput.layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
        quoteInput.layer.borderWidth = 1
        quoteInput.layer.cornerRadius = 8
        quoteInput.translatesAutoresizingMaskIntoConstraints = false
        quoteInput.delegate = self
        view.addSubview(quoteInput)

        placeholderLabel = UILabel()
        placeholderLabel.text = "记下一句打动你的话…"
        placeholderLabel.font = .systemFont(ofSize: 14)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteInput.addSubview(placeholderLabel)
        placeholderLabel.topAnchor.constraint(equalTo: quoteInput.topAnchor, constant: 8).isActive = true
        placeholderLabel.leadingAnchor.constraint(equalTo: quoteInput.leadingAnchor, constant: 6).isActive = true

        saveBtn = UIButton(type: .system)
        saveBtn.setTitle("保存", for: .normal)
        saveBtn.backgroundColor = Theme.primary
        saveBtn.setTitleColor(.white, for: .normal)
        saveBtn.layer.cornerRadius = 8
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        saveBtn.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        view.addSubview(saveBtn)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            table.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: quoteInput.topAnchor, constant: -8),
            quoteInput.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            quoteInput.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -8),
            quoteInput.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            quoteInput.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            quoteInput.heightAnchor.constraint(lessThanOrEqualToConstant: 120),
            saveBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            saveBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            saveBtn.widthAnchor.constraint(equalToConstant: 72),
            saveBtn.heightAnchor.constraint(equalToConstant: 60),
        ])
    }

    @objc private func refresh() { load() }

    private func load() {
        Task {
            do {
                let r = try await API.getQuotes()
                let items = r["items"] as? [[String: Any]] ?? []
                OfflineStore.rebuildQuotes(items)
                loaded = true
                reloadFromCache()
                statusLabel.text = ""
            } catch {
                let cached = OfflineStore.cachedQuotes()
                if !cached.isEmpty {
                    loaded = true
                    reloadFromCache()
                    statusLabel.text = "离线数据（可能不是最新）"
                } else {
                    statusLabel.text = "加载失败，请检查网络"
                    table.refreshControl?.endRefreshing()
                }
            }
        }
    }

    private func reloadFromCache() {
        quotes = OfflineStore.cachedQuotes()
        table.reloadData()
        table.refreshControl?.endRefreshing()
    }

    @objc private func saveTapped() {
        let text = (quoteInput.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { Toast.show("先写点什么", view); return }
        saveBtn.isEnabled = false
        Task {
            defer { saveBtn.isEnabled = true }
            let clientKey = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + "-" + String(Int.random(in: 0..<1_000_000), radix: 36)
            do {
                let res = try await API.createQuote(text: text, note: "", clientKey: clientKey)
                let id = res["id"] as? Int ?? OfflineStore.allocateLocalQuoteId()
                OfflineStore.upsertQuote(["id": id, "text": text, "note": "", "day": OfflineStore.todayString()])
                finishSave()
            } catch {
                guard isNetworkError(error) else { Toast.show(error.localizedDescription, view); return }
                // 断网摘抄：本地负数 id 记录 + 入队，恢复联网自动上传
                let localId = OfflineStore.allocateLocalQuoteId()
                OfflineStore.upsertQuote(["id": localId, "text": text, "note": "", "day": OfflineStore.todayString(), "client_key": clientKey])
                let payload: [String: Any] = ["text": text, "note": "", "client_key": clientKey]
                OfflineStore.enqueue(.quoteCreate(record: payload, clientKey: clientKey, localId: localId))
                finishSave()
                Toast.show("已离线保存，联网后自动同步", view)
            }
        }
    }

    private func finishSave() {
        quoteInput.text = ""
        placeholderLabel.isHidden = false
        reloadFromCache()
        if !quotes.isEmpty {
            table.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !(textView.text?.isEmpty ?? true)
    }

    // MARK: table
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        quotes.isEmpty ? 1 : quotes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if quotes.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "qempty") ?? UITableViewCell(style: .default, reuseIdentifier: "qempty")
            var cfg = cell.defaultContentConfiguration()
            cfg.text = loaded ? "还没有摘抄，记下第一句吧" : "加载中…"
            cfg.textProperties.alignment = .center
            cell.contentConfiguration = cfg
            cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "qcard") as! QuoteCardCell
        cell.bind(quotes[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !quotes.isEmpty else { return nil }
        let quote = quotes[indexPath.row]
        let del = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            self?.confirmDelete(quote)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [del])
    }

    private func confirmDelete(_ quote: [String: Any]) {
        let alert = UIAlertController(title: "删除摘抄", message: "确定要删除这句摘抄吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            Task { await self.deleteQuote(quote) }
        })
        present(alert, animated: true)
    }

    private func deleteQuote(_ quote: [String: Any]) async {
        guard let id = quote["id"] as? Int else { return }
        do {
            _ = try await API.deleteQuote(id)
            OfflineStore.removeQuote(id: id)
        } catch {
            guard isNetworkError(error) else { Toast.show(error.localizedDescription, view); return }
            if id > 0 {
                OfflineStore.enqueue(.quoteDelete(serverId: id))
                OfflineStore.removeQuote(id: id)
            } else if let key = quote["client_key"] as? String {
                // 本地未同步摘抄：连同 create 队列项一起撤销
                OfflineStore.cancelPendingQuoteCreate(clientKey: key)
                OfflineStore.removeQuote(id: id)
            }
            Toast.show("已离线删除，联网后同步", view)
        }
        reloadFromCache()
    }
}

// 摘抄卡片：句子 + 日期（复购卡片的圆角卡片样式）
class QuoteCardCell: UITableViewCell {
    private let card = UIView()
    private let textLabel_ = UILabel()
    private let dayLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.backgroundColor = .white
        card.layer.cornerRadius = 12
        card.layer.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        textLabel_.font = .systemFont(ofSize: 15)
        textLabel_.numberOfLines = 0
        textLabel_.textColor = .label
        textLabel_.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(textLabel_)

        dayLabel.font = .systemFont(ofSize: 12)
        dayLabel.textColor = .secondaryLabel
        dayLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(dayLabel)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            textLabel_.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            textLabel_.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            textLabel_.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            dayLabel.topAnchor.constraint(equalTo: textLabel_.bottomAnchor, constant: 6),
            dayLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            dayLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func bind(_ quote: [String: Any]) {
        textLabel_.text = quote["text"] as? String ?? ""
        dayLabel.text = quote["day"] as? String ?? ""
    }
}

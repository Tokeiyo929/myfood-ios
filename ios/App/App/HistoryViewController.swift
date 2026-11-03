import UIKit

// 历史 tab：搜索 + 分页卡片列表（对齐小程序 history 页）
class HistoryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    var onRecordsChanged: (() -> Void)?
    func markNeedsRefresh() { needsRefresh = true }
    private var table: UITableView!
    private var searchBar: UISearchBar!
    private var records: [DecoratedRecord] = []
    private var search = ""
    private var page = 1
    private var hasMore = true
    private(set) var loading = false
    private(set) var loaded = false
    private var needsRefresh = true
    private var generation = 0
    #if DEBUG
    private(set) var completedLoads = 0
    var recordIDs: [Int] { records.map { $0.id } }
    #endif
    private var searchTask: Task<Void, Never>?
    private let backTop = UIButton(type: .system)

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "历史"
        searchBar = UISearchBar()
        searchBar.placeholder = "搜索名称/品牌"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        table = UITableView(frame: .zero, style: .plain)
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        table.register(HistoryCardCell.self, forCellReuseIdentifier: "hcard")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 110
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(refresh), for: .valueChanged)
        table.refreshControl = rc

        backTop.setTitle("↑ 顶部", for: .normal)
        backTop.backgroundColor = Theme.primary
        backTop.setTitleColor(.white, for: .normal)
        backTop.layer.cornerRadius = 18
        backTop.alpha = 0
        backTop.translatesAutoresizingMaskIntoConstraints = false
        backTop.addTarget(self, action: #selector(goTop), for: .touchUpInside)
        view.addSubview(backTop)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            table.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backTop.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            backTop.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            backTop.widthAnchor.constraint(equalToConstant: 76),
            backTop.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @objc private func refresh() {
        Task { await loadRecords(reset: true) }
    }

    @objc private func goTop() {
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if needsRefresh {
            needsRefresh = false
            Task { await loadRecords(reset: true) }
        }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            search = searchText
            await loadRecords(reset: true)
        }
    }

    private func loadRecords(reset: Bool) async {
        if !reset && loading { return }
        generation += 1
        let requestGeneration = generation
        let query = search
        loading = true
        loaded = false
        defer {
            #if DEBUG
            completedLoads += 1
            #endif
            if generation == requestGeneration {
                loading = false
                table.refreshControl?.endRefreshing()
            }
        }
        let reqPage = reset ? 1 : page + 1
        do {
            let config = try await AppConfig.load()
            let limit = config.pageSize
            let r = try await API.getFoods(page: reqPage, limit: limit, search: query)
            guard requestGeneration == generation else { return }
            let items = (r["items"] as! [[String: Any]]).map { AppConfig.decorate($0) }
            let total = r["total"] as! Int
            loaded = true
            records = reset ? items : records + items
            page = reqPage
            hasMore = records.count < total
            table.reloadData()
        } catch {
            guard requestGeneration == generation else { return }
            Toast.show(error.localizedDescription, view)
        }
    }

    // MARK: table
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.isEmpty ? 1 : records.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if records.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "hempty") ?? UITableViewCell(style: .default, reuseIdentifier: "hempty")
            var cfg = cell.defaultContentConfiguration()
            cfg.text = loading ? "加载中…" : "暂无记录"
            cfg.textProperties.alignment = .center
            cell.contentConfiguration = cfg
            cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "hcard") as! HistoryCardCell
        cell.bind(records[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if !records.isEmpty && hasMore && indexPath.row >= records.count - 3 {
            Task { await loadRecords(reset: false) }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let show = scrollView.contentOffset.y > 400
        UIView.animate(withDuration: 0.2) { self.backTop.alpha = show ? 1 : 0 }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !records.isEmpty else { return }
        let d = DetailViewController(foodId: records[indexPath.row].id)
        d.onChanged = { [weak self] in self?.needsRefresh = true; self?.onRecordsChanged?() }
        navigationController?.pushViewController(d, animated: true)
    }

    // SmokeTour 用：打开第一条记录
    func smokeOpenFirst() {
        tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
    }
}

// 记录卡片：图 + 名称/品牌 + 味道标签 + 材料标签 + 复购（对齐小程序 record-card）
class HistoryCardCell: UITableViewCell {
    private let card = UIView()
    private let imgView = UIImageView()
    private let nameLabel = UILabel()
    private let flavorRow = UILabel()
    private let ingRow = UILabel()
    private let repurchaseLabel = UILabel()

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

        imgView.contentMode = .scaleAspectFill
        imgView.clipsToBounds = true
        imgView.layer.cornerRadius = 10
        imgView.backgroundColor = UIColor(white: 0.93, alpha: 1)
        imgView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(imgView)

        nameLabel.font = .boldSystemFont(ofSize: 15)
        flavorRow.font = .systemFont(ofSize: 12)
        flavorRow.textColor = Theme.primary
        ingRow.font = .systemFont(ofSize: 12)
        ingRow.textColor = Theme.primary
        repurchaseLabel.font = .systemFont(ofSize: 12)
        repurchaseLabel.textColor = .secondaryLabel

        let info = UIStackView(arrangedSubviews: [nameLabel, flavorRow, ingRow, repurchaseLabel])
        info.axis = .vertical
        info.spacing = 4
        info.setCustomSpacing(6, after: nameLabel)
        info.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(info)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            imgView.widthAnchor.constraint(equalToConstant: 80),
            imgView.heightAnchor.constraint(equalToConstant: 80),
            imgView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            imgView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            info.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 12),
            info.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            info.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            info.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func bind(_ d: DecoratedRecord) {
        let title = NSMutableAttributedString(
            string: d.name.isEmpty ? "未命名" : d.name,
            attributes: [.font: UIFont.boldSystemFont(ofSize: 15), .foregroundColor: UIColor.label])
        if !d.brand.isEmpty {
            title.append(NSAttributedString(string: " - \(d.brand)", attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel]))
        }
        nameLabel.attributedText = title
        flavorRow.text = d.flavorLabels.isEmpty ? "" : "味道：" + d.flavorLabels.joined(separator: " ")
        ingRow.text = d.ingredientLabels.isEmpty ? "" : "材料：" + d.ingredientLabels.joined(separator: " ")
        repurchaseLabel.text = d.repurchase > 0 ? "复购\(d.repurchase)次" : ""
        for l in [flavorRow, ingRow, repurchaseLabel] { l.isHidden = (l.text ?? "").isEmpty }
        addLeftBorder(color: d.prefBorderColor ?? Theme.border)
        ImageLoader.shared.load(API.imageUrl(d.imagePath), into: imgView)
    }

    private var leftBar: UIView?
    private func addLeftBorder(color: UIColor) {
        if let leftBar { leftBar.backgroundColor = color; return }
        let bar = UIView()
        bar.backgroundColor = color
        bar.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            bar.topAnchor.constraint(equalTo: card.topAnchor),
            bar.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 4),
        ])
        leftBar = bar
    }
}

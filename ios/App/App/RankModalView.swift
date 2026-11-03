import UIKit

// 类别排行榜弹窗（对齐小程序 rank-panel）：
// 长按条目拖到另一条上交换排名，边缘自动滚动，松手 PATCH category_rank
final class RankModalView: UIView, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {

    var onClose: (() -> Void)?
    var onApplyRank: (([[String: Any]]) async throws -> Void)?
    private var saving = false
    private let retry = UIButton(type: .system)

    private let category: String
    private var foods: [[String: Any]]
    private let table = UITableView()

    // 拖拽状态
    private var dragIndex = -1
    private var overIndex = -1
    private var dragSnapshot: UIView?
    private var grabOffset: CGFloat = 0
    private var lastTouchY: CGFloat = 0
    private var autoDir = 0
    private var autoTimer: Timer?

    private let panel = UIView()
    private let hint = UILabel()

    init(category: String, foods: [[String: Any]]) {
        self.category = category
        self.foods = foods
        super.init(frame: .zero)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        backgroundColor = UIColor(white: 0, alpha: 0.45)

        let tap = UITapGestureRecognizer(target: self, action: #selector(maskTapped))
        tap.delegate = self
        addGestureRecognizer(tap)

        panel.backgroundColor = .white
        panel.layer.cornerRadius = 12
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.layer.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        panel.isUserInteractionEnabled = true

        let title = UILabel()
        title.text = "\(category) · 排行榜"
        title.font = .boldSystemFont(ofSize: 16)
        let close = UIButton(type: .system)
        close.setTitle("×", for: .normal)
        close.titleLabel?.font = .boldSystemFont(ofSize: 20)
        close.setTitleColor(.secondaryLabel, for: .normal)
        close.addAction(UIAction(handler: { [weak self] _ in self?.close() }), for: .touchUpInside)
        let head = UIStackView(arrangedSubviews: [title, UIView(), close])
        retry.setTitle("重试保存", for: .normal)
        retry.isHidden = true
        retry.addAction(UIAction { [weak self] _ in self?.saveOrder() }, for: .touchUpInside)
        head.insertArrangedSubview(retry, at: 1)
        head.translatesAutoresizingMaskIntoConstraints = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        head.axis = .horizontal

        hint.text = "长按条目拖到另一条上，交换排名"
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabel

        table.dataSource = self
        table.delegate = self
        table.register(RankCell.self, forCellReuseIdentifier: "rank")
        table.separatorStyle = .none
        table.translatesAutoresizingMaskIntoConstraints = false
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(dragGesture(_:)))
        lp.minimumPressDuration = 0.35
        table.addGestureRecognizer(lp)

        panel.addSubview(head)
        panel.addSubview(hint)
        panel.addSubview(table)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.62),
            head.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            head.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            hint.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            table.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            table.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            table.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 底部弹起效果
        if window != nil {
            panel.transform = CGAffineTransform(translationX: 0, y: panel.frame.height)
            UIView.animate(withDuration: 0.25) { self.panel.transform = .identity }
        }
    }

    @objc private func maskTapped() {
        if dragIndex >= 0 { return } // 拖动中不关（对齐 closeRankModal）
        close()
    }

    func close() {
        guard !saving else { return }
        stopAutoScroll()
        onClose?()
        UIView.animate(withDuration: 0.2, animations: {
            self.backgroundColor = UIColor(white: 0, alpha: 0)
            self.panel.transform = CGAffineTransform(translationX: 0, y: self.panel.frame.height)
        }, completion: { _ in self.removeFromSuperview() })
    }

    // MARK: - 拖拽（对齐 onRankLongPress / onRankTouchMove / onRankTouchEnd）

    @objc private func dragGesture(_ g: UILongPressGestureRecognizer) {
        guard !saving, retry.isHidden else { return }
        let loc = g.location(in: self)
        lastTouchY = loc.y
        switch g.state {
        case .began:
            guard let p = table.indexPathForRow(at: g.location(in: table)) else { return }
            dragIndex = p.row
            overIndex = p.row
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if let cell = table.cellForRow(at: p) {
                let snap = cell.snapshotView(afterScreenUpdates: true)
                if let snap {
                    snap.frame = cell.convert(cell.bounds, to: self)
                    grabOffset = loc.y - snap.center.y
                    addSubview(snap)
                    dragSnapshot = snap
                }
                cell.contentView.alpha = 0.35
            }
            highlightOver()
            startAutoScrollIfNeeded()
        case .changed:
            guard let snap = dragSnapshot, dragIndex >= 0 else { return }
            snap.center.y = loc.y - grabOffset
            // 命中行 → overIndex 高亮（对齐 updateOverFromTouch）
            let tp = table.convert(loc, from: self)
            if let p = table.indexPathForRow(at: tp), p.row != overIndex {
                clearOverHighlight()
                overIndex = p.row
                highlightOver()
            }
            startAutoScrollIfNeeded()
        default:
            endDrag(apply: g.state == .ended)
        }
    }

    private func endDrag(apply: Bool) {
        guard dragIndex >= 0 else { return }
        stopAutoScroll()
        dragSnapshot?.removeFromSuperview()
        dragSnapshot = nil
        let from = dragIndex
        let to = overIndex
        dragIndex = -1
        overIndex = -1
        table.reloadData()
        guard apply, to >= 0, to != from, from < foods.count, to < foods.count else { return }
        // 交换（对齐 onRankTouchEnd：list[from] ↔ list[to]）
        foods.swapAt(from, to)
        table.reloadData()
        saveOrder()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === self
    }

    private func saveOrder() {
        guard !saving, let onApplyRank else { return }
        saving = true
        table.isUserInteractionEnabled = false
        retry.isEnabled = false
        hint.text = "保存中…"
        Task {
            defer { saving = false; table.isUserInteractionEnabled = true; retry.isEnabled = true }
            do {
                try await onApplyRank(foods)
                for index in foods.indices {
                    var ranks = foods[index]["category_rank"] as? [String: Any] ?? [:]
                    ranks[category] = index + 1
                    foods[index]["category_rank"] = ranks
                }
                retry.isHidden = true
                hint.text = "已保存；长按交换排名"
            } catch {
                retry.isHidden = false
                hint.text = "排名未全部保存，请重试"
                Toast.show(error.localizedDescription, self)
            }
        }
    }

    private func highlightOver() {
        guard dragIndex >= 0, overIndex >= 0, overIndex != dragIndex,
              let cell = table.cellForRow(at: IndexPath(row: overIndex, section: 0)) else { return }
        cell.layer.borderColor = Theme.primary.cgColor
        cell.layer.borderWidth = 2
    }

    private func clearOverHighlight() {
        guard overIndex >= 0,
              let cell = table.cellForRow(at: IndexPath(row: overIndex, section: 0)) else { return }
        cell.layer.borderWidth = 0
    }

    // 边缘自动滚动（对齐 startAutoScroll：±48pt 内，每 50ms 12pt）
    private func startAutoScrollIfNeeded() {
        guard dragIndex >= 0 else { return }
        let tableY = convert(CGPoint(x: 0, y: lastTouchY), to: table).y
        let dir: Int
        if tableY < 48 { dir = -1 }
        else if tableY > table.bounds.height - 48 { dir = 1 }
        else { dir = 0 }
        if dir == autoDir { return }
        stopAutoScroll()
        guard dir != 0 else { return }
        autoDir = dir
        autoTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let target = max(0, min(self.table.contentSize.height - self.table.bounds.height + 40,
                                    self.table.contentOffset.y + CGFloat(self.autoDir) * 12))
            self.table.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }
    }

    private func stopAutoScroll() {
        autoTimer?.invalidate()
        autoTimer = nil
        autoDir = 0
    }

    // MARK: - table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        foods.isEmpty ? 1 : foods.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if foods.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "rankempty") ?? UITableViewCell(style: .default, reuseIdentifier: "rankempty")
            var cfg = cell.defaultContentConfiguration()
            cfg.text = "该类别还没有记录"
            cfg.textProperties.alignment = .center
            cell.contentConfiguration = cfg
            cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "rank") as! RankCell
        cell.bind(index: indexPath.row, food: foods[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 62 }
}

// 排行榜条目：名次 + 图 + 名称/品牌/复购（对齐 rank-item）
private final class RankCell: UITableViewCell {
    private let noLabel = UILabel()
    private let imgView = UIImageView()
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = UIColor(white: 0.97, alpha: 1)
        contentView.layer.cornerRadius = 10
        contentView.layer.masksToBounds = true

        noLabel.font = .boldSystemFont(ofSize: 15)
        noLabel.textColor = Theme.primary
        noLabel.translatesAutoresizingMaskIntoConstraints = false

        imgView.contentMode = .scaleAspectFill
        imgView.clipsToBounds = true
        imgView.layer.cornerRadius = 8
        imgView.backgroundColor = UIColor(white: 0.92, alpha: 1)
        imgView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        metaLabel.font = .systemFont(ofSize: 12)
        metaLabel.textColor = .secondaryLabel
        let info = UIStackView(arrangedSubviews: [nameLabel, metaLabel])
        info.axis = .vertical
        info.spacing = 2
        info.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(noLabel)
        contentView.addSubview(imgView)
        contentView.addSubview(info)
        NSLayoutConstraint.activate([
            noLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            noLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            noLabel.widthAnchor.constraint(equalToConstant: 24),
            imgView.leadingAnchor.constraint(equalTo: noLabel.trailingAnchor, constant: 6),
            imgView.widthAnchor.constraint(equalToConstant: 44),
            imgView.heightAnchor.constraint(equalToConstant: 44),
            imgView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            info.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 10),
            info.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            info.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func bind(index: Int, food: [String: Any]) {
        contentView.alpha = 1
        layer.borderWidth = 0
        noLabel.text = "\(index + 1)"
        let n = food["name"] as? String ?? ""
        nameLabel.text = n.isEmpty ? "未命名" : n
        var meta: [String] = []
        if let b = food["brand_name"] as? String, !b.isEmpty { meta.append(b) }
        if let r = food["repurchase"] as? Int, r > 0 { meta.append("复购\(r)次") }
        metaLabel.text = meta.joined(separator: " · ")
        metaLabel.isHidden = meta.isEmpty
        let path = food["image_path"] as? String
        ImageLoader.shared.load(API.imageUrl(path), into: imgView)
    }
}

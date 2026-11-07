import UIKit

// 美食地图（对齐小程序 map-package/pages/map）：
// 中国/欧洲 GeoJSON 渲染 + 缩放平移 + 点选省份 → 特色美食列表 → 类别排行榜长按拖拽交换
// echarts 的 UTF8 压缩地图数据已在构建期解码为普通 GeoJSON 随包分发
final class FoodMapViewController: UIViewController, UIScrollViewDelegate {

    // 对齐小程序 PROVINCE_MAP：短名 ↔ 全名
    private static let provinceMap: [String: String] = [
        "北京": "北京市", "天津": "天津市", "上海": "上海市", "重庆": "重庆市",
        "内蒙古": "内蒙古自治区", "广西": "广西壮族自治区", "西藏": "西藏自治区", "宁夏": "宁夏回族自治区", "新疆": "新疆维吾尔自治区",
        "香港": "香港特别行政区", "澳门": "澳门特别行政区",
    ]
    private static func toFullName(_ name: String) -> String {
        provinceMap[name] ?? (name + "省")
    }
    private let visitedColor = UIColor(red: 0.702, green: 0.616, blue: 0.859, alpha: 1) // #b39ddb
    private let defaultColor = UIColor(red: 0.941, green: 0.941, blue: 0.941, alpha: 1) // #f0f0f0
    private let borderColor = UIColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)        // #ccc

    // 数据
    private var region = "china"   // china | europe
    private var allFoods: [[String: Any]] = []
    private var visitedDishes: Set<String> = []
    private var byProvince: [String: [String]] = [:]
    private var dishList: [(name: String, visited: Bool)] = []

    // UI
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private var regionLayers: [(name: String, layer: CAShapeLayer)] = []
    private var featureCache: [String: [(name: String, rings: [[CGPoint]])]] = [:]
    private let statusLabel = UILabel()
    private var chinaBtn: UIButton!
    private var europeBtn: UIButton!
    private let zoomStack = UIStackView()
    private var dishPanel: UIView!
    private var dishTitleLabel: UILabel!
    private var dishStack: UIStackView!
    private var rankModal: RankModalView?
    private(set) var dataReady = false
    var mapReady: Bool { dataReady && !regionLayers.isEmpty }
    private var renderedSize = CGSize.zero
    private var needsRefresh = true
    private var loading = false

    func markNeedsRefresh() { needsRefresh = true }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "地图"
        view.backgroundColor = .systemBackground
        buildUI()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(refreshData))
        // 设置页手动同步后，回到本页自动刷新
        NotificationCenter.default.addObserver(forName: .myfoodDataSynced, object: nil, queue: .main) { [weak self] _ in
            self?.needsRefresh = true
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if needsRefresh { needsRefresh = false; Task { await loadData() } }
    }

    @objc private func refreshData() {
        Task { await loadData() }
    }

    private func buildUI() {
        // 顶部区域切换
        chinaBtn = regionBtn("中国地图", sel: #selector(switchChina))
        europeBtn = regionBtn("欧洲地图", sel: #selector(switchEurope))
        let switchRow = UIStackView(arrangedSubviews: [chinaBtn, europeBtn])
        switchRow.axis = .horizontal
        switchRow.spacing = 10
        switchRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(switchRow)

        // 地图滚动区（zoom 1~10，对齐 roam:move + scaleLimit）
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 10
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        contentView.backgroundColor = .clear

        // 命中点击选省
        let tap = UITapGestureRecognizer(target: self, action: #selector(mapTapped(_:)))
        contentView.addGestureRecognizer(tap)

        // 缩放按钮
        let zin = UIButton(type: .system)
        zin.setTitle("＋", for: .normal)
        zin.addTarget(self, action: #selector(zoomIn), for: .touchUpInside)
        let zout = UIButton(type: .system)
        zout.setTitle("－", for: .normal)
        zout.addTarget(self, action: #selector(zoomOut), for: .touchUpInside)
        for b in [zin, zout] {
            b.titleLabel?.font = .boldSystemFont(ofSize: 18)
            b.backgroundColor = .white
            b.layer.cornerRadius = 16
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        zoomStack.addArrangedSubview(zin)
        zoomStack.addArrangedSubview(zout)
        zoomStack.axis = .vertical
        zoomStack.spacing = 8
        zoomStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoomStack)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // 底部特色美食面板（选中省份后出现）
        dishPanel = UIView()
        dishPanel.backgroundColor = .white
        dishPanel.layer.cornerRadius = 12
        dishPanel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        dishPanel.layer.masksToBounds = true
        dishPanel.isHidden = true
        dishPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dishPanel)
        dishTitleLabel = UILabel()
        dishTitleLabel.font = .boldSystemFont(ofSize: 15)
        let dishScroll = UIScrollView()
        dishScroll.alwaysBounceVertical = true
        dishScroll.translatesAutoresizingMaskIntoConstraints = false
        dishStack = UIStackView()
        dishStack.axis = .vertical
        dishStack.spacing = 6
        dishStack.translatesAutoresizingMaskIntoConstraints = false
        dishScroll.addSubview(dishStack)
        dishPanel.addSubview(dishScroll) // 先入层级再激活约束（否则无共同祖先崩溃）
        NSLayoutConstraint.activate([
            dishScroll.topAnchor.constraint(equalTo: dishStack.topAnchor),
            dishScroll.leadingAnchor.constraint(equalTo: dishStack.leadingAnchor),
            dishScroll.trailingAnchor.constraint(equalTo: dishStack.trailingAnchor),
            dishScroll.bottomAnchor.constraint(equalTo: dishStack.bottomAnchor),
            dishScroll.widthAnchor.constraint(equalTo: dishPanel.widthAnchor, constant: -24),
            dishScroll.heightAnchor.constraint(equalToConstant: 240),
            // 行宽 = 滚动区可视宽（否则 stack 按标题收缩，列表很窄）
            dishStack.widthAnchor.constraint(equalTo: dishScroll.frameLayoutGuide.widthAnchor),
        ])
        dishPanel.addSubview(dishTitleLabel)
        NSLayoutConstraint.activate([
            dishTitleLabel.topAnchor.constraint(equalTo: dishPanel.topAnchor, constant: 10),
            dishTitleLabel.leadingAnchor.constraint(equalTo: dishPanel.leadingAnchor, constant: 12),
            dishScroll.topAnchor.constraint(equalTo: dishTitleLabel.bottomAnchor, constant: 8),
            dishScroll.centerXAnchor.constraint(equalTo: dishPanel.centerXAnchor),
            dishScroll.bottomAnchor.constraint(equalTo: dishPanel.bottomAnchor, constant: -10),
        ])

        NSLayoutConstraint.activate([
            switchRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            switchRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: switchRow.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            zoomStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -10),
            zoomStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 8),
            statusLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            dishPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dishPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dishPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        statusLabel.text = "加载中…"
        updateRegionButtons()
    }

    private func regionBtn(_ title: String, sel: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13)
        b.contentEdgeInsets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        b.layer.cornerRadius = 12
        b.addTarget(self, action: sel, for: .touchUpInside)
        return b
    }

    private func updateRegionButtons() {
        for (b, active) in [(chinaBtn, region == "china"), (europeBtn, region == "europe")] {
            b?.backgroundColor = active ? Theme.primary : UIColor(white: 0.94, alpha: 1)
            b?.setTitleColor(active ? .white : Theme.primary, for: .normal)
        }
    }

    // MARK: - 数据（对齐 loadData）

    private func loadData() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var offline = false
        var foods: [[String: Any]] = []
        var catItems: [[String: Any]] = []
        do {
            let config = try await AppConfig.load()
            let limit = config.maxPageSize
            foods = try await API.getAllFoods(limit: limit)
            OfflineStore.mergeRecords(foods)
            let catResult = try await API.getCategories()
            catItems = catResult["items"] as? [[String: Any]] ?? []
            OfflineStore.saveCategories(catItems)
        } catch {
            // 断网兜底：本地缓存继续可用
            let cachedFoods = OfflineStore.cachedRecords()
            let cachedCats = OfflineStore.cachedCategories()
            guard !cachedFoods.isEmpty || !cachedCats.isEmpty else {
                needsRefresh = true
                await MainActor.run { statusLabel.text = "地图数据加载失败" }
                return
            }
            foods = cachedFoods
            catItems = cachedCats
            offline = true
        }
        var visited: Set<String> = []
        for f in foods {
            let cats = f["categories"] as? [String] ?? []
            for c in cats where !c.isEmpty { visited.insert(c) }
        }
        var byProv: [String: [String]] = [:]
        for item in catItems {
            guard let name = item["name"] as? String else { continue }
            let prov = (item["parentcategories"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !prov.isEmpty else { continue }
            byProv[prov, default: []].append(name)
        }
        let isOffline = offline
        await MainActor.run {
            statusLabel.text = isOffline ? "离线数据（可能不是最新）" : ""
            dataReady = true
            visitedDishes = visited
            byProvince = byProv
            allFoods = foods
            renderMap()
        }
    }

    // MARK: - GeoJSON 渲染（对齐 renderRegionMap）

    // 布局后重绘（首帧 scrollView.bounds 可能为 0）
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if dataReady && (regionLayers.isEmpty || renderedSize != scrollView.bounds.size) {
            renderMap()
        }
    }

    private func loadFeatures(_ name: String) -> [(name: String, rings: [[CGPoint]])] {
        if let c = featureCache[name] { return c }
        guard let url = Bundle.main.url(forResource: "\(name).geojson", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let features = obj["features"] as? [[String: Any]] else { return [] }
        var out: [(name: String, rings: [[CGPoint]])] = []
        for f in features {
            guard let props = f["properties"] as? [String: Any],
                  let n = props["name"] as? String,
                  let geo = f["geometry"] as? [String: Any] else { continue }
            var rings: [[CGPoint]] = []
            switch geo["type"] as? String {
            case "Polygon":
                if let rr = geo["coordinates"] as? [[[Double]]] { rings += rr.map { Self.toPoints($0) } }
            case "MultiPolygon":
                if let polys = geo["coordinates"] as? [[[[Double]]]] {
                    for poly in polys { rings += poly.map { Self.toPoints($0) } }
                }
            default: break
            }
            if !rings.isEmpty { out.append((n, rings)) }
        }
        featureCache[name] = out
        return out
    }

    private static func toPoints(_ ring: [[Double]]) -> [CGPoint] {
        ring.compactMap { p in
            p.count >= 2 ? CGPoint(x: p[0], y: p[1]) : nil
        }
    }

    private func renderMap() {
        renderedSize = scrollView.bounds.size
        // 清空旧 layer
        regionLayers.forEach { $0.layer.removeFromSuperlayer() }
        regionLayers = []
        dishPanel.isHidden = true
        dishStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let features = loadFeatures(region)
        guard !features.isEmpty else { statusLabel.text = "地图数据缺失"; return }

        // bbox
        var minLon = Double.greatestFiniteMagnitude, maxLon = -Double.greatestFiniteMagnitude
        var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
        for f in features { for ring in f.rings { for p in ring {
            minLon = min(minLon, Double(p.x)); maxLon = max(maxLon, Double(p.x))
            minLat = min(minLat, Double(p.y)); maxLat = max(maxLat, Double(p.y))
        } } }
        let vw = scrollView.bounds.width, vh = scrollView.bounds.height
        guard maxLon > minLon, maxLat > minLat, vw > 0, vh > 0 else { return }

        // equirectangular 投影 + cos(中纬度) 经度校正（否则中国/欧洲横向被拉伸）
        // 可测：projectParams / projectPoint 为纯函数
        let params = Self.projectParams(vw: vw, vh: vh, minLon: minLon, maxLon: maxLon, minLat: minLat, maxLat: maxLat)

        func project(_ lonlat: CGPoint) -> CGPoint {
            Self.projectPoint(lonlat, params: params)
        }

        let isEurope = region == "europe"
        for f in features {
            let path = UIBezierPath()
            for ring in f.rings {
                let pts = ring.map(project)
                guard let first = pts.first else { continue }
                path.move(to: first)
                for p in pts.dropFirst() { path.addLine(to: p) }
                path.close()
            }
            let layer = CAShapeLayer()
            layer.path = path.cgPath
            layer.fillRule = .nonZero
            layer.strokeColor = borderColor.cgColor
            layer.lineWidth = 0.5
            // 命中查询用：先记名字
            let prov = isEurope ? f.name : Self.toFullName(f.name)
            let dishes = byProvince[prov] ?? []
            let isVisited = dishes.contains { visitedDishes.contains($0) }
            layer.fillColor = isVisited ? visitedColor.cgColor : defaultColor.cgColor
            contentView.layer.addSublayer(layer)
            regionLayers.append((f.name, layer))
        }
        // contentView 尺寸 = 视口（zoom=1 铺满，与 echarts 一致）
        scrollView.contentSize = CGSize(width: vw, height: vh)
        contentView.frame = CGRect(x: 0, y: 0, width: vw, height: vh)
    }

    // 投影参数（纯函数，便于自测）：经度先乘 cos(midLat) 再 fit 视窗；水平居中、垂直居中
    // （竖屏手机上地图宽扁，顶部对齐会在下方留大片空白——视觉测试暴露后改为垂直居中）
    static func projectParams(vw: CGFloat, vh: CGFloat, minLon: Double, maxLon: Double, minLat: Double, maxLat: Double) -> (k: Double, offsetX: Double, offsetY: Double, minLon: Double, maxLat: Double, cosLat: Double) {
        let midLat = (minLat + maxLat) / 2
        let cosLat = cos(midLat * .pi / 180)
        let dLon = (maxLon - minLon) * cosLat
        let dLat = maxLat - minLat
        let k = min(Double(vw) / dLon, Double(vh) / dLat)
        let offsetX = (Double(vw) - dLon * k) / 2
        let offsetY = (Double(vh) - dLat * k) / 2
        return (k, offsetX, offsetY, minLon, maxLat, cosLat)
    }

    static func projectPoint(_ lonlat: CGPoint, params: (k: Double, offsetX: Double, offsetY: Double, minLon: Double, maxLat: Double, cosLat: Double)) -> CGPoint {
        CGPoint(x: (Double(lonlat.x) - params.minLon) * params.cosLat * params.k + params.offsetX,
                y: (params.maxLat - Double(lonlat.y)) * params.k + params.offsetY)
    }

    // MARK: - 交互

    @objc private func switchChina() { switchRegion("china") }
    @objc private func switchEurope() { switchRegion("europe") }

    // SmokeTour 用：切到欧洲 / 打开一个已解锁类目的排行榜
    func smokeSwitchEurope() { switchRegion("europe") }

    func smokeOpenRank() {
        // dishList 只有点省后才填，初始为空；直接用已解锁类目集合
        guard let first = visitedDishes.sorted().first else { return }
        openCatModal(name: first)
    }

    private func switchRegion(_ r: String) {
        guard r != region else { return }
        region = r
        updateRegionButtons()
        renderMap()
    }

    @objc private func zoomIn() { zoom(by: 1.4) }
    @objc private func zoomOut() { zoom(by: 1 / 1.4) }

    private func zoom(by factor: CGFloat) {
        let next = min(scrollView.maximumZoomScale, max(scrollView.minimumZoomScale, scrollView.zoomScale * factor))
        scrollView.zoomScale = next
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    @objc private func mapTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: contentView)
        // 命中选省（对齐 chart click → toFullName → dishList visited 置顶）
        for (name, layer) in regionLayers {
            guard let path = layer.path, path.contains(p) else { continue }
            let province = region == "europe" ? name : Self.toFullName(name)
            var dishes = (byProvince[province] ?? []).map { (name: $0, visited: visitedDishes.contains($0)) }
            dishes.sort { ($0.visited ? 1 : 0) > ($1.visited ? 1 : 0) }
            dishList = dishes
            showDishPanel(province)
            return
        }
    }

    private func showDishPanel(_ province: String) {
        dishTitleLabel.text = "\(province) 的特色美食"
        dishStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for d in dishList {
            dishStack.addArrangedSubview(makeDishRow(d))
        }
        dishPanel.isHidden = false
    }

    // 对齐小程序 .dish-item：全宽行，菜名居左、状态标签居右
    private func makeDishRow(_ d: (name: String, visited: Bool)) -> UIControl {
        let row = UIControl()
        row.backgroundColor = d.visited ? .white : UIColor(white: 0.96, alpha: 1)
        row.layer.cornerRadius = 8
        let nameLabel = UILabel()
        nameLabel.text = d.name
        nameLabel.font = .systemFont(ofSize: 14)
        nameLabel.textColor = d.visited ? .label : UIColor(white: 0.73, alpha: 1)
        let tagLabel = UILabel()
        tagLabel.text = d.visited ? "✓" : "未解锁"
        tagLabel.font = .systemFont(ofSize: 12)
        tagLabel.textColor = d.visited ? Theme.excellent : UIColor(white: 0.73, alpha: 1)
        let content = UIStackView(arrangedSubviews: [nameLabel, tagLabel])
        content.axis = .horizontal
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
        ])
        row.addAction(UIAction(handler: { [weak self] _ in
            self?.openCatModal(name: d.name)
        }), for: .touchUpInside)
        return row
    }

    // MARK: - 排行榜弹窗（对齐 rank modal）

    private func sortByRank(_ foods: [[String: Any]], _ cat: String) -> [[String: Any]] {
        let ranked = foods
            .filter { f in (f["category_rank"] as? [String: Any])?[cat] != nil }
            .sorted { (a, b) in
                let ra = (a["category_rank"] as? [String: Any])?[cat] as? Int ?? 0
                let rb = (b["category_rank"] as? [String: Any])?[cat] as? Int ?? 0
                return ra < rb
            }
        let rest = foods
            .filter { ((($0["category_rank"] as? [String: Any])?[cat]) == nil) }
            .sorted { ($0["id"] as? Int ?? 0) > ($1["id"] as? Int ?? 0) }
        return ranked + rest
    }

    private func openCatModal(name: String) {
        guard visitedDishes.contains(name) else { return } // 未解锁不可点
        let foods = sortByRank(allFoods.filter { ($0["categories"] as? [String] ?? []).contains(name) }, name)
        let modal = RankModalView(category: name, foods: foods)
        modal.onApplyRank = { [weak self] list in
            guard let self else { throw APIError(message: "地图页面已关闭") }
            try await self.applyRankOrder(list, cat: name)
        }
        modal.onClose = { [weak self] in self?.rankModal = nil }
        modal.frame = view.bounds
        modal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(modal)
        rankModal = modal
    }

    // 交换后按显示顺序写入名次（1 开始），只 PATCH 有变化的记录（对齐 applyRankOrder）
    // 断网时入队 + 本地更新，恢复联网后由 SyncEngine 补传，UI 视为保存成功
    private func applyRankOrder(_ list: [[String: Any]], cat: String) async throws {
        for change in RankOrder.changes(list, current: allFoods, category: cat) {
            do {
                _ = try await API.updateFoodDetails(change.id, fields: ["category_rank": change.rank])
            } catch {
                OfflineStore.enqueue(.patch(serverId: change.id, fields: ["category_rank": change.rank]))
            }
            if let index = allFoods.firstIndex(where: { ($0["id"] as? Int) == change.id }) {
                allFoods[index]["category_rank"] = change.rank
                OfflineStore.upsertRecord(allFoods[index])
            }
        }
    }
}

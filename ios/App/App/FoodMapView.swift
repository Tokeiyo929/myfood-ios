import SwiftUI

// 美食地图 tab（原 UIKit FoodMapViewController + RankModalView 移植）：
// 中国/欧洲 GeoJSON Canvas 渲染 + 缩放平移 + 点选省份 → 特色美食面板 → 排行榜拖拽交换
@MainActor
@Observable
final class FoodMapViewModel {
    var region = "china" // china | europe
    var allFoods: [[String: Any]] = []
    var visitedDishes: Set<String> = []
    var byProvince: [String: [String]] = [:]
    private(set) var visitedProvinces: Set<String> = []
    var statusText = "加载中…"
    var dataReady = false
    var needsRefresh = true
    var zoom: CGFloat = 1
    var panOffset: CGSize = .zero
    var selectedProvince: String?
    var selectedDishes: [(name: String, visited: Bool)] = []
    var rankCategory: String?
    var rankFoods: [[String: Any]] = []
    var toast: String?
    var panBase: CGSize = .zero
    private var pinchBase: CGFloat?

    var mapReady: Bool { dataReady }

    var geometry: FoodMapGeometry { region == "europe" ? .europe : .china }

    func onAppear() {
        guard needsRefresh else { return }
        needsRefresh = false
        Task { await loadData() }
    }

    func loadData() async {
        var foods: [[String: Any]] = []
        var catItems: [[String: Any]] = []
        var offline = false
        do {
            let config = try await AppConfig.load()
            foods = try await API.getAllFoods(limit: config.maxPageSize)
            OfflineStore.mergeRecords(foods)
            let catResult = try await API.getCategories()
            catItems = catResult["items"] as? [[String: Any]] ?? []
            OfflineStore.saveCategories(catItems)
        } catch {
            guard isNetworkError(error) else {
                statusText = error.localizedDescription
                needsRefresh = true
                return
            }
            // 断网兜底：本地缓存继续可用
            let cachedFoods = OfflineStore.cachedRecords()
            let cachedCats = OfflineStore.cachedCategories()
            guard !cachedFoods.isEmpty || !cachedCats.isEmpty else {
                statusText = "地图数据加载失败"
                needsRefresh = true
                return
            }
            foods = cachedFoods
            catItems = cachedCats
            offline = true
        }
        var visited: Set<String> = []
        for f in foods {
            for c in (f["categories"] as? [String] ?? []) where !c.isEmpty { visited.insert(c) }
        }
        var byProv: [String: [String]] = [:]
        var visitedProvs: Set<String> = []
        for item in catItems {
            guard let name = item["name"] as? String else { continue }
            let prov = (item["parentcategories"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !prov.isEmpty else { continue }
            byProv[prov, default: []].append(name)
            if visited.contains(name) { visitedProvs.insert(prov) }
        }
        allFoods = foods
        visitedDishes = visited
        byProvince = byProv
        visitedProvinces = visitedProvs
        statusText = offline ? "离线数据（可能不是最新）" : ""
        dataReady = true
    }

    func switchRegion(_ r: String) {
        guard r != region else { return }
        region = r
        zoom = 1
        pinchBase = nil
        panOffset = .zero
        panBase = .zero
        selectedProvince = nil
    }

    func magnify(_ amount: CGFloat) {
        let base = pinchBase ?? zoom
        pinchBase = base
        zoom = min(10, max(1, base * amount))
    }

    func endMagnify() { pinchBase = nil }

    // 点选省份 → 特色美食列表（visited 置顶，移植 mapTapped）
    func selectProvince(_ name: String) {
        let province = region == "europe" || byProvince[name] != nil ? name : FoodMapGeometry.toFullName(name)
        var dishes = (byProvince[province] ?? []).map { (name: $0, visited: visitedDishes.contains($0)) }
        dishes.sort { ($0.visited ? 1 : 0) > ($1.visited ? 1 : 0) }
        selectedProvince = province
        selectedDishes = dishes
    }

    func openRank(category: String) {
        guard visitedDishes.contains(category) else { return } // 未解锁不可点
        rankCategory = category
        rankFoods = Self.sortByRank(allFoods.filter { ($0["categories"] as? [String] ?? []).contains(category) }, category)
    }

    // 精准匹配：有排名按名次升序，无排名按时间倒序跟在后面
    static func sortByRank(_ foods: [[String: Any]], _ cat: String) -> [[String: Any]] {
        let ranked = foods.filter { ($0["category_rank"] as? [String: Any])?[cat] != nil }
            .sorted { ($0["category_rank"] as? [String: Any])?[cat] as? Int ?? 0 < ($1["category_rank"] as? [String: Any])?[cat] as? Int ?? 0 }
        let rest = foods.filter { (($0["category_rank"] as? [String: Any])?[cat]) == nil }
            .sorted { ($0["id"] as? Int ?? 0) > ($1["id"] as? Int ?? 0) }
        return ranked + rest
    }

    // 交换后按显示顺序写入名次（1 开始）；断网入队 + 本地更新
    func applyRankOrder(list: [[String: Any]], cat: String) async throws {
        for change in RankOrder.changes(list, current: allFoods, category: cat) {
            do {
                _ = try await API.updateFoodDetails(change.id, fields: ["category_rank": change.rank])
                SyncDiff.snapshotPatchFood(id: change.id, fields: ["category_rank": change.rank]) // 防误报"远端更新"
            } catch {
                guard isNetworkError(error) else { throw error }
                OfflineStore.enqueue(.patch(serverId: change.id, fields: ["category_rank": change.rank]))
            }
            if let index = allFoods.firstIndex(where: { ($0["id"] as? Int) == change.id }) {
                allFoods[index]["category_rank"] = change.rank
                OfflineStore.upsertRecord(allFoods[index])
            }
        }
    }

    // SmokeTour 用：切到欧洲 / 打开一个已解锁类目的排行榜
    func smokeSwitchEurope() { switchRegion("europe") }
    func smokeOpenRank() {
        guard let first = visitedDishes.sorted().first else { return }
        openRank(category: first)
    }

    func smokeOpenProvince() {
        switchRegion("china")
        guard let category = visitedDishes.sorted().first,
              let province = byProvince.first(where: { $0.value.contains(category) })?.key else { return }
        selectProvince(province)
    }
}

// 每个区域首次显示时构建居中、经度按纬度校正的路径，绘制与点选共用。
struct FoodMapGeometry {
    static let china = FoodMapGeometry(features: loadFeatures("china"))
    static let europe = FoodMapGeometry(features: loadFeatures("europe"))
    static let provinceMap: [String: String] = [
        "北京": "北京市", "天津": "天津市", "上海": "上海市", "重庆": "重庆市",
        "内蒙古": "内蒙古自治区", "广西": "广西壮族自治区", "西藏": "西藏自治区", "宁夏": "宁夏回族自治区", "新疆": "新疆维吾尔自治区",
        "香港": "香港特别行政区", "澳门": "澳门特别行政区",
    ]
    static func toFullName(_ name: String) -> String { provinceMap[name] ?? (name + "省") }

    let paths: [(name: String, path: Path)]
    private let extent: CGSize

    init(features: [ProvinceFeature]) {
        var bounds = CGRect.null
        let outlines = features.map { feature in
            var outline = Path()
            for ring in feature.rings {
                guard let first = ring.first else { continue }
                outline.move(to: first)
                for point in ring.dropFirst() { outline.addLine(to: point) }
                outline.closeSubpath()
            }
            if !outline.isEmpty { bounds = bounds.union(outline.boundingRect) }
            return (name: feature.name, path: outline)
        }
        guard !bounds.isNull else { paths = []; extent = .zero; return }
        let cosLat = cos(bounds.midY * .pi / 180)
        let projection = CGAffineTransform(a: cosLat, b: 0, c: 0, d: -1,
                                           tx: -bounds.midX * cosLat, ty: bounds.midY)
        extent = CGSize(width: bounds.width * cosLat, height: bounds.height)
        paths = outlines.map { ($0.name, $0.path.applying(projection)) }
    }

    func viewTransform(size: CGSize, zoom: CGFloat, pan: CGSize) -> CGAffineTransform? {
        guard extent.width > 0, extent.height > 0, size.width > 0, size.height > 0 else { return nil }
        let scale = min(size.width / extent.width, size.height / extent.height) * zoom
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: size.width / 2 + pan.width, ty: size.height / 2 + pan.height)
    }

    func province(at location: CGPoint, transform: CGAffineTransform) -> String? {
        let point = location.applying(transform.inverted())
        return paths.reversed().first(where: { $0.path.contains(point) })?.name
    }

    struct ProvinceFeature {
        let name: String
        let rings: [[CGPoint]] // 经纬度点
    }

    private static func loadFeatures(_ name: String) -> [ProvinceFeature] {
        guard let url = Bundle.main.url(forResource: "\(name).geojson", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let features = obj["features"] as? [[String: Any]] else { return [] }
        var out: [ProvinceFeature] = []
        for f in features {
            guard let props = f["properties"] as? [String: Any],
                  let n = props["name"] as? String,
                  let geo = f["geometry"] as? [String: Any] else { continue }
            var rings: [[CGPoint]] = []
            switch geo["type"] as? String {
            case "Polygon":
                if let rr = geo["coordinates"] as? [[[Double]]] { rings += rr.map { toPoints($0) } }
            case "MultiPolygon":
                if let polys = geo["coordinates"] as? [[[[Double]]]] {
                    for poly in polys { rings += poly.map { toPoints($0) } }
                }
            default: break
            }
            if !rings.isEmpty { out.append(ProvinceFeature(name: n, rings: rings)) }
        }
        return out
    }

    private static func toPoints(_ ring: [[Double]]) -> [CGPoint] {
        ring.compactMap { p in p.count >= 2 ? CGPoint(x: p[0], y: p[1]) : nil }
    }
}

struct FoodMapView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.foodMap
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                regionButton("中国地图", active: vm.region == "china") { vm.switchRegion("china") }
                regionButton("欧洲地图", active: vm.region == "europe") { vm.switchRegion("europe") }
                Spacer()
            }
            .padding(.horizontal, 12)

            ZStack(alignment: .topLeading) {
                if vm.dataReady {
                    mapCanvas
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(vm.statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
            }
            .background(Color(UIColor.systemBackground))
        }
        .navigationTitle("地图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await vm.loadData() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .toast($vm.toast)
        .onAppear { vm.onAppear() }
    }

    private func regionButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(active ? Theme.primary : Color(white: 0.94), in: Capsule())
                .foregroundStyle(active ? Color.white : Theme.primary)
        }
        .buttonStyle(.plain)
    }

    private var mapCanvas: some View {
        GeometryReader { geo in
            let vm = app.foodMap
            let geometry = vm.geometry
            let zoom = vm.zoom
            let transform = geometry.viewTransform(size: geo.size, zoom: zoom, pan: vm.panOffset)
            let visited = vm.visitedProvinces
            let isEurope = vm.region == "europe"
            ZStack(alignment: .bottomTrailing) {
                Canvas { ctx, _ in
                    guard let transform else { return }
                    ctx.concatenate(transform)
                    // 变换同时缩放描边，换算回原先的屏幕线宽。
                    let lineWidth = 0.5 / zoom / transform.a
                    for (name, path) in geometry.paths {
                        let province = isEurope ? name : FoodMapGeometry.toFullName(name)
                        ctx.fill(path, with: .color(visited.contains(province) ? Color(red: 0.702, green: 0.616, blue: 0.859) : Color(white: 0.941)))
                        ctx.stroke(path, with: .color(Color(white: 0.8)), lineWidth: lineWidth)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if let transform, let name = geometry.province(at: location, transform: transform) {
                        vm.selectProvince(name)
                    }
                }
                .gesture(panZoomGesture)

                VStack(spacing: 8) {
                    zoomButton("＋") { app.foodMap.zoom = min(10, app.foodMap.zoom * 1.4) }
                    zoomButton("－") { app.foodMap.zoom = max(1, app.foodMap.zoom / 1.4) }
                }
                .padding(.trailing, 10)
                .padding(.bottom, 16)
            }
        }
        .sheet(item: Bindable(app.foodMap).selectedProvinceItem) { province in
            DishPanelView(province: province.name)
        }
    }

    private func zoomButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(Color.white, in: Circle())
                .overlay(Circle().stroke(Color(white: 0.85)))
        }
        .buttonStyle(.plain)
    }

    // 拖动平移 + 双指捏合缩放（移植 zoom/pan；范围 1~10；平移基准累计）
    private var panZoomGesture: some Gesture {
        SimultaneousGesture(
            DragGesture()
                .onChanged { g in
                    app.foodMap.panOffset = CGSize(width: app.foodMap.panBase.width + g.translation.width,
                                                   height: app.foodMap.panBase.height + g.translation.height)
                }
                .onEnded { g in
                    app.foodMap.panBase = app.foodMap.panOffset
                },
            MagnifyGesture()
                .onChanged { g in
                    app.foodMap.magnify(g.magnification)
                }
                .onEnded { _ in
                    app.foodMap.endMagnify()
                }
        )
    }
}

// 省份面板模型（sheet item）
extension FoodMapViewModel {
    var selectedProvinceItem: ProvinceItem? {
        get { selectedProvince.map { ProvinceItem(name: $0) } }
        set { selectedProvince = newValue?.name }
    }
    var rankPresented: Bool {
        get { rankCategory != nil }
        set { if !newValue { rankCategory = nil } }
    }
}

struct ProvinceItem: Identifiable {
    let name: String
    var id: String { name }
}

// 特色美食面板（选中省份后出现）
struct DishPanelView: View {
    let province: String
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(province) 的特色美食").font(.system(size: 15, weight: .bold))
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(app.foodMap.selectedDishes, id: \.name) { dish in
                        Button { app.foodMap.openRank(category: dish.name) } label: {
                            HStack {
                                Text(dish.name).font(.system(size: 14))
                                    .foregroundStyle(dish.visited ? Color(UIColor.label) : Color(white: 0.73))
                                Spacer()
                                if dish.visited {
                                    Text("✓").font(.system(size: 12)).foregroundStyle(Theme.excellent)
                                } else {
                                    Text("未解锁").font(.system(size: 12)).foregroundStyle(Color(white: 0.73))
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(dish.visited ? Color.white : Color(white: 0.96), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(!dish.visited)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: Bindable(app.foodMap).rankPresented) {
            if let category = app.foodMap.rankCategory { RankSheetView(category: category) }
        }
    }
}

// 排行榜弹窗（长按拖拽交换排名；移植 RankModalView 简化为整行拖动）
struct RankSheetView: View {
    let category: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var foods: [[String: Any]] = []
    @State private var statusText = "长按条目拖到另一条上，交换排名"
    @State private var saving = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                List {
                    ForEach(foods.indices, id: \.self) { idx in
                        let f = foods[idx]
                        HStack(spacing: 12) {
                            Text("\(idx + 1)")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.primary)
                                .frame(width: 24)
                            RemoteImage(path: f["image_path"] as? String)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f["name"] as? String ?? "").font(.system(size: 15, weight: .medium))
                                Text(f["brand_name"] as? String ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove { from, to in
                        foods.move(fromOffsets: from, toOffset: to)
                        Task { await apply() }
                    }
                }
                .listStyle(.plain)
                .environment(\.editMode, .constant(.active))
                .disabled(saving)
            }
            .padding(.horizontal, 12)
            .navigationTitle("\(category) · 排行榜")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .toast($toast)
        }
        .onAppear { foods = app.foodMap.rankFoods }
        .presentationDetents([.large])
    }

    private func apply() async {
        guard !saving else { return }
        saving = true
        statusText = "保存中…"
        defer { saving = false }
        do {
            try await app.foodMap.applyRankOrder(list: foods, cat: category)
            for index in foods.indices {
                var ranks = foods[index]["category_rank"] as? [String: Any] ?? [:]
                ranks[category] = index + 1
                foods[index]["category_rank"] = ranks
            }
            statusText = "已保存；拖动交换排名"
        } catch {
            statusText = "排名未全部保存，可重试拖动"
            toast = error.localizedDescription
        }
    }
}

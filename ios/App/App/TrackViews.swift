import SwiftUI
import MapKit

// 轨迹 tab（原 UIKit MapViewController + TrackDaysViewController 移植）：
// iOS17 SwiftUI Map + 折线；今天页以当前位置为中心，历史某天按轨迹起点
@MainActor
@Observable
final class TrackViewModel {
    var viewDay: String? // nil = 今天
    var points: [[String: Any]] = []
    var coords: [CLLocationCoordinate2D] = []
    var statusText = "加载中…"
    var loaded = false

    var title: String { viewDay.map { "轨迹 · \($0)" } ?? "轨迹" }

    func load(day: String?) async {
        viewDay = day
        let dayString = day ?? TrackView.fmtDay(Date())
        do {
            let pts = try await API.getTrackPoints(day: dayString)
            OfflineStore.saveTrackPoints(pts, day: dayString)
            apply(points: pts)
        } catch {
            // 断网兜底：当天缓存 + 本机未上传点
            var cached = OfflineStore.cachedTrackPoints(day: dayString)
            cached += TrackRecorder.shared.pendingPoints(day: dayString)
            if !cached.isEmpty {
                apply(points: cached)
                statusText = "离线轨迹 · \(coords.count)点"
                loaded = true
            } else {
                statusText = "轨迹加载失败"
                loaded = true
            }
        }
    }

    private func apply(points pts: [[String: Any]]) {
        var out: [CLLocationCoordinate2D] = []
        for p in pts {
            guard let lat = p["lat"] as? Double, let lng = p["lng"] as? Double else { continue }
            // 存储是原始 GPS(WGS-84)，国内地图瓦片是 GCJ-02 基准：显示前纠偏，否则偏移几百米
            let gcj = GCJConverter.wgs84ToGcj02(lat: lat, lng: lng)
            out.append(CLLocationCoordinate2D(latitude: gcj.lat, longitude: gcj.lng))
        }
        points = pts
        coords = out
        statusText = viewDay == nil ? "\(out.count)点" : "历史轨迹 · \(viewDay!)"
        loaded = true
    }

    // 录制中状态（今天页）
    var recorderStatus: String {
        let offlineMark = NetworkMonitor.shared.isOnline ? "" : " · 离线(底图可能空白)"
        if TrackRecorder.shared.isTracking {
            return "记录中 · \(TrackRecorder.shared.todayPoints.count)点\(offlineMark)"
        }
        return "未记录 · 点按开启\(offlineMark)"
    }
}

@MainActor
@Observable
final class TrackDaysViewModel {
    var days: [[String: Any]] = []
    var loaded = false
    var toast: String?

    func load() async {
        do {
            let fetched = try await API.getTrackDays()
            OfflineStore.saveTrackDays(fetched)
            days = Self.mergingPending(server: fetched)
            loaded = true
        } catch {
            // 断网兜底：历史日期缓存 + 未上传点聚合出的天
            let cached = Self.mergingPending(server: OfflineStore.cachedTrackDays())
            loaded = true
            if !cached.isEmpty {
                days = cached
                toast = "离线数据（可能不是最新）"
            } else {
                toast = error.localizedDescription
            }
        }
    }

    // 服务端按天统计合并本机未上传点（主要是今天），断网也能看到当天轨迹
    static func mergingPending(server: [[String: Any]]) -> [[String: Any]] {
        var result = server
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        var pendingByDay: [String: Int] = [:]
        for p in TrackRecorder.shared.allPendingPoints() {
            guard let ts = p["ts"] as? Double else { continue }
            let day = f.string(from: Date(timeIntervalSince1970: ts / 1000))
            pendingByDay[day, default: 0] += 1
        }
        guard !pendingByDay.isEmpty else { return result }
        for i in result.indices {
            let day = result[i]["day"] as? String ?? ""
            let base = result[i]["points"] as? Int ?? 0
            if let extra = pendingByDay.removeValue(forKey: day) {
                result[i]["points"] = base + extra
            }
        }
        for (day, count) in pendingByDay {
            result.append(["day": day, "points": count])
        }
        return result.sorted { ($0["day"] as? String ?? "") > ($1["day"] as? String ?? "") }
    }
}

struct TrackRootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.daysPath) {
            TrackView()
                .navigationDestination(for: TrackDestination.self) { dest in
                    TrackDayView(day: dest.day)
                }
        }
    }
}

struct TrackDestination: Hashable {
    let day: String
}

// 轨迹 tab 根页（今天）：地图为主 + 每日记录入口（二级页）
struct TrackView: View {
    @Environment(AppModel.self) private var app
    var day: String?

    private var vm: TrackViewModel { day == nil ? app.tracks : app.dayVM }

    static func fmtDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: d)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if vm.loaded {
                mapSection
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(vm.statusText)
                .font(.system(size: 12))
                .padding(6)
                .background(Color(white: 1, opacity: 0.85), in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
        }
        .navigationTitle(vm.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if day == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: TrackDestination(day: TrackView.fmtDay(Date()))) {
                        Text("每日记录").font(.system(size: 15))
                    }
                }
            }
        }
        .task { await vm.load(day: day) }
    }

    private var mapSection: some View {
        let position: MapCameraPosition = {
            if day == nil, let here = TrackRecorder.shared.lastKnownCoordinate {
                return .region(MKCoordinateRegion(center: here, latitudinalMeters: 800, longitudinalMeters: 800))
            }
            if let first = vm.coords.first {
                return .region(MKCoordinateRegion(center: first, latitudinalMeters: 800, longitudinalMeters: 800))
            }
            return .automatic
        }()
        return Map(position: .constant(position)) {
            if !vm.coords.isEmpty {
                MapPolyline(coordinates: vm.coords)
                    .stroke(Theme.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            UserAnnotation()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .overlay(alignment: .topLeading) {
            if day == nil {
                Text(vm.recorderStatus)
                    .font(.system(size: 12))
                    .padding(6)
                    .background(Color(white: 1, opacity: 0.85), in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
            }
        }
    }
}

// 某天轨迹（三级页）
struct TrackDayView: View {
    let day: String

    var body: some View {
        TrackView(day: day)
    }
}

// 每日记录列表（二级页）
struct TrackDaysView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List {
            if app.days.days.isEmpty {
                Text(app.days.loaded ? "还没有轨迹记录\n轨迹在 App 启动后自动记录" : "加载中…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            ForEach(app.days.days.indices, id: \.self) { idx in
                let d = app.days.days[idx]
                let day = d["day"] as? String ?? ""
                NavigationLink(value: TrackDestination(day: day)) {
                    HStack {
                        Text(day)
                        Spacer()
                        Text("\(d["points"] as? Int ?? 0) 个定位点").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("每日记录")
        .navigationBarTitleDisplayMode(.inline)
        .toast($app.days.toast)
        .task { await app.days.load() }
    }
}

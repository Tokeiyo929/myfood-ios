import UIKit

// 轨迹 tab 二级页：每日记录列表（根页是 MapViewController 地图）
class TrackDaysViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var table: UITableView!
    private var days: [[String: Any]] = []
    private(set) var loaded = false

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "每日记录"
        table = UITableView(frame: .zero, style: .plain)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 60
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        Task {
            do {
                let fetched = try await API.getTrackDays()
                OfflineStore.saveTrackDays(fetched)
                days = Self.mergingPending(server: fetched)
                loaded = true
                table.reloadData()
            } catch {
                // 断网兜底：历史日期缓存 + 未上传点聚合出的天
                let cached = Self.mergingPending(server: OfflineStore.cachedTrackDays())
                loaded = true
                if !cached.isEmpty {
                    days = cached
                    table.reloadData()
                    Toast.show("离线数据（可能不是最新）", view)
                } else {
                    Toast.show(error.localizedDescription, view)
                }
            }
        }
    }

    // SmokeTour 用：打开第一条日期（三级页：某天轨迹）
    func smokeOpenFirst() {
        guard !days.isEmpty else { return }
        let day = days[0]["day"] as? String ?? ""
        let vc = MapViewController()
        vc.viewDay = day
        navigationController?.pushViewController(vc, animated: false)
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

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        days.isEmpty ? 1 : days.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "dcell") ?? UITableViewCell(style: .value1, reuseIdentifier: "dcell")
        cell.accessoryType = .none
        if days.isEmpty {
            cell.textLabel?.text = "还没有轨迹记录"
            cell.detailTextLabel?.text = "轨迹在 App 启动后自动记录"
            return cell
        }
        let d = days[indexPath.row]
        cell.textLabel?.text = d["day"] as? String ?? ""
        cell.detailTextLabel?.text = "\(d["points"] as? Int ?? 0) 个定位点"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !days.isEmpty else { return }
        let day = days[indexPath.row]["day"] as? String ?? ""
        let vc = MapViewController()
        vc.viewDay = day
        navigationController?.pushViewController(vc, animated: true)
    }
}

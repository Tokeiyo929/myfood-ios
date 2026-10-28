import UIKit

// 轨迹 tab：按天列表
class TrackDaysViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var table: UITableView!
    private var days: [[String: Any]] = []

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "轨迹"
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
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        Task {
            days = (try? await API.getTrackDays()) ?? []
            DispatchQueue.main.async { self.table.reloadData() }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        days.isEmpty ? 1 : days.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "dcell") ?? UITableViewCell(style: .value1, reuseIdentifier: "dcell")
        if days.isEmpty {
            cell.textLabel?.text = "还没有轨迹记录"
            cell.detailTextLabel?.text = "去地图页点「开始记录」"
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

import UIKit

// 历史 tab：全部记录
class HistoryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var table: UITableView!
    private var records: [[String: Any]] = []
    private var titleLabel: UILabel!

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "历史"
        table = UITableView(frame: .zero, style: .plain)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 72
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        loadAll()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadAll()
    }

    private func loadAll() {
        Task {
            var items: [[String: Any]] = []
            var page = 1
            while true {
                do {
                    let r = try await API.getFoods(page: page, limit: 50)
                    let batch = r["items"] as? [[String: Any]] ?? []
                    items += batch
                    if batch.count < 50 || page >= 20 { break }
                    page += 1
                } catch { break }
            }
            records = items
            DispatchQueue.main.async {
                self.title = "历史 (\(items.count))"
                self.table.reloadData()
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.isEmpty ? 1 : records.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "hcell") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "hcell")
        if records.isEmpty {
            cell.textLabel?.text = "还没有记录"
            cell.detailTextLabel?.text = ""
            return cell
        }
        let rec = records[indexPath.row]
        cell.textLabel?.text = (rec["name"] as? String) ?? "未命名"
        let t = (rec["taken_at"] as? String) ?? (rec["create_at"] as? String) ?? ""
        cell.detailTextLabel?.text = t
        cell.accessoryType = .disclosureIndicator
        cell.imageView?.image = nil
        if let path = rec["image_path"] as? String, let url = API.imageUrl(path) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data else { return }
                DispatchQueue.main.async {
                    if let img = UIImage(data: data) {
                        cell.imageView?.image = img
                        tableView.reloadRows(at: [indexPath], with: .none)
                    }
                }
            }.resume()
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !records.isEmpty else { return }
        guard let id = records[indexPath.row]["id"] as? Int else { return }
        navigationController?.pushViewController(DetailViewController(foodId: id), animated: true)
    }
}

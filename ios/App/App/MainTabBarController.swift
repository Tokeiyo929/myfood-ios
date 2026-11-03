import UIKit

// 五 tab：历史 | 记录 | 地图(中心凸起,默认) | 轨迹 | 设置
class MainTabBarController: UITabBarController, UITabBarControllerDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        let history = HistoryViewController()
        let record = RecordViewController()
        let map = FoodMapViewController()   // 美食地图（对齐小程序 map-package）
        let tracks = MapViewController()    // 轨迹 tab：地图为主（每日记录为二级页）
        let settings = SettingsViewController()
        history.tabBarItem = UITabBarItem(title: "历史", image: UIImage(systemName: "clock"), tag: 0)
        record.tabBarItem = UITabBarItem(title: "记录", image: UIImage(systemName: "camera"), tag: 1)
        map.tabBarItem = UITabBarItem(title: "地图", image: UIImage(systemName: "map"), tag: 2)
        tracks.tabBarItem = UITabBarItem(title: "轨迹", image: UIImage(systemName: "calendar"), tag: 3)
        settings.tabBarItem = UITabBarItem(title: "设置", image: UIImage(systemName: "gearshape"), tag: 4)
        viewControllers = [history, record, map, tracks, settings].map { UINavigationController(rootViewController: $0) }
        tabBar.tintColor = Theme.primary // #66508f
        selectedIndex = 2 // 默认地图
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        SmokeTour.debugNote("vda args=\(ProcessInfo.processInfo.arguments)") // 诊断
        SmokeTour.start() // CI 冒烟巡访（仅 -autoSmoke 时生效，内部有防重入）
        AutoTest.start() // CI 自测（仅 -autoTest 时生效，内部有防重入）
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        raiseCenterTab()
    }

    // 中心凸起按钮
    private func raiseCenterTab() {
        guard tabBar.subviews.count == 5 else { return }
        let center = tabBar.subviews[3] // 第3个(0-indexed: 历史0 记录1 地图2 + 横杠3... 实际 subview 含 _UIBarBackground)
        let items = tabBar.subviews.filter { String(describing: type(of: $0)).contains("TabBarButton") }
        guard items.count == 5 else { return }
        let mapBtn = items[2]
        mapBtn.frame = mapBtn.frame.offsetBy(dx: 0, dy: -14)
    }
}

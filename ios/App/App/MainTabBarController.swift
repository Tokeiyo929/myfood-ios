import UIKit

// 五 tab：历史 | 记录 | 地图(中心凸起,默认) | 轨迹 | 设置
class MainTabBarController: UITabBarController, UITabBarControllerDelegate {
    private let centerButton = UIButton(type: .system)
    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        let history = HistoryViewController()
        let record = RecordViewController()
        let map = FoodMapViewController()   // 美食地图（对齐小程序 map-package）
        let tracks = MapViewController()    // 轨迹 tab：地图为主（每日记录为二级页）
        let settings = SettingsViewController()
        history.onRecordsChanged = { [weak record, weak map] in record?.markNeedsRefresh(); map?.markNeedsRefresh() }
        record.onRecordsChanged = { [weak history, weak map] in history?.markNeedsRefresh(); map?.markNeedsRefresh() }
        history.tabBarItem = UITabBarItem(title: "历史", image: UIImage(systemName: "clock"), tag: 0)
        record.tabBarItem = UITabBarItem(title: "记录", image: UIImage(systemName: "camera"), tag: 1)
        map.tabBarItem = UITabBarItem(title: "地图", image: UIImage(systemName: "map"), tag: 2)
        tracks.tabBarItem = UITabBarItem(title: "轨迹", image: UIImage(systemName: "calendar"), tag: 3)
        settings.tabBarItem = UITabBarItem(title: "设置", image: UIImage(systemName: "gearshape"), tag: 4)
        viewControllers = [history, record, map, tracks, settings].map { UINavigationController(rootViewController: $0) }
        tabBar.tintColor = Theme.primary
        selectedIndex = AutoTest.enabled ? 4 : 2 // 自测先打开无需请求数据的设置页。
        var config = UIButton.Configuration.plain()
        config.title = "地图"
        config.image = UIImage(systemName: "map")
        config.imagePlacement = .top
        config.imagePadding = 3
        config.baseForegroundColor = Theme.primary
        centerButton.configuration = config
        centerButton.backgroundColor = .systemBackground
        centerButton.layer.cornerRadius = 16
        centerButton.accessibilityLabel = "地图"
        centerButton.addAction(UIAction { [weak self] _ in self?.selectedIndex = 2 }, for: .touchUpInside)
        view.addSubview(centerButton)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        SmokeTour.start() // CI 冒烟巡访（仅 -autoSmoke 时生效，内部有防重入）
        AutoTest.start() // CI 自测（仅 -autoTest 时生效，内部有防重入）
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = tabBar.bounds.width / CGFloat(viewControllers?.count ?? 5)
        let height = tabBar.bounds.height - tabBar.safeAreaInsets.bottom
        centerButton.frame = CGRect(x: tabBar.frame.midX - width / 2, y: tabBar.frame.minY - 14, width: width, height: height + 14)
        centerButton.isHidden = tabBar.isHidden
        view.bringSubviewToFront(centerButton)
    }
}

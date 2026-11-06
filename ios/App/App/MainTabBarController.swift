import UIKit

// 五 tab：地图 | 轨迹 | 历史(默认) | 设置 | 更多(占位)；轨迹默认自动记录，无需手动开启
class MainTabBarController: UITabBarController, UITabBarControllerDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        let history = HistoryViewController()  // 记录页已并入：拍照/相册入口在历史页导航栏
        let map = FoodMapViewController()      // 美食地图（对齐小程序 map-package）
        let tracks = MapViewController()       // 轨迹 tab：地图为主（每日记录为二级页）
        let settings = SettingsViewController()
        let placeholder = PlaceholderViewController()
        history.onRecordsChanged = { [weak map] in map?.markNeedsRefresh() }
        map.tabBarItem = UITabBarItem(title: "地图", image: UIImage(systemName: "map"), tag: 0)
        tracks.tabBarItem = UITabBarItem(title: "轨迹", image: UIImage(systemName: "calendar"), tag: 1)
        history.tabBarItem = UITabBarItem(title: "历史", image: UIImage(systemName: "clock"), tag: 2)
        settings.tabBarItem = UITabBarItem(title: "设置", image: UIImage(systemName: "gearshape"), tag: 3)
        placeholder.tabBarItem = UITabBarItem(title: "更多", image: UIImage(systemName: "ellipsis.circle"), tag: 4)
        viewControllers = [map, tracks, history, settings, placeholder].map { UINavigationController(rootViewController: $0) }
        tabBar.tintColor = Theme.primary
        selectedIndex = AutoTest.enabled ? 4 : 2 // 自测先打开无需请求数据的占位页。
        // 轨迹默认记录：启动即自动开始（测试模式跳过，避免首启弹窗干扰冒烟截图）
        if !SmokeTour.enabled, !AutoTest.enabled {
            TrackRecorder.shared.start()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        SmokeTour.start() // CI 冒烟巡访（仅 -autoSmoke 时生效，内部有防重入）
        AutoTest.start() // CI 自测（仅 -autoTest 时生效，内部有防重入）
    }
}

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG
        if AutoTest.enabled || SmokeTour.enabled {
            TestFixture.install() // 测试会话：fixture 服务端，不走离线同步
        } else {
            Self.startSync()
        }
        #else
        Self.startSync()
        #endif
        return true
    }

    // 离线同步：启动排空队列 + 断网恢复联网时自动补传
    static func startSync() {
        NetworkMonitor.shared.start()
        NetworkMonitor.shared.onReconnect = { Task { await SyncEngine.drain() } }
        Task { await SyncEngine.drain() }
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

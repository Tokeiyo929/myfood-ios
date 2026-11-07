import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: windowScene)
        let root = MainTabBarController()
        root.loadViewIfNeeded()
        window?.rootViewController = root
        window?.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // 回前台补一次离线队列排空（联网时为空队列即空转）
        #if DEBUG
        guard !AutoTest.enabled, !SmokeTour.enabled else { return }
        #endif
        Task { await SyncEngine.drain() }
    }
}

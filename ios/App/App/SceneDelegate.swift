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
        SmokeTour.start() // CI 冒烟巡访（仅 -autoSmoke 时生效）
    }
}

import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = MainViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)

        // Opened from a shared filter link.
        connectionOptions.userActivities.compactMap(\.webpageURL).forEach { ShareLinks.open($0) }
        connectionOptions.urlContexts.forEach { ShareLinks.open($0.url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        ShareLinks.showPending()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        let others = URLContexts.filter { !ShareLinks.open($0.url) }
        if !others.isEmpty { SceneDelegateProxy.shared.scene(scene, openURLContexts: others) }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL, ShareLinks.open(url) { return }
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}

import UIKit

/// Escena del iPhone. Es la que manda: aquí vive el first responder, así que
/// **todo el teclado físico entra por esta escena**, no por la externa, que es
/// no interactiva por definición.
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = PhoneRootViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    /// Vuelta desde Atajos por `brunos://`, tras encender AssistiveTouch.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            AppServices.shared.handle(url: context.url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppServices.shared.assistiveTouch.refresh()
        // Con monitor conectado la pantalla del iPhone no se puede apagar: si la
        // app pasa a segundo plano, iOS vuelve a duplicar la pantalla.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = false
        // Si iOS cierra la app en segundo plano, que no se lleve las cookies.
        CookieVault.shared.saveNow()
    }
}

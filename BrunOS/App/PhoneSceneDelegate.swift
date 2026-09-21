import UIKit

/// Escena del iPhone. Es la que manda: aquí vive el first responder, así que
/// **todo el teclado físico entra por esta escena**, no por la externa, que es
/// no interactiva por definición.
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// Gestor de la pantalla externa. Vive en la escena del teléfono porque el
    /// accesorio se registra desde su view controller raíz.
    let externalDisplay = ExternalDisplayManager()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = PhoneRootViewController(externalDisplay: externalDisplay)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Con monitor conectado la pantalla del iPhone no se puede apagar: si la
        // app pasa a segundo plano, iOS vuelve a duplicar la pantalla.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

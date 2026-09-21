import UIKit

/// Escena que el sistema conecta cuando hay monitor y el accesorio está
/// disponible. Es **no interactiva**: no recibe toques, ni teclado, ni puntero.
/// Todo lo que pase aquí lo dirige la escena del iPhone.
///
/// Esta clase no se instancia a mano: la nombra el `UISceneConfiguration` que
/// `ExternalDisplayManager` le pasa al `UISceneAccessory`.
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let desktop = DesktopViewController()
        window.rootViewController = desktop
        window.isHidden = false
        self.window = window

        // El gestor vive en la escena del iPhone, que es quien conoce el perfil
        // de la pantalla y quien tiene que recalcular el mosaico.
        phoneSceneDelegate()?.externalDisplay.attach(window: window, screen: windowScene.screen)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        phoneSceneDelegate()?.externalDisplay.detach()
        window = nil
    }

    /// Busca la escena del iPhone entre las conectadas.
    ///
    /// Las dos escenas comparten proceso pero no delegado, y el accesorio no da
    /// una referencia directa a quien lo registró.
    private func phoneSceneDelegate() -> PhoneSceneDelegate? {
        UIApplication.shared.connectedScenes
            .compactMap { $0.delegate as? PhoneSceneDelegate }
            .first
    }
}

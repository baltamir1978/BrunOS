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

        let services = AppServices.shared
        let window = UIWindow(windowScene: windowScene)
        let desktop = DesktopViewController()
        window.rootViewController = desktop
        window.isHidden = false
        self.window = window

        services.externalDisplay.attach(window: window, screen: windowScene.screen)

        // El cursor va después del layout: necesita saber el tamaño lógico del
        // escritorio para centrarse donde toca.
        window.layoutIfNeeded()
        desktop.attachPointer()

        // Las ventanas de la última vez, si así está en Ajustes. Si no, el
        // escritorio sale vacío y se abre lo que se pulse en el dock (lo pidió
        // Bruno el 24-sep-2026; antes salía una ventana de cada app).
        if services.desktop.active.isEmpty, services.desktop.active.minimized.isEmpty {
            desktop.restoreSession()
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // El estado de los paneles vive en AppServices y **no se toca aquí**:
        // al volver a enchufar el monitor todo tiene que reaparecer igual.
        AppServices.shared.pointer.detach()
        AppServices.shared.externalDisplay.detach()
        window = nil
    }
}

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

        EventLog.note("Monitor: escena conectada")
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

    /// **Al volver de otra app, iOS no siempre conecta una escena nueva**:
    /// reutiliza esta. Pero mientras BrunOS estaba en segundo plano (en Atajos,
    /// para Tailscale) el accesorio dejó de estar disponible y la pantalla se
    /// dio por desconectada: sin cursor, y el iPhone fuera del modo mando. Al
    /// volver no había nadie que lo enganchara otra vez, y Bruno se encontraba
    /// el iPhone en blanco y el ratón sin moverse bien (24-sep-2026).
    func sceneWillEnterForeground(_ scene: UIScene) {
        reattachIfNeeded()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        reattachIfNeeded()
    }

    /// Lo mismo para todas las escenas del monitor que haya, desde fuera:
    /// al volver la app al frente y cuando el accesorio vuelve a estar
    /// disponible.
    static func reattachAll() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            (scene.delegate as? ExternalSceneDelegate)?.reattachIfNeeded()
        }
    }

    /// Vuelve a enganchar el monitor y el cursor si se soltaron mientras la
    /// escena seguía viva. No hace nada si ya estaba enganchado.
    func reattachIfNeeded() {
        guard let window, let windowScene = window.windowScene,
              windowScene.activationState != .background
        else { return }
        let services = AppServices.shared
        // Sólo si no hay ninguna enganchada: si iOS ha conectado ya una escena
        // nueva, la vieja no se la puede quitar.
        guard services.externalDisplay.currentProfile == nil else { return }
        EventLog.note("Monitor: se vuelve a enganchar la escena que ya estaba")
        services.externalDisplay.attach(window: window, screen: windowScene.screen)
        window.layoutIfNeeded()
        (window.rootViewController as? DesktopViewController)?.attachPointer()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        EventLog.note("Monitor: escena desconectada")
        // El estado de los paneles vive en AppServices y **no se toca aquí**:
        // al volver a enchufar el monitor todo tiene que reaparecer igual.
        AppServices.shared.pointer.detach()
        AppServices.shared.externalDisplay.detach()
        window = nil
    }
}

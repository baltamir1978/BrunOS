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
            EventLog.note("Vuelta por \(context.url.scheme ?? "")://\(context.url.host() ?? "")")
            AppServices.shared.handle(url: context.url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        EventLog.note("iPhone: activa")
        // Por si la escena del monitor se quedó suelta mientras estábamos en
        // otra app (ver `ExternalSceneDelegate.reattachIfNeeded`).
        ExternalSceneDelegate.reattachAll()
        AppServices.shared.assistiveTouch.refresh()
        // Una nota cambiada desde la app Archivos, al volver.
        AppServices.shared.notes.refreshFromDisk()
        // Tailscale ha podido cambiar desde Atajos o desde su app.
        AppServices.shared.tailscale.refresh()
        // Con monitor conectado la pantalla del iPhone no se puede apagar: si la
        // app pasa a segundo plano, iOS vuelve a duplicar la pantalla.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// **Se suelta el botón del ratón al irse.** Un clic que manda a otra app
    /// (el «Conectar» de Tailscale abre Atajos al pulsar) no llega a soltarse:
    /// el toque de AssistiveTouch se corta, y si la vista del trackpad ya no
    /// está para enterarse, BrunOS se quedaba con el botón «pulsado» e
    /// ignoraba el movimiento del puntero al volver.
    func sceneWillResignActive(_ scene: UIScene) {
        EventLog.note("iPhone: deja de estar activa")
        let services = AppServices.shared
        if services.pointer.isHoldingButton {
            services.pointer.isHoldingButton = false
            services.desktopViewController?.deliverPointer(.up(button: .left), modifiers: [])
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        EventLog.note("iPhone: en segundo plano")
        UIApplication.shared.isIdleTimerDisabled = false
        // Si iOS cierra la app en segundo plano, que no se lleve las cookies.
        CookieVault.shared.saveNow()
        AppServices.shared.history.flush()
        AppServices.shared.notes.saveNow()
        AppServices.shared.desktopViewController?.saveSessionNow()
    }
}

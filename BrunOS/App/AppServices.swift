import UIKit

/// Lo que comparten las dos escenas.
///
/// BrunOS tiene un problema de forma que conviene entender antes de tocar nada:
/// **el estado vive en la escena del iPhone y se dibuja en la externa**. La del
/// teléfono recibe el teclado y el ratón; la externa no recibe nada, porque es
/// no interactiva. Y las dos se conectan y se desconectan por su cuenta.
///
/// Por eso hay un único contenedor compartido en vez de pasar referencias entre
/// delegados: al reconectar el monitor, la escena externa nueva tiene que
/// encontrar el escritorio **tal y como estaba**, con sus paneles y su foco.
@MainActor
final class AppServices {

    static let shared = AppServices()

    let desktop = DesktopModel()
    let externalDisplay = ExternalDisplayManager()
    let pointer = PointerController()
    let mouse = MouseRouter()
    let keyboard = KeyboardRouter()
    let assistiveTouch = AssistiveTouchMonitor()
    let hosts = HostStore()
    let knownHosts = KnownHostsStore()
    let tailscale = TailscaleMonitor()
    let wallpaper = WallpaperStore()
    let blocker = ContentBlocker()

    /// El escritorio de la pantalla externa, si está conectada.
    weak var desktopViewController: DesktopViewController?

    private init() {}

    func start() {
        mouse.start()
        assistiveTouch.start()
        tailscale.start()
        Task { await blocker.prepare() }
    }

    /// Gestiona la vuelta desde Atajos por `brunos://`.
    func handle(url: URL) {
        guard url.scheme == "brunos" else { return }
        // El estado de AssistiveTouch puede haber cambiado mientras estábamos
        // fuera, y la notificación no siempre llega estando en segundo plano.
        assistiveTouch.handleCallback(host: url.host)
    }
}

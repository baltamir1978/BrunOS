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
    let smbServers = SMBServerStore()
    let knownHosts = KnownHostsStore()
    let tailscale = TailscaleMonitor()
    let wallpaper = WallpaperStore()
    let blocker = ContentBlocker()
    let files = FileService()
    let history = BrowserHistory()
    let favicons = FaviconStore()
    let downloads = DownloadCenter()
    let hls = HLSDownloader()
    let notes = NotesStore()
    let clipboard = ClipboardHistory()
    let weather = WeatherService()

    /// El escritorio de la pantalla externa, si está conectada.
    weak var desktopViewController: DesktopViewController?

    private init() {}

    func start() {
        // Lo primero: los orígenes de ficheros no se pueden montar en el
        // `init` de `FileService` porque necesitan este mismo singleton.
        files.rebuild()

        mouse.start()
        assistiveTouch.start()
        tailscale.start()

        // Las máquinas SSH aparecen también como orígenes de ficheros, así que
        // hay que rehacer la lista cuando se añada o se quite alguna.
        NotificationCenter.default.addObserver(
            forName: HostStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppServices.shared.files.rebuild() }
        }
        NotificationCenter.default.addObserver(
            forName: SMBServerStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppServices.shared.files.rebuild() }
        }
        Task { await blocker.prepare() }
    }

    /// Gestiona la vuelta desde Atajos por `brunos://`.
    func handle(url: URL) {
        guard url.scheme == "brunos" else { return }
        // El estado de AssistiveTouch puede haber cambiado mientras estábamos
        // fuera, y la notificación no siempre llega estando en segundo plano.
        assistiveTouch.handleCallback(host: url.host)
        tailscale.handleCallback(host: url.host)
    }
}

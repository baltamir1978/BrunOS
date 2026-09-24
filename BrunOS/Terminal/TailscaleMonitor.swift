import Foundation
import Network
import Observation
import UIKit

/// Mira si Tailscale parece estar levantado.
///
/// **Es sólo un aviso y nunca bloquea una conexión.** No hay forma pública de
/// preguntarle a la app de Tailscale por su estado, así que esto es una
/// deducción a partir de las interfaces de red, y puede equivocarse. Impedir
/// conectar por una deducción sería peor que no avisar.
///
/// El indicio: una interfaz `utun` con una dirección del rango que usa
/// Tailscale, `100.64.0.0/10` en IPv4 —el rango CGNAT— o `fd7a:115c:a1e0::/48`
/// en IPv6. Son rangos públicos y documentados, nada del tailnet de nadie.
@MainActor
@Observable
final class TailscaleMonitor {

    static let didChange = Notification.Name("BrunOSTailscaleDidChange")

    /// Avisa al cambiar, para la barra superior, que no observa nada.
    private(set) var isLikelyUp = false {
        didSet {
            if isLikelyUp != oldValue {
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        }
    }

    /// Qué pasó la última vez que se pidió encender o apagar desde BrunOS.
    enum ToggleResult: Equatable {
        case waiting
        case done
        /// Atajos no pudo abrir el atajo: casi siempre, que no existe.
        case missingShortcut
    }

    private(set) var lastToggle: ToggleResult? {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    private var monitor: NWPathMonitor?
    private var pollTimer: Timer?

    func start() {
        let monitor = NWPathMonitor()
        self.monitor = monitor

        monitor.pathUpdateHandler = { [weak self] _ in
            let detected = Self.hasTailscaleAddress()
            Task { @MainActor in
                self?.isLikelyUp = detected
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.baltamir.brunos.tailscale"))
        isLikelyUp = Self.hasTailscaleAddress()

        // **Y además, cada 10 segundos** (lo pidió Bruno, 24-sep-2026): el
        // aviso de cambio de red no siempre llega al encender o apagar la VPN
        // desde la app de Tailscale, y el icono se quedaba con lo de antes.
        // Leer las interfaces no cuesta nada, y la barra sólo se repinta si el
        // estado cambia (`isLikelyUp` sólo avisa entonces).
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        isLikelyUp = Self.hasTailscaleAddress()
    }

    // MARK: - Encender y apagar

    /// El atajo que hay que crear en la app Atajos.
    ///
    /// **iOS no deja que una app encienda la VPN de otra**: `NEVPNManager`
    /// sólo gestiona las configuraciones de la propia app, y la de Tailscale
    /// es suya. Lo que sí hay es Atajos: la app de Tailscale trae acciones
    /// para conectar y desconectar, y un atajo se lanza por URL. Es el mismo
    /// camino que el de AssistiveTouch, con la misma vuelta por `brunos://`.
    ///
    /// Se le pasa `on` u `off` como entrada, por si el atajo quiere decidir
    /// con un «Si»; uno que sólo alterne también vale.
    static let shortcutName = "BrunOS Tailscale"

    /// Pide encender (o apagar) Tailscale por Atajos.
    ///
    /// Para lanzar el atajo, iOS pasa un momento a la app Atajos y vuelve:
    /// mientras tanto el monitor enseña el iPhone duplicado. No hay forma de
    /// evitarlo desde fuera.
    func toggle(on: Bool) {
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")
        components?.queryItems = [
            URLQueryItem(name: "name", value: Self.shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: on ? "on" : "off"),
            URLQueryItem(name: "x-success", value: "brunos://tailscale-ok"),
            URLQueryItem(name: "x-error", value: "brunos://tailscale-error"),
        ]
        guard let url = components?.url else { return }
        lastToggle = .waiting
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            MainActor.assumeIsolated {
                if !opened { self?.lastToggle = .missingShortcut }
            }
        }
    }

    /// La vuelta de Atajos. La interfaz de red tarda un poco en aparecer o
    /// irse, así que se mira otra vez al rato.
    func handleCallback(host: String?) {
        switch host {
        case "tailscale-ok":
            lastToggle = .done
            refresh()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        case "tailscale-error":
            lastToggle = .missingShortcut
        default:
            break
        }
    }

    /// Recorre las interfaces buscando una `utun` con dirección de Tailscale.
    ///
    /// `getifaddrs` es la vía: `NWPathMonitor` dice si hay red y de qué tipo,
    /// pero no enumera direcciones, y aquí lo que identifica a Tailscale es
    /// justamente la dirección.
    nonisolated private static func hasTailscaleAddress() -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(addresses) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("utun"), let address = current.pointee.ifa_addr else { continue }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var storage = sockaddr_in()
                memcpy(&storage, address, MemoryLayout<sockaddr_in>.size)
                // 100.64.0.0/10: el rango CGNAT que usa Tailscale.
                let value = UInt32(bigEndian: storage.sin_addr.s_addr)
                if value >> 22 == 0b01100100_01 {
                    return true
                }

            case AF_INET6:
                var storage = sockaddr_in6()
                memcpy(&storage, address, MemoryLayout<sockaddr_in6>.size)
                let bytes = withUnsafeBytes(of: storage.sin6_addr) { Array($0) }
                // fd7a:115c:a1e0::/48
                if bytes.count >= 6,
                   bytes[0] == 0xFD, bytes[1] == 0x7A,
                   bytes[2] == 0x11, bytes[3] == 0x5C,
                   bytes[4] == 0xA1, bytes[5] == 0xE0 {
                    return true
                }

            default:
                break
            }
        }
        return false
    }
}

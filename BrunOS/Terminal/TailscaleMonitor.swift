import Foundation
import Network
import Observation

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

    private(set) var isLikelyUp = false

    private var monitor: NWPathMonitor?

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
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    func refresh() {
        isLikelyUp = Self.hasTailscaleAddress()
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

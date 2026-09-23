import Foundation
import Security

/// Perfil de una máquina a la que conectarse.
///
/// **Aquí no entra ni un secreto.** Esto se guarda en un JSON en Application
/// Support; las contraseñas van al Keychain, que es el único sitio donde tienen
/// sentido. Si alguna vez hay que añadir un campo, conviene recordarlo.
struct SSHHost: Codable, Identifiable, Equatable, Sendable {

    enum Authentication: String, Codable, CaseIterable, Sendable {
        /// Método SSH `none`: **es el de Tailscale SSH**, que autentica por la
        /// identidad del tailnet y no pide nada al cliente.
        case tailscale
        /// Contraseña, guardada en el Keychain de este dispositivo.
        case password
        /// La clave ed25519 del iPhone (`SSHKeyStore`).
        case key

        var label: String {
            switch self {
            case .tailscale: "Tailscale (sin contraseña)"
            case .password: "Contraseña"
            case .key: "Clave ed25519"
            }
        }
    }

    var id: UUID
    var name: String
    /// Admite nombres de MagicDNS como `homelab`, no sólo IPs.
    var host: String
    var port: Int
    var username: String
    var authentication: Authentication
    /// Lo que se ejecuta nada más entrar. Por ejemplo `tmux new -As main`.
    var initialCommand: String

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        authentication: Authentication = .tailscale,
        initialCommand: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.initialCommand = initialCommand
    }

    /// Lo que se rotula en la pestaña del panel.
    var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }
}

/// Guarda los perfiles en Application Support, en JSON legible.
@MainActor
@Observable
final class HostStore {

    /// Avisa al escritorio, que no observa este objeto y necesita enterarse
    /// para conectar los paneles que estuvieran esperando una máquina.
    static let didChangeNotification = Notification.Name("BrunOSHostsDidChange")

    private(set) var hosts: [SSHHost] = []

    private let url: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("hosts.json")
    }()

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([SSHHost].self, from: data)
        else { return }
        hosts = stored
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hosts) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func upsert(_ host: SSHHost) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func remove(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        SSHKeychain.removePassword(for: host)
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

/// Contraseñas de los hosts SSH.
enum SSHKeychain {

    private static let vault = PasswordVault(service: "com.baltamir.brunos.ssh")

    static func setPassword(_ password: String, for host: SSHHost) {
        vault.set(password, account: host.id.uuidString)
    }

    static func password(for host: SSHHost) -> String? {
        vault.password(account: host.id.uuidString)
    }

    static func removePassword(for host: SSHHost) {
        vault.remove(account: host.id.uuidString)
    }

    static func hasPassword(for host: SSHHost) -> Bool {
        password(for: host) != nil
    }
}

/// Contraseñas en el Keychain, una por cuenta dentro de un servicio.
///
/// Se guardan con `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, que son dos
/// decisiones en una: **no salen del iPhone** (nada de iCloud) y **no se leen
/// con el teléfono bloqueado**. Para algo que abre una consola o una carpeta
/// en una máquina ajena, parece lo mínimo.
struct PasswordVault: Sendable {

    let service: String

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func set(_ password: String, account: String) {
        remove(account: account)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }

        var attributes = query(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func password(account: String) -> String? {
        var attributes = query(account: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

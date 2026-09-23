import Foundation

/// Un servidor de red (SMB) al que BrunOS se conecta él solo, sin pasar por la
/// app Archivos.
///
/// **Aquí no entra ni un secreto**, igual que en `SSHHost`: esto va a un JSON
/// en Application Support y la contraseña al Keychain (`SMBKeychain`).
struct SMBServer: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// Nombre de MagicDNS, nombre de red o IP.
    var host: String
    /// Una carpeta compartida concreta. Vacía, se enseñan todas las del
    /// servidor como carpetas de primer nivel.
    var share: String
    var username: String

    init(id: UUID = UUID(), name: String = "", host: String = "", share: String = "", username: String = "") {
        self.id = id
        self.name = name
        self.host = host
        self.share = share
        self.username = username
    }

    var displayName: String {
        if !name.isEmpty { return name }
        return share.isEmpty ? host : "\(share) en \(host)"
    }
}

/// Guarda los servidores SMB en Application Support, en JSON legible.
@MainActor
@Observable
final class SMBServerStore {

    static let didChangeNotification = Notification.Name("BrunOSSMBServersDidChange")

    private(set) var servers: [SMBServer] = []

    private let url: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("smb-servers.json")
    }()

    init() {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([SMBServer].self, from: data)
        else { return }
        servers = stored
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(servers) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func upsert(_ server: SMBServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func remove(_ server: SMBServer) {
        servers.removeAll { $0.id == server.id }
        SMBKeychain.removePassword(for: server)
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

/// Contraseñas de los servidores SMB, aparte de las de SSH.
enum SMBKeychain {

    private static let vault = PasswordVault(service: "com.baltamir.brunos.smb")

    static func setPassword(_ password: String, for server: SMBServer) {
        vault.set(password, account: server.id.uuidString)
    }

    static func password(for server: SMBServer) -> String? {
        vault.password(account: server.id.uuidString)
    }

    static func removePassword(for server: SMBServer) {
        vault.remove(account: server.id.uuidString)
    }
}

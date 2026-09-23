@preconcurrency import Citadel
import CryptoKit
import Foundation
@preconcurrency import NIOCore

/// Los ficheros de una máquina por SFTP.
///
/// Reutiliza los perfiles y la autenticación de la Fase 2: el mismo host que se
/// usa para el terminal sirve aquí sin configurar nada aparte.
///
/// **La conexión es perezosa y se reaprovecha.** Abrir una sesión SSH por cada
/// listado sería lentísimo, así que se mantiene una viva y se reconecta sola si
/// se cae. Se cierra al soltar el proveedor.
final class SFTPProvider: FileProvider, @unchecked Sendable {

    let host: SSHHost
    var name: String { host.displayName }
    let symbol = "server.rack"
    /// Se empieza en el directorio personal, que es lo que uno espera.
    let rootPath = "."

    /// La sesión viva, si la hay. Va tras un actor porque la toca cualquiera.
    private actor Connection {
        private var client: SSHClient?
        private var sftp: SFTPClient?

        func session(
            for host: SSHHost,
            password: String,
            key: Curve25519.Signing.PrivateKey?
        ) async throws -> SFTPClient {
            if let sftp, sftp.isActive { return sftp }

            let authentication: SSHAuthenticationMethod
            switch host.authentication {
            case .tailscale:
                authentication = .tailscale(username: host.username)
            case .password:
                authentication = .passwordBased(username: host.username, password: password)
            case .key:
                guard let key else {
                    throw FileError.failed("No hay clave SSH: genérala en Ajustes del terminal › Clave SSH.")
                }
                authentication = .ed25519(username: host.username, privateKey: key)
            }

            let known = await MainActor.run {
                AppServices.shared.knownHosts.entry(host: host.host, port: host.port)?.fingerprint
            }

            let client = try await SSHClient.connect(
                host: host.host,
                port: host.port,
                authenticationMethod: authentication,
                hostKeyValidator: .custom(KnownHostsValidator(
                    host: host.host,
                    port: host.port,
                    known: known,
                    onResult: { matched, fingerprint in
                        Task { @MainActor in
                            let store = AppServices.shared.knownHosts
                            if matched {
                                store.trust(fingerprint: fingerprint, host: host.host, port: host.port)
                            } else {
                                store.noteChange(fingerprint: fingerprint, host: host.host, port: host.port)
                            }
                        }
                    }
                )),
                reconnect: .never
            )
            let sftp = try await client.openSFTP()
            self.client = client
            self.sftp = sftp
            return sftp
        }

        func close() async {
            try? await sftp?.close()
            try? await client?.close()
            sftp = nil
            client = nil
        }
    }

    private let connection = Connection()

    init(host: SSHHost) {
        self.host = host
    }

    deinit {
        let connection = self.connection
        Task { await connection.close() }
    }

    private func session() async throws -> SFTPClient {
        let password = await MainActor.run {
            host.authentication == .password ? SSHKeychain.password(for: host) ?? "" : ""
        }
        let key = host.authentication == .key ? SSHKeyStore.privateKey() : nil
        do {
            return try await connection.session(for: host, password: password, key: key)
        } catch {
            throw FileError.failed("No se pudo conectar con \(host.host): \(error.localizedDescription)")
        }
    }

    // MARK: - FileProvider

    func list(_ path: String) async throws -> [FileItem] {
        let sftp = try await session()
        let listings: [SFTPMessage.Name]
        do {
            listings = try await sftp.listDirectory(atPath: path)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }

        return listings
            .flatMap(\.components)
            // `.` y `..` los pone el protocolo; subir de nivel ya tiene su
            // tecla y verlos en la lista sólo estorba.
            .filter { $0.filename != "." && $0.filename != ".." }
            .filter { !$0.filename.hasPrefix(".") }
            .map { component in
                let attributes = component.attributes
                // El primer carácter del `longname` es el tipo, como en `ls -l`.
                let isDirectory = component.longname.first == "d"
                return FileItem(
                    name: component.filename,
                    path: path == "." ? component.filename : path + "/" + component.filename,
                    isDirectory: isDirectory,
                    size: Int64(attributes.size ?? 0),
                    // Citadel ya lo da como `Date`, sin conversiones.
                    modified: attributes.accessModificationTime?.modificationTime
                )
            }
    }

    func read(_ path: String) async throws -> Data {
        let sftp = try await session()
        do {
            return try await sftp.withFile(filePath: path, flags: .read) { file in
                let buffer = try await file.readAll()
                return Data(buffer.readableBytesView)
            }
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    func write(_ data: Data, to path: String) async throws {
        let sftp = try await session()
        do {
            try await sftp.withFile(
                filePath: path,
                flags: [.write, .create, .truncate]
            ) { file in
                try await file.write(ByteBuffer(bytes: data))
            }
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    func delete(_ path: String) async throws {
        let sftp = try await session()
        do {
            try await sftp.remove(at: path)
        } catch {
            // Puede ser un directorio, que se borra con otra orden.
            do {
                try await sftp.rmdir(at: path)
            } catch {
                throw FileError.failed(error.localizedDescription)
            }
        }
    }

    func rename(_ path: String, to newName: String) async throws {
        let sftp = try await session()
        let parent = (path as NSString).deletingLastPathComponent
        let destination = parent.isEmpty ? newName : parent + "/" + newName
        do {
            try await sftp.rename(at: path, to: destination)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    func createDirectory(_ path: String) async throws {
        let sftp = try await session()
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    /// Descarga el fichero a un temporal para poder enseñarlo.
    ///
    /// Se guarda en caché mientras dure la sesión: abrir dos veces la misma
    /// vista previa no tiene por qué costar dos descargas.
    func localURL(for item: FileItem) async throws -> URL {
        let url = previewURL(for: item, prefix: "sftp-\(host.id.uuidString)")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        try await download(item.path, to: url)
        return url
    }

    func move(_ path: String, to destination: String) async throws {
        let sftp = try await session()
        do {
            try await sftp.rename(at: path, to: destination)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    /// Trozos de 256 KB: bastante para que no sean miles de peticiones, y
    /// nada para la memoria.
    private static let chunk: UInt32 = 256 * 1024

    func download(_ path: String, to url: URL) async throws {
        let sftp = try await session()
        // Se escribe a un temporal y se mueve al final: una descarga cortada
        // no deja un fichero a medias que parezca bueno (la vista previa lo
        // reaprovecharía).
        let partial = url.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            try await sftp.withFile(filePath: path, flags: .read) { file in
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let buffer = try await file.read(from: offset, length: Self.chunk)
                    guard buffer.readableBytes > 0 else { break }
                    try handle.write(contentsOf: buffer.readableBytesView)
                    offset += UInt64(buffer.readableBytes)
                }
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw FileError.failed(error.localizedDescription)
        }
    }

    func upload(from url: URL, to path: String) async throws {
        let sftp = try await session()
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                var offset: UInt64 = 0
                while let data = try handle.read(upToCount: Int(Self.chunk)), !data.isEmpty {
                    try Task.checkCancellation()
                    try await file.write(ByteBuffer(bytes: data), at: offset)
                    offset += UInt64(data.count)
                }
            }
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }
}

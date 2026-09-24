@preconcurrency import AMSMB2
import Foundation

/// Los ficheros de un servidor de red por SMB, con cliente propio (AMSMB2,
/// sobre libsmb2).
///
/// **Las rutas empiezan por la carpeta compartida**: `/Fotos/2026/a.jpg` es
/// `2026/a.jpg` dentro de la compartida `Fotos`. Si el servidor se dio de alta
/// sin compartida, la raíz (`/`) lista todas las del servidor; si se dio con
/// una, la raíz es esa (`/Fotos`) y no se sube más arriba.
final class SMBProvider: RangeReadableProvider, @unchecked Sendable {

    let server: SMBServer
    var name: String { server.displayName }
    let symbol = "externaldrive.connected.to.line.below"
    let rootPath: String

    /// Una conexión por compartida: en SMB cada una es su propio árbol, y
    /// `SMB2Manager` sólo sabe estar en una a la vez.
    private actor Connection {
        private var managers: [String: SMB2Manager] = [:]
        /// Las que se están abriendo. **El actor no protege de esto solo**:
        /// entre mirar la caché y terminar `connectShare` hay un `await`, y
        /// dos peticiones a la vez (el listado y una copia) abrían dos sesiones
        /// y una se quedaba colgada en el servidor.
        private var connecting: [String: Task<SMB2Manager, any Error>] = [:]
        private var browser: SMB2Manager?

        /// Para listar las compartidas no hace falta estar dentro de ninguna.
        func browser(url: URL, credential: URLCredential?) throws -> SMB2Manager {
            if let browser { return browser }
            let manager = try Self.make(url: url, credential: credential)
            browser = manager
            return manager
        }

        func manager(share: String, url: URL, credential: URLCredential?) async throws -> SMB2Manager {
            if let manager = managers[share] { return manager }
            if let pending = connecting[share] { return try await pending.value }

            let task = Task {
                let manager = try Self.make(url: url, credential: credential)
                try await manager.connectShare(name: share)
                return manager
            }
            connecting[share] = task
            defer { connecting[share] = nil }
            let manager = try await task.value
            managers[share] = manager
            return manager
        }

        /// AMSMB2 espera un minuto a que conteste el servidor. Con uno apagado,
        /// eso es un minuto mirando un panel en blanco; 20 segundos sobran
        /// para una red de casa o el tailnet, y es por petición, no por copia.
        private static func make(url: URL, credential: URLCredential?) throws -> SMB2Manager {
            guard let manager = SMB2Manager(url: url, credential: credential) else {
                throw FileError.failed("La dirección del servidor no es válida.")
            }
            manager.timeout = 20
            return manager
        }

        /// Tras un error de red se tira la conexión: la siguiente petición
        /// abre otra, que es la forma más sencilla de reconectar.
        func drop(share: String) async {
            guard let manager = managers.removeValue(forKey: share) else { return }
            // Cerrarla de verdad: si no, cada error dejaba una sesión abierta
            // en el servidor hasta que se soltara el proveedor.
            try? await manager.disconnectShare()
        }

        func close() async {
            for manager in managers.values {
                try? await manager.disconnectShare(gracefully: true)
            }
            managers = [:]
            browser = nil
        }
    }

    private let connection = Connection()

    init(server: SMBServer) {
        self.server = server
        self.rootPath = server.share.isEmpty ? "/" : "/" + server.share
    }

    deinit {
        let connection = self.connection
        Task { await connection.close() }
    }

    // MARK: - Conexión

    private var serverURL: URL? {
        URL(string: "smb://" + server.host)
    }

    private func credential() async -> URLCredential? {
        let server = self.server
        guard !server.username.isEmpty else { return nil }
        let password = await MainActor.run { SMBKeychain.password(for: server) ?? "" }
        return URLCredential(user: server.username, password: password, persistence: .forSession)
    }

    /// Separa `/Compartida/a/b` en la compartida y la ruta de dentro.
    private func split(_ path: String) -> (share: String, inner: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let share = parts.first else { return nil }
        return (String(share), "/" + parts.dropFirst().joined(separator: "/"))
    }

    /// La conexión a la compartida de una ruta, y la ruta dentro de ella.
    private func resolve(_ path: String) async throws -> (SMB2Manager, String, String) {
        guard let url = serverURL else { throw FileError.failed("La dirección del servidor no es válida.") }
        guard let (share, inner) = split(path) else {
            throw FileError.failed("Elige primero una carpeta compartida.")
        }
        do {
            let manager = try await connection.manager(share: share, url: url, credential: await credential())
            return (manager, share, inner)
        } catch {
            throw FileError.failed("No se pudo conectar con \(server.host): \(Self.describe(error))")
        }
    }

    /// Hace una operación y, si falla, suelta la conexión para que la
    /// siguiente vuelva a abrirla: un servidor que se ha dormido o una red que
    /// ha cambiado dejan la sesión muerta sin avisar.
    private func perform<T: Sendable>(
        _ path: String,
        _ operation: @Sendable (SMB2Manager, String) async throws -> T
    ) async throws -> T {
        let (manager, share, inner) = try await resolve(path)
        do {
            return try await operation(manager, inner)
        } catch {
            // Sólo si parece la conexión: un «no existe» o un «sin permiso»
            // no tienen por qué tirarla.
            if !Self.isFileLevel(error) { await connection.drop(share: share) }
            throw FileError.failed(Self.describe(error))
        }
    }

    private static func isFileLevel(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain,
              let code = POSIXErrorCode(rawValue: Int32(nsError.code))
        else { return false }
        return [.ENOENT, .EEXIST, .EACCES, .EPERM, .ENOTEMPTY, .EISDIR, .ENOTDIR].contains(code)
    }

    private static func describe(_ error: any Error) -> String {
        let posix = (error as NSError).domain == NSPOSIXErrorDomain ? (error as NSError).code : nil
        switch posix.flatMap({ POSIXErrorCode(rawValue: Int32($0)) }) {
        case .EACCES?, .EPERM?: return "Usuario o contraseña incorrectos, o sin permiso."
        case .ENOENT?: return "No existe."
        case .ETIMEDOUT?, .EHOSTUNREACH?, .ECONNREFUSED?:
            return "El servidor no responde. ¿Está encendido y en la misma red o en el tailnet?"
        default: return error.localizedDescription
        }
    }

    // MARK: - FileProvider

    func list(_ path: String) async throws -> [FileItem] {
        if split(path) == nil {
            return try await listShares()
        }
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        let entries = try await perform(path) { manager, inner in
            let raw = try await manager.contentsOfDirectory(atPath: inner)
            return raw.map { entry in
                SendableEntry(
                    name: entry[.nameKey] as? String ?? "",
                    isDirectory: entry[.isDirectoryKey] as? Bool ?? false,
                    size: (entry[.fileSizeKey] as? NSNumber)?.int64Value ?? 0,
                    modified: entry[.contentModificationDateKey] as? Date
                )
            }
        }
        return entries
            .filter { !$0.name.isEmpty && !$0.name.hasPrefix(".") }
            .map { entry in
                FileItem(
                    name: entry.name,
                    path: base + "/" + entry.name,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    modified: entry.modified
                )
            }
    }

    private struct SendableEntry: Sendable {
        var name: String
        var isDirectory: Bool
        var size: Int64
        var modified: Date?
    }

    /// Las compartidas del servidor, como carpetas. Las ocultas (las que
    /// acaban en `$`, como `IPC$` o `C$`) no salen: son de administración.
    private func listShares() async throws -> [FileItem] {
        guard let url = serverURL else { throw FileError.failed("La dirección del servidor no es válida.") }
        do {
            let browser = try await connection.browser(url: url, credential: await credential())
            let shares = try await browser.listShares()
            return shares.map { share in
                FileItem(name: share.name, path: "/" + share.name, isDirectory: true, size: 0, modified: nil)
            }
        } catch {
            throw FileError.failed("No se pudo conectar con \(server.host): \(Self.describe(error))")
        }
    }

    func read(_ path: String) async throws -> Data {
        try await perform(path) { manager, inner in
            try await manager.contents(atPath: inner)
        }
    }

    /// Un trozo suelto, para ver un vídeo mientras llega (`MediaStreamer`).
    func read(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        try await perform(path) { manager, inner in
            try await manager.contents(atPath: inner, range: offset..<(offset + UInt64(length)))
        }
    }

    func write(_ data: Data, to path: String) async throws {
        try await perform(path) { manager, inner in
            try await manager.write(data: data, toPath: inner, progress: nil)
        }
    }

    func delete(_ path: String) async throws {
        try await perform(path) { manager, inner in
            try await manager.removeItem(atPath: inner)
        }
    }

    func rename(_ path: String, to newName: String) async throws {
        try await perform(path) { manager, inner in
            let parent = (inner as NSString).deletingLastPathComponent
            try await manager.moveItem(atPath: inner, toPath: (parent as NSString).appendingPathComponent(newName))
        }
    }

    func createDirectory(_ path: String) async throws {
        try await perform(path) { manager, inner in
            try await manager.createDirectory(atPath: inner)
        }
    }

    /// Descarga a un temporal para poder enseñarlo.
    func localURL(for item: FileItem) async throws -> URL {
        let url = previewURL(for: item, prefix: "smb-\(server.id.uuidString)")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        try await download(item.path, to: url)
        return url
    }

    /// A un `.part` y se mueve al final, como en SFTP: una descarga cortada no
    /// deja un fichero a medias que la vista previa daría por bueno.
    func download(_ path: String, to url: URL) async throws {
        let partial = url.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        // El aviso de AMSMB2 llega fuera de la tarea: el valor de tarea se lee
        // antes y se lleva dentro.
        let report = TransferProgress.report
        do {
            try await perform(path) { manager, inner in
                try await manager.downloadItem(atPath: inner, to: partial, progress: { bytes, _ in
                    report?(bytes)
                    return true
                })
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    func move(_ path: String, to destination: String) async throws {
        guard let (share, inner) = split(destination) else {
            throw FileError.failed("Elige primero una carpeta compartida.")
        }
        guard let (sourceShare, _) = split(path), sourceShare == share else {
            throw FileError.failed("Entre carpetas compartidas distintas no se puede mover en el servidor.")
        }
        try await perform(path) { manager, source in
            try await manager.moveItem(atPath: source, toPath: inner)
        }
    }

    func upload(from url: URL, to path: String) async throws {
        let report = TransferProgress.report
        try await perform(path) { manager, inner in
            try await manager.uploadItem(at: url, toPath: inner, progress: { bytes in
                report?(bytes)
                return true
            })
        }
    }
}

import Observation
import UIKit

/// Los orígenes de ficheros disponibles y cuál se está mirando.
///
/// El panel habla con el protocolo `FileProvider` y no sabe con cuál está
/// tratando, así que añadir orígenes no cambia nada de la interfaz. Y copiar
/// entre dos de ellos no necesita casos especiales: se lee de uno y se escribe
/// en el otro.
@MainActor
@Observable
final class FileService {

    private(set) var providers: [any FileProvider] = []
    private(set) var currentIndex = 0

    /// Lo copiado o cortado, a la espera de pegarse.
    private(set) var clipboard: (provider: any FileProvider, item: FileItem, isCut: Bool)?

    let externalFolders = ExternalFolderStore()

    var currentProvider: any FileProvider {
        providers[min(currentIndex, providers.count - 1)]
    }

    /// **No se construyen los orígenes aquí.**
    ///
    /// `rebuild()` mira `AppServices.shared` para sacar las máquinas SSH, y
    /// este objeto se crea **dentro** de esa misma propiedad estática. Pedirla
    /// mientras se está inicializando deja a Swift bloqueado para siempre en
    /// `swift_once`: la app no llega ni a pintar. Se rellena desde
    /// `AppServices.start()`, cuando el singleton ya existe.
    init() {
        providers = [LocalProvider()]
    }

    /// Rehace la lista de orígenes: el iPhone, las carpetas añadidas y las
    /// máquinas SSH configuradas.
    func rebuild() {
        var providers: [any FileProvider] = [LocalProvider()]

        // Se crean todas, disponibles o no: un servidor de red desmontado
        // tiene que seguir viéndose en la barra lateral, en gris, y no
        // desaparecer como si nunca se hubiera añadido.
        for folder in externalFolders.folders {
            providers.append(ExternalFolderProvider(folder: folder))
        }

        // Las máquinas SSH salen solas: si ya están configuradas para el
        // terminal, no tiene sentido volver a darlas de alta aquí.
        for host in AppServices.shared.hosts.hosts {
            providers.append(SFTPProvider(host: host))
        }

        for server in AppServices.shared.smbServers.servers {
            providers.append(SMBProvider(server: server))
        }

        self.providers = providers
        currentIndex = min(currentIndex, providers.count - 1)
    }

    func select(_ index: Int) {
        guard providers.indices.contains(index) else { return }
        currentIndex = index
    }

    // MARK: - Portapapeles

    func copy(_ item: FileItem) {
        clipboard = (currentProvider, item, false)
    }

    func cut(_ item: FileItem) {
        clipboard = (currentProvider, item, true)
    }

    func clearClipboard() {
        clipboard = nil
    }

    /// Cómo va una copia, para la barra de progreso.
    struct Progress: Sendable {
        var filesDone = 0
        var filesTotal = 0
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        /// El fichero que se está copiando ahora.
        var current = ""

        var fraction: Double {
            if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
            return filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0
        }
    }

    /// Pega lo copiado en una carpeta del origen actual.
    ///
    /// Funciona igual dentro de un origen que entre dos distintos, incluido
    /// local ↔ SFTP: se lee de uno y se escribe en el otro. **Las carpetas se
    /// copian enteras**: primero se recorren para saber cuánto hay —si no, la
    /// barra de progreso no podría decir nada útil— y luego se recrean carpeta
    /// a carpeta y fichero a fichero.
    ///
    /// Si ya hay algo con ese nombre, no se pisa: la copia se llama «copia»,
    /// como en el Finder. Así copiar y pegar en la misma carpeta funciona.
    ///
    /// Se puede cancelar: se mira entre fichero y fichero.
    func paste(into directory: String, progress: @escaping @MainActor (Progress) -> Void) async throws {
        guard let clipboard else { return }
        try await transfer(
            clipboard.item,
            from: clipboard.provider,
            to: currentProvider,
            into: directory,
            move: clipboard.isCut,
            progress: progress
        )
        self.clipboard = nil
    }

    /// Copia o mueve algo de un origen a una carpeta de otro, o del mismo. Lo
    /// usan pegar y arrastrar.
    func transfer(
        _ item: FileItem,
        from source: any FileProvider,
        to target: any FileProvider,
        into directory: String,
        move: Bool,
        progress: @escaping @MainActor (Progress) -> Void
    ) async throws {
        // Meter una carpeta dentro de sí misma no tiene fin.
        if source === target, item.isDirectory,
           directory == item.path || directory.hasPrefix(item.path + "/") {
            throw FileError.failed("No se puede meter \(item.name) dentro de sí misma.")
        }

        // Mover dentro del mismo origen conserva el nombre y, si ya hay algo
        // que se llama igual, se para en vez de inventarse una «copia» de
        // algo que se quería mover.
        if move, source === target {
            let existing = Set(try await target.list(directory).map(\.name))
            guard !existing.contains(item.name) else {
                throw FileError.failed("Ya hay algo que se llama \(item.name) en esa carpeta.")
            }
            try await moveWithinProvider(item, in: target, to: directory)
            return
        }

        var state = Progress()
        state.current = "Contando…"
        progress(state)
        let plan = try await collect(item, from: source)
        state.filesTotal = plan.filter { !$0.item.isDirectory }.count
        state.bytesTotal = plan.reduce(0) { $0 + ($1.item.isDirectory ? 0 : $1.item.size) }
        progress(state)

        let existing = Set(try await target.list(directory).map(\.name))
        let rootName = Self.uniqueName(item.name, avoiding: existing)
        let root = Self.join(directory, rootName)

        for entry in plan {
            try Task.checkCancellation()
            let destination = entry.relative.isEmpty ? root : Self.join(root, entry.relative)
            if entry.item.isDirectory {
                try await target.createDirectory(destination)
            } else {
                state.current = entry.item.name
                progress(state)
                try await Self.copyFile(entry.item.path, from: source, to: destination, in: target)
                state.filesDone += 1
                state.bytesDone += entry.item.size
                progress(state)
            }
        }

        if move {
            try await deleteRecursively(item, from: source)
        }
    }

    /// Lo que hay que copiar, carpetas antes que su contenido. `relative` es
    /// la ruta dentro de lo copiado; vacía para lo copiado mismo.
    private func collect(
        _ item: FileItem,
        from provider: any FileProvider,
        relative: String = ""
    ) async throws -> [(item: FileItem, relative: String)] {
        var result = [(item, relative)]
        guard item.isDirectory else { return result }
        for child in try await provider.list(item.path) {
            try Task.checkCancellation()
            let childRelative = relative.isEmpty ? child.name : Self.join(relative, child.name)
            result += try await collect(child, from: provider, relative: childRelative)
        }
        return result
    }

    /// Un fichero de un origen a otro, por un temporal en disco y no por
    /// memoria: un vídeo de varios gigas entre SFTP y SMB no cabe en la RAM
    /// del iPhone.
    private static func copyFile(
        _ path: String,
        from source: any FileProvider,
        to destination: String,
        in target: any FileProvider
    ) async throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("brunos-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try await source.download(path, to: staging)
        try await target.upload(from: staging, to: destination)
    }

    private func moveWithinProvider(_ item: FileItem, in provider: any FileProvider, to directory: String) async throws {
        // `rename` sólo cambia el nombre dentro de la misma carpeta: para
        // llevarlo a otra se copia y se borra, sin pasar por la memoria más de
        // un fichero cada vez.
        let parent = (item.path as NSString).deletingLastPathComponent
        if parent == directory { return }
        let plan = try await collect(item, from: provider)
        let root = Self.join(directory, item.name)
        for entry in plan {
            try Task.checkCancellation()
            let destination = entry.relative.isEmpty ? root : Self.join(root, entry.relative)
            if entry.item.isDirectory {
                try await provider.createDirectory(destination)
            } else {
                try await Self.copyFile(entry.item.path, from: provider, to: destination, in: provider)
            }
        }
        try await deleteRecursively(item, from: provider)
    }

    /// Borra una carpeta con todo lo de dentro.
    ///
    /// Por SFTP hace falta: `rmdir` sólo borra carpetas vacías, y sin esto
    /// borrar una carpeta con algo dentro fallaba.
    func deleteRecursively(_ item: FileItem, from provider: any FileProvider) async throws {
        if item.isDirectory {
            for child in try await provider.list(item.path) {
                try await deleteRecursively(child, from: provider)
            }
        }
        try await provider.delete(item.path)
    }

    /// «Fotos» → «Fotos copia», «Fotos copia 2»… «nota.txt» → «nota copia.txt».
    static func uniqueName(_ name: String, avoiding existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var counter = 1
        while true {
            let suffix = counter == 1 ? " copia" : " copia \(counter)"
            let candidate = ext.isEmpty ? base + suffix : base + suffix + "." + ext
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

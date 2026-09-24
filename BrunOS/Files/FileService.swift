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

    /// Lo copiado o cortado, a la espera de pegarse. Varios elementos de una
    /// vez, siempre de un mismo origen: el de la ventana donde se copiaron.
    private(set) var clipboard: (provider: any FileProvider, items: [FileItem], isCut: Bool)?

    let externalFolders = ExternalFolderStore()

    /// **La última ubicación elegida en cualquier ventana**, que es donde se
    /// abre una ventana nueva. Cada `FilesPane` lleva la suya
    /// (`provider(forKey:)`): antes todas miraban ésta, y con dos ventanas de
    /// Ficheros cambiar de ubicación en una cambiaba lo que veía la otra.
    var currentProvider: any FileProvider {
        providers[min(currentIndex, providers.count - 1)]
    }

    /// La ubicación con esa clave (`key(of:)`), si sigue estando.
    func provider(forKey key: String) -> (any FileProvider)? {
        providers.first { Self.key(of: $0) == key }
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
        for host in AppServices.shared.hosts.hosts where !hiddenHosts.contains(host.id.uuidString) {
            providers.append(SFTPProvider(host: host))
        }

        for server in AppServices.shared.smbServers.servers {
            providers.append(SMBProvider(server: server))
        }

        // Se sigue en la misma ubicación aunque cambie de puesto: al quitar
        // una de más arriba, el índice solo apuntaría a otra.
        let current = Self.key(of: currentProvider)
        self.providers = providers
        currentIndex = providers.firstIndex { Self.key(of: $0) == current } ?? 0
    }

    /// Qué ubicación es, más allá del objeto: `rebuild()` los crea de nuevo.
    static func key(of provider: any FileProvider) -> String {
        switch provider {
        case let external as ExternalFolderProvider: "folder:\(external.folder.id)"
        case let sftp as SFTPProvider: "sftp:\(sftp.host.id)"
        case let smb as SMBProvider: "smb:\(smb.server.id)"
        default: "local"
        }
    }

    // MARK: - Quitar ubicaciones

    /// Las máquinas SSH que no se quieren ver en Ficheros. Siguen en el
    /// terminal: quitarlas de aquí no borra la máquina.
    private static let hiddenHostsKey = "files.hiddenHosts"

    private(set) var hiddenHosts: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: FileService.hiddenHostsKey) ?? []
    )

    /// Si una ubicación se puede quitar. El iPhone no: es la carpeta de la app.
    func canRemove(_ provider: any FileProvider) -> Bool {
        !(provider is LocalProvider)
    }

    /// Quita una ubicación de la barra lateral. Una carpeta añadida con el
    /// selector se olvida (el marcador), un servidor SMB se borra con su
    /// contraseña y una máquina SSH sólo se esconde de aquí.
    func remove(_ provider: any FileProvider) {
        switch provider {
        case let external as ExternalFolderProvider:
            externalFolders.remove(id: external.folder.id)
        case let smb as SMBProvider:
            // Avisa con su notificación, que vuelve a llamar a `rebuild()`.
            AppServices.shared.smbServers.remove(smb.server)
        case let sftp as SFTPProvider:
            setHidden(true, host: sftp.host.id)
        default:
            return
        }
        rebuild()
    }

    /// Las carpetas añadidas que ya no responden: servidores desmontados,
    /// USB desenchufados, carpetas borradas.
    var unavailableFolders: [ExternalFolderProvider] {
        providers.compactMap { $0 as? ExternalFolderProvider }.filter { !$0.isAvailable }
    }

    func removeUnavailable() {
        for provider in unavailableFolders {
            externalFolders.remove(id: provider.folder.id)
        }
        rebuild()
    }

    func setHidden(_ hidden: Bool, host id: UUID) {
        if hidden {
            hiddenHosts.insert(id.uuidString)
        } else {
            hiddenHosts.remove(id.uuidString)
        }
        UserDefaults.standard.set(Array(hiddenHosts), forKey: Self.hiddenHostsKey)
        rebuild()
    }

    func select(_ index: Int) {
        guard providers.indices.contains(index) else { return }
        currentIndex = index
    }

    // MARK: - Portapapeles

    func copy(_ items: [FileItem], from provider: any FileProvider) {
        guard !items.isEmpty else { return }
        clipboard = (provider, items, false)
    }

    func cut(_ items: [FileItem], from provider: any FileProvider) {
        guard !items.isEmpty else { return }
        clipboard = (provider, items, true)
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
        /// Se mueve en vez de copiar: cambia el rótulo de la barra.
        var isMove = false

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
    func paste(
        into directory: String,
        of target: any FileProvider,
        progress: @escaping @MainActor (Progress) -> Void
    ) async throws {
        guard let clipboard else { return }
        // Lo cortado se va de donde estaba: el portapapeles ya no sirve. Lo
        // copiado se puede volver a pegar, como en el Finder.
        if clipboard.isCut { self.clipboard = nil }
        try await transfer(
            clipboard.items,
            from: clipboard.provider,
            to: target,
            into: directory,
            move: clipboard.isCut,
            progress: progress
        )
    }

    /// Copia o mueve varias cosas de un origen a una carpeta de otro, o del
    /// mismo. Lo usan pegar y arrastrar.
    ///
    /// **Una sola barra para todo**: primero se recorre todo lo elegido para
    /// saber cuántos ficheros y bytes son, y luego se copia en orden. Dentro
    /// de cada fichero la barra avanza también (`TransferProgress`), para que
    /// un vídeo de varios gigas no se quede en 0 % hasta el final.
    func transfer(
        _ items: [FileItem],
        from source: any FileProvider,
        to target: any FileProvider,
        into directory: String,
        move: Bool,
        progress: @escaping @MainActor (Progress) -> Void
    ) async throws {
        for item in items where source === target && item.isDirectory
            && (directory == item.path || directory.hasPrefix(item.path + "/")) {
            // Meter una carpeta dentro de sí misma no tiene fin.
            throw FileError.failed("No se puede meter \(item.name) dentro de sí misma.")
        }

        var state = Progress()
        state.isMove = move

        // Mover dentro del mismo origen conserva el nombre y, si ya hay algo
        // que se llama igual, se para en vez de inventarse una «copia» de
        // algo que se quería mover.
        if move, source === target {
            var existing = Set(try await target.list(directory).map(\.name))
            let items = items.filter { ($0.path as NSString).deletingLastPathComponent != directory }
            if let clash = items.first(where: { existing.contains($0.name) }) {
                throw FileError.failed("Ya hay algo que se llama \(clash.name) en esa carpeta.")
            }
            state.filesTotal = items.count
            for item in items {
                try Task.checkCancellation()
                state.current = item.name
                progress(state)
                try await moveWithinProvider(item, in: target, to: directory)
                existing.insert(item.name)
                state.filesDone += 1
                progress(state)
            }
            return
        }

        state.current = "Contando…"
        progress(state)
        var plans: [(item: FileItem, plan: [(item: FileItem, relative: String)])] = []
        for item in items {
            let plan = try await collect(item, from: source)
            plans.append((item, plan))
        }
        let entries = plans.flatMap(\.plan)
        state.filesTotal = entries.filter { !$0.item.isDirectory }.count
        state.bytesTotal = entries.reduce(0) { $0 + ($1.item.isDirectory ? 0 : $1.item.size) }
        progress(state)

        var existing = Set(try await target.list(directory).map(\.name))
        for (item, plan) in plans {
            let rootName = Self.uniqueName(item.name, avoiding: existing)
            existing.insert(rootName)
            let root = Self.join(directory, rootName)

            for entry in plan {
                try Task.checkCancellation()
                let destination = entry.relative.isEmpty ? root : Self.join(root, entry.relative)
                if entry.item.isDirectory {
                    try await target.createDirectory(destination)
                } else {
                    state.current = entry.item.name
                    progress(state)
                    // Lo que va de este fichero, por encima de lo ya copiado.
                    let before = state
                    let throttle = ProgressThrottle { done in
                        Task { @MainActor in
                            var partial = before
                            partial.bytesDone = before.bytesDone + min(done, entry.item.size)
                            progress(partial)
                        }
                    }
                    try await TransferProgress.$report.withValue(throttle.report) {
                        try await Self.copyFile(
                            entry.item.path, size: entry.item.size,
                            from: source, to: destination, in: target
                        )
                    }
                    throttle.stop()
                    state.filesDone += 1
                    state.bytesDone += entry.item.size
                    progress(state)
                }
            }

            if move {
                try await deleteRecursively(item, from: source)
            }
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
        size: Int64 = 0,
        from source: any FileProvider,
        to destination: String,
        in target: any FileProvider
    ) async throws {
        // Sin copia intermedia cuando uno de los dos es el propio iPhone: un
        // vídeo de 4 GB al servidor no necesita otros 4 GB libres en el tmp.
        if source is LocalProvider {
            try await target.upload(from: URL(fileURLWithPath: path), to: destination)
            return
        }
        if target is LocalProvider {
            try await source.download(path, to: URL(fileURLWithPath: destination))
            return
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("brunos-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        // Por un temporal, el fichero viaja dos veces: bajar es la primera
        // mitad de la barra y subir la segunda. Si no, llegaría al final y
        // volvería a empezar.
        let report = TransferProgress.report
        let firstHalf: (@Sendable (Int64) -> Void)? = report.map { report in { done in report(done / 2) } }
        let secondHalf: (@Sendable (Int64) -> Void)? = report.map { report in { done in report(size / 2 + done / 2) } }
        try await TransferProgress.$report.withValue(firstHalf) {
            try await source.download(path, to: staging)
        }
        try await TransferProgress.$report.withValue(secondHalf) {
            try await target.upload(from: staging, to: destination)
        }
    }

    private func moveWithinProvider(_ item: FileItem, in provider: any FileProvider, to directory: String) async throws {
        // `rename` sólo cambia el nombre dentro de la misma carpeta: para
        // llevarlo a otra se copia y se borra, sin pasar por la memoria más de
        // un fichero cada vez.
        let parent = (item.path as NSString).deletingLastPathComponent
        if parent == directory { return }

        // En el propio servidor o disco, que es instantáneo. Si no se puede
        // (SMB entre compartidas distintas), se copia y se borra.
        if (try? await provider.move(item.path, to: Self.join(directory, item.name))) != nil { return }

        let plan = try await collect(item, from: provider)
        let root = Self.join(directory, item.name)
        for entry in plan {
            try Task.checkCancellation()
            let destination = entry.relative.isEmpty ? root : Self.join(root, entry.relative)
            if entry.item.isDirectory {
                try await provider.createDirectory(destination)
            } else {
                try await Self.copyFile(entry.item.path, size: entry.item.size, from: provider, to: destination, in: provider)
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


/// Cuánto lleva el fichero que se está copiando, en bytes.
///
/// Va por un valor de tarea y no por un parámetro de `download`/`upload`:
/// así el protocolo `FileProvider` no cambia, y cada origen informa si sabe
/// (SFTP a cada trozo, SMB con el aviso de AMSMB2). Los locales copian con
/// `copyItem`, que no dice nada, y se quedan sin barra por dentro.
enum TransferProgress {
    @TaskLocal static var report: (@Sendable (Int64) -> Void)?
}

/// Deja pasar un aviso de progreso cada décima de segundo como mucho. SFTP
/// avisa cada 256 KB y SMB más a menudo: repintar el panel a ese ritmo se
/// notaba en el cursor.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var stopped = false
    private let forward: @Sendable (Int64) -> Void

    init(_ forward: @escaping @Sendable (Int64) -> Void) {
        self.forward = forward
    }

    var report: @Sendable (Int64) -> Void {
        { [self] done in
            let now = Date()
            let pass: Bool = lock.withLock {
                guard !stopped, now.timeIntervalSince(last) >= 0.1 else { return false }
                last = now
                return true
            }
            if pass { forward(done) }
        }
    }

    /// Ya terminó el fichero: un aviso que llegue tarde pintaría la barra
    /// hacia atrás.
    func stop() {
        lock.withLock { stopped = true }
    }
}

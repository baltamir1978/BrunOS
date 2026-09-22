import Foundation
import Observation

/// De dónde viene una carpeta añadida, para el icono y para poder explicar qué
/// hacer cuando no está disponible.
///
/// **No hay API para preguntárselo a iOS.** No existe forma pública de saber si
/// una carpeta está en iCloud, en un USB o en un servidor de red, pero sus
/// rutas se distinguen: acertar con el icono y con el mensaje ayuda mucho más
/// que un genérico para todo.
enum ExternalFolderKind: String, Codable, Sendable {
    case iCloud
    case usb
    case server
    case folder

    var symbol: String {
        switch self {
        case .iCloud: "icloud"
        case .usb: "externaldrive"
        case .server: "externaldrive.connected.to.line.below"
        case .folder: "folder"
        }
    }

    var label: String {
        switch self {
        case .iCloud: "iCloud Drive"
        case .usb: "Disco conectado"
        case .server: "Servidor de red"
        case .folder: "Carpeta con permiso"
        }
    }

    /// Qué hacer cuando la carpeta no responde. Cada origen se cae por un
    /// motivo distinto y con una solución distinta.
    var unavailableHint: String {
        switch self {
        case .iCloud: "iCloud no responde. Mira que el iPhone tenga conexión."
        case .usb: "El disco no está conectado al iPhone."
        case .server:
            "El servidor no está conectado. Ábrelo una vez en la app Archivos del iPhone "
            + "(Examinar › ⋯ › Conectar a servidor) y vuelve aquí."
        case .folder: "La carpeta ya no está donde estaba."
        }
    }

    /// Los servidores de red montados por la app Archivos viven bajo
    /// `LiveFiles/com.apple.filesystems.smbclientd`; iCloud, en `Mobile
    /// Documents`; los discos, en `/Volumes`.
    static func detect(_ url: URL) -> Self {
        let path = url.path.lowercased()
        if path.contains("smbclientd") || path.contains("netfs") { return .server }
        if path.contains("mobile documents") || path.contains("icloud") { return .iCloud }
        if path.contains("/volumes/") { return .usb }
        return .folder
    }
}

/// Una ubicación añadida con el selector del sistema.
///
/// **El nombre y el tipo se guardan, no se deducen al vuelo.** Si un servidor
/// SMB no está montado, el marcador de seguridad no resuelve y antes la
/// ubicación desaparecía de la barra lateral sin decir nada: parecía que no se
/// hubiera añadido nunca. Con el nombre guardado sigue ahí, en gris, diciendo
/// qué hacer.
struct ExternalFolder: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var bookmark: Data
    var name: String
    var kind: ExternalFolderKind
    /// La ruta que tenía al añadirla, para el subtítulo de los ajustes.
    var location: String
}

/// Una carpeta de fuera del contenedor de la app: iCloud Drive, una carpeta de
/// Archivos, un disco USB o un servidor SMB montado en la app Archivos.
///
/// **En iOS las cuatro son lo mismo.** Se añaden con el selector de documentos
/// en modo carpeta y, a partir de ahí, se manejan igual: no hay API de «montar
/// un USB» ni cliente SMB en el SDK; hay carpetas a las que el usuario ha dado
/// permiso.
///
/// **El marcador de seguridad no es opcional.** Sin guardarlo, el permiso se
/// pierde al cerrar la app y a la vuelta la carpeta ya no se puede leer. Y cada
/// acceso tiene que ir entre `startAccessingSecurityScopedResource()` y su
/// pareja: olvidar el cierre agota los permisos del sistema y acaban fallando
/// todos, también los de las demás carpetas.
final class ExternalFolderProvider: FileProvider, @unchecked Sendable {

    let name: String
    let symbol: String
    let rootPath: String
    let kind: ExternalFolderKind

    let folder: ExternalFolder

    /// Se resolvió el marcador la última vez que se intentó.
    ///
    /// No es `let`: un servidor puede montarse y desmontarse mientras la app
    /// está abierta, y la barra lateral lo pinta en gris cuando no responde.
    private(set) var isAvailable: Bool

    /// **No es falible a propósito.** Antes, si el marcador no resolvía, el
    /// proveedor no se creaba y la ubicación se esfumaba de la interfaz. Ahora
    /// se crea igual y es `list` quien explica qué pasa.
    init(folder: ExternalFolder) {
        self.folder = folder
        self.name = folder.name
        self.kind = folder.kind
        self.symbol = folder.kind.symbol

        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: folder.bookmark,
            options: [],
            bookmarkDataIsStale: &isStale
        )
        self.rootPath = url?.path ?? folder.location
        self.isAvailable = url != nil
    }

    /// Ejecuta algo con la carpeta accesible, y siempre suelta el permiso.
    private func withAccess<T>(_ work: (URL) throws -> T) throws -> T {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: folder.bookmark,
            options: [],
            bookmarkDataIsStale: &isStale
        ) else {
            isAvailable = false
            throw FileError.failed("«\(name)» no está disponible. \(kind.unavailableHint)")
        }

        guard url.startAccessingSecurityScopedResource() else {
            isAvailable = false
            throw FileError.notPermitted(name)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        isAvailable = true

        // Un marcador caducado (el volumen se movió, el servidor se remontó en
        // otro punto) se renueva aquí mismo: si no, al siguiente arranque la
        // ubicación estaría muerta y habría que volver a añadirla a mano.
        if isStale, let renewed = try? url.bookmarkData() {
            Task { @MainActor [id = folder.id] in
                AppServices.shared.files.externalFolders.refresh(id: id, bookmark: renewed)
            }
        }

        return try work(url)
    }

    func list(_ path: String) async throws -> [FileItem] {
        try withAccess { _ in
            let url = URL(fileURLWithPath: path)
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
            return contents.map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return FileItem(
                    name: url.lastPathComponent,
                    path: url.path,
                    isDirectory: values?.isDirectory ?? false,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate
                )
            }
        }
    }

    func read(_ path: String) async throws -> Data {
        try withAccess { _ in try Data(contentsOf: URL(fileURLWithPath: path)) }
    }

    func write(_ data: Data, to path: String) async throws {
        try withAccess { _ in
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func delete(_ path: String) async throws {
        try withAccess { _ in try FileManager.default.removeItem(atPath: path) }
    }

    func rename(_ path: String, to newName: String) async throws {
        try withAccess { _ in
            let source = URL(fileURLWithPath: path)
            let destination = source.deletingLastPathComponent().appendingPathComponent(newName)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw FileError.failed("Ya existe algo con ese nombre.")
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    func createDirectory(_ path: String) async throws {
        try withAccess { _ in
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: false
            )
        }
    }

    func localURL(for item: FileItem) async throws -> URL {
        // Se copia a un temporal en lugar de devolver la ruta original: el
        // visor abre el fichero más tarde, fuera del `withAccess`, y para
        // entonces el permiso ya estaría cerrado.
        let data = try await read(item.path)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(item.name)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Guarda qué carpetas externas se han añadido.
@MainActor
@Observable
final class ExternalFolderStore {

    private static let key = "files.externalFolders.v2"
    /// La primera versión guardaba sólo los marcadores, sin nombre ni tipo.
    private static let legacyKey = "files.externalFolders"

    private(set) var folders: [ExternalFolder] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([ExternalFolder].self, from: data) {
            folders = stored
        } else if let legacy = UserDefaults.standard.array(forKey: Self.legacyKey) as? [Data] {
            folders = legacy.compactMap(Self.migrate)
            save()
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        }
    }

    /// Un marcador suelto de la primera versión: se resuelve una vez para
    /// sacarle el nombre y el tipo, y se guarda ya completo.
    private static func migrate(_ bookmark: Data) -> ExternalFolder? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return ExternalFolder(
            bookmark: bookmark,
            name: url.lastPathComponent,
            kind: ExternalFolderKind.detect(url),
            location: url.path
        )
    }

    @discardableResult
    func add(_ url: URL) throws -> ExternalFolder {
        guard url.startAccessingSecurityScopedResource() else {
            throw FileError.notPermitted(url.lastPathComponent)
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        // Sin repetir: añadir dos veces la misma carpeta llenaría la barra
        // lateral de duplicados.
        if let existing = folders.first(where: { $0.bookmark == bookmark || $0.location == url.path }) {
            return existing
        }

        let folder = ExternalFolder(
            bookmark: bookmark,
            name: url.lastPathComponent,
            kind: ExternalFolderKind.detect(url),
            location: url.path
        )
        folders.append(folder)
        save()
        return folder
    }

    func remove(id: UUID) {
        folders.removeAll { $0.id == id }
        save()
    }

    func rename(id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = clean
        save()
    }

    /// Renueva un marcador caducado sin perder el nombre que tuviera puesto.
    func refresh(id: UUID, bookmark: Data) {
        guard let index = folders.firstIndex(where: { $0.id == id }),
              folders[index].bookmark != bookmark
        else { return }
        folders[index].bookmark = bookmark
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

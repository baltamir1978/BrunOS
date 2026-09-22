import Foundation
import UIKit

/// Una carpeta de fuera del contenedor de la app: iCloud Drive, una carpeta de
/// Archivos o la unidad USB del adaptador.
///
/// **En iOS las tres son lo mismo.** Se añaden con el selector de documentos en
/// modo carpeta y, a partir de ahí, se manejan igual: no hay una API de «montar
/// un USB», hay carpetas a las que el usuario ha dado permiso.
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

    let bookmark: Data

    init?(bookmark: Data) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        self.bookmark = bookmark
        self.rootPath = url.path
        self.name = url.lastPathComponent

        // El icono se deduce de la ruta. No hay forma de preguntarle a iOS si
        // una carpeta está en iCloud o en un USB, pero sus rutas se distinguen
        // y acertar con el icono ayuda más que un genérico para todo.
        let path = url.path.lowercased()
        if path.contains("mobile documents") || path.contains("icloud") {
            symbol = "icloud"
        } else if path.contains("/volumes/") {
            symbol = "externaldrive"
        } else {
            symbol = "folder"
        }
    }

    /// Ejecuta algo con la carpeta accesible, y siempre suelta el permiso.
    private func withAccess<T>(_ work: (URL) throws -> T) throws -> T {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            bookmarkDataIsStale: &isStale
        ) else {
            throw FileError.notFound(name)
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw FileError.notPermitted(name)
        }
        defer { url.stopAccessingSecurityScopedResource() }
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

    private static let key = "files.externalFolders"

    private(set) var bookmarks: [Data] = []

    init() {
        if let stored = UserDefaults.standard.array(forKey: Self.key) as? [Data] {
            bookmarks = stored
        }
    }

    func add(_ url: URL) throws {
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
        guard !bookmarks.contains(bookmark) else { return }
        bookmarks.append(bookmark)
        save()
    }

    func remove(bookmark: Data) {
        bookmarks.removeAll { $0 == bookmark }
        save()
    }

    func remove(at index: Int) {
        guard bookmarks.indices.contains(index) else { return }
        bookmarks.remove(at: index)
        save()
    }

    private func save() {
        UserDefaults.standard.set(bookmarks, forKey: Self.key)
    }
}

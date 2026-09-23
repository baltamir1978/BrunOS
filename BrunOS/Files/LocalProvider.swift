import Foundation

/// Los ficheros del propio iPhone: el contenedor de BrunOS.
///
/// Es lo que se ve desde la app Archivos en «En mi iPhone › BrunOS», porque el
/// `Info.plist` lleva `UIFileSharingEnabled`. Aquí caen las descargas del
/// navegador.
final class LocalProvider: FileProvider, @unchecked Sendable {

    let name = "iPhone"
    let symbol = "iphone"

    let rootPath: String

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootPath = documents.path

        // La carpeta de descargas existe desde el primer momento, aunque no se
        // haya descargado nada: una carpeta que aparece sola al usar el
        // navegador desconcierta más que ayuda.
        let downloads = documents.appendingPathComponent("Descargas", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    func list(_ path: String) async throws -> [FileItem] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                // Sin los ocultos: en el contenedor de una app son metadatos
                // del sistema que no le importan a nadie.
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw FileError.failed(error.localizedDescription)
        }

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

    func read(_ path: String) async throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    func write(_ data: Data, to path: String) async throws {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    func delete(_ path: String) async throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    func rename(_ path: String, to newName: String) async throws {
        let source = URL(fileURLWithPath: path)
        let destination = source.deletingLastPathComponent().appendingPathComponent(newName)

        // No se pisa nada por descuido: renombrar sobre un fichero existente
        // lo borraría sin avisar.
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FileError.failed("Ya existe algo con ese nombre.")
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    func createDirectory(_ path: String) async throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: false
            )
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    func move(_ path: String, to destination: String) async throws {
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw FileError.failed("Ya existe algo con ese nombre.")
        }
        do {
            try FileManager.default.moveItem(atPath: path, toPath: destination)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    func download(_ path: String, to url: URL) async throws {
        try Self.copy(URL(fileURLWithPath: path), to: url)
    }

    func upload(from url: URL, to path: String) async throws {
        try Self.copy(url, to: URL(fileURLWithPath: path))
    }

    /// Copia de disco a disco: la hace el sistema, sin pasar por memoria, y
    /// en el mismo volumen es un clon instantáneo.
    static func copy(_ source: URL, to destination: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
    }

    func localURL(for item: FileItem) async throws -> URL {
        URL(fileURLWithPath: item.path)
    }
}

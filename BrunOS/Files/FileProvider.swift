import Foundation
import UniformTypeIdentifiers

/// Una entrada de un directorio, venga de donde venga.
struct FileItem: Identifiable, Equatable, Sendable {
    var id: String { path }

    var name: String
    /// Ruta completa dentro del proveedor.
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?

    /// Tipo deducido por la extensión.
    ///
    /// Se mira la extensión y no el contenido: leer la cabecera de cada fichero
    /// para listar una carpeta sería lentísimo por SFTP, y para elegir icono y
    /// visor la extensión acierta casi siempre.
    var type: UTType? {
        guard !isDirectory else { return .folder }
        return UTType(filenameExtension: (name as NSString).pathExtension)
    }

    var kind: Kind {
        guard !isDirectory else { return .folder }
        guard let type else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .audio) { return .media }
        if type == .pdf { return .pdf }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
        return .other
    }

    enum Kind {
        case folder, image, media, pdf, text, other
    }

    /// Tamaño en unidades legibles. Las carpetas no lo muestran: contarlo
    /// obligaría a recorrerlas enteras, y por SFTP eso no se hace gratis.
    var sizeLabel: String {
        guard !isDirectory else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var modifiedLabel: String {
        guard let modified else { return "—" }
        return modified.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Lo que cualquier origen de ficheros tiene que saber hacer.
///
/// Lo cumplen por igual los ficheros del propio iPhone, una carpeta de iCloud,
/// un disco USB y una máquina por SFTP. El panel no sabe con cuál está
/// hablando, que es lo que permite copiar de uno a otro sin casos especiales.
protocol FileProvider: AnyObject, Sendable {

    /// Lo que se rotula en la barra lateral.
    var name: String { get }
    var symbol: String { get }

    /// Dónde se empieza al abrirlo.
    var rootPath: String { get }

    func list(_ path: String) async throws -> [FileItem]
    func read(_ path: String) async throws -> Data
    func write(_ data: Data, to path: String) async throws
    func delete(_ path: String) async throws
    func rename(_ path: String, to newName: String) async throws
    func createDirectory(_ path: String) async throws

    /// Una URL local del fichero, para poder enseñarlo.
    ///
    /// En local es el fichero mismo; en SFTP habrá que descargarlo a un
    /// temporal antes. Por eso devuelve una URL y no un `Data`: un vídeo de
    /// medio giga no cabe en memoria.
    func localURL(for item: FileItem) async throws -> URL
}

extension FileProvider {
    /// Sube un nivel, o `nil` si ya se está en la raíz.
    func parent(of path: String) -> String? {
        guard path != rootPath, path.count > rootPath.count else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? rootPath : parent
    }
}

/// Errores que el panel sabe enseñar.
enum FileError: LocalizedError {
    case notFound(String)
    case notPermitted(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name): "No se encuentra \(name)."
        case .notPermitted(let name): "Sin permiso para \(name)."
        case .failed(let reason): reason
        }
    }
}

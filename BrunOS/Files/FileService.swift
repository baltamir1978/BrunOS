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

        for bookmark in externalFolders.bookmarks {
            if let provider = ExternalFolderProvider(bookmark: bookmark) {
                providers.append(provider)
            }
        }

        // Las máquinas SSH salen solas: si ya están configuradas para el
        // terminal, no tiene sentido volver a darlas de alta aquí.
        for host in AppServices.shared.hosts.hosts {
            providers.append(SFTPProvider(host: host))
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

    /// Pega lo copiado en una carpeta del origen actual.
    ///
    /// Funciona igual dentro de un origen que entre dos distintos, incluido
    /// local ↔ SFTP: se lee de uno y se escribe en el otro. Las carpetas no se
    /// copian todavía; hacerlo bien pide recorrerlas enteras y una barra de
    /// progreso de verdad.
    func paste(into directory: String) async throws {
        guard let clipboard else { return }
        guard !clipboard.item.isDirectory else {
            throw FileError.failed("Copiar carpetas enteras todavía no está hecho.")
        }

        let destination = directory.hasSuffix("/")
            ? directory + clipboard.item.name
            : directory + "/" + clipboard.item.name

        let data = try await clipboard.provider.read(clipboard.item.path)
        try await currentProvider.write(data, to: destination)

        if clipboard.isCut {
            try await clipboard.provider.delete(clipboard.item.path)
        }
        self.clipboard = nil
    }
}

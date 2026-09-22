import Observation

/// Los orígenes de ficheros disponibles y cuál se está mirando.
///
/// De momento sólo el iPhone. iCloud, el USB y SFTP entran aquí cuando les
/// toque: el panel habla con el protocolo y no sabe con cuál está tratando, así
/// que añadirlos no cambia nada de la interfaz.
@MainActor
@Observable
final class FileService {

    private(set) var providers: [any FileProvider] = [LocalProvider()]
    private(set) var currentIndex = 0

    var currentProvider: any FileProvider {
        providers[min(currentIndex, providers.count - 1)]
    }

    func select(_ index: Int) {
        guard providers.indices.contains(index) else { return }
        currentIndex = index
    }
}

import Foundation
import Observation

/// Las descargas del navegador, todas juntas.
///
/// **Están fuera del panel a propósito.** Una descarga empieza en una pestaña,
/// pero sigue viva aunque esa pestaña se cierre o se cambie de espacio, y tiene
/// que poder verse desde cualquier panel de navegador, como el ⤓ de Safari.
///
/// Se guarda en memoria y nada más: la lista es de esta sesión, mientras que
/// los ficheros se quedan en Descargas, que es lo que importa.
@MainActor
@Observable
final class DownloadCenter {

    static let didChange = Notification.Name("BrunOSDownloadsDidChange")

    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var state: State
        var fraction: Double
        var bytesDone: Int64
        var bytesTotal: Int64
        /// Dónde ha quedado el fichero, cuando termina.
        var url: URL?
        var started = Date()

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }

        var isRunning: Bool { state == .running }

        /// Lo que se lee en el menú, debajo del nombre.
        var detail: String {
            switch state {
            case .running:
                let percent = Int((fraction * 100).rounded())
                guard bytesTotal > 0 else { return "\(percent) %" }
                return "\(percent) % · "
                    + ByteCountFormatter.string(fromByteCount: bytesDone, countStyle: .file)
                    + " de " + ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file)
            case .finished:
                let size = url.flatMap {
                    (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                }
                guard let size else { return "Terminada" }
                return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            case .failed(let reason):
                return reason
            case .cancelled:
                return "Cancelada"
            }
        }
    }

    private(set) var items: [Item] = []

    /// Cómo cancelar cada descarga en curso. Vive aquí y no en el `Item`
    /// porque un modelo que se compara y se copia no debería arrastrar
    /// closures.
    private var cancellers: [UUID: () -> Void] = [:]

    var hasRunning: Bool { items.contains { $0.isRunning } }

    /// Empieza a seguir una descarga. El nombre del fichero ya viene sin
    /// repetir (el destino se numera), así que sirve para encontrarla luego.
    func begin(name: String, cancel: @escaping () -> Void) {
        // Una descarga que se reintenta con el mismo nombre sustituye a la
        // anterior en la lista, en vez de dejar dos filas iguales.
        items.removeAll { $0.name == name && !$0.isRunning }
        let item = Item(name: name, state: .running, fraction: 0, bytesDone: 0, bytesTotal: 0)
        items.insert(item, at: 0)
        cancellers[item.id] = cancel
        changed()
    }

    func progress(name: String, fraction: Double, done: Int64, total: Int64) {
        guard let index = items.firstIndex(where: { $0.name == name && $0.isRunning }) else { return }
        items[index].fraction = fraction
        items[index].bytesDone = done
        items[index].bytesTotal = total
        changed()
    }

    func finish(name: String, url: URL) {
        guard let index = items.firstIndex(where: { $0.name == name && $0.isRunning }) else { return }
        items[index].state = .finished
        items[index].fraction = 1
        items[index].url = url
        cancellers[items[index].id] = nil
        changed()
    }

    func fail(name: String, reason: String) {
        // Si no se sabe cuál falló (el destino ya se había soltado), se marca
        // la que estuviera en curso: sólo puede ser ésa.
        let index = items.firstIndex { $0.name == name && $0.isRunning }
            ?? items.firstIndex { $0.isRunning }
        guard let index else { return }
        items[index].state = .failed(reason)
        cancellers[items[index].id] = nil
        changed()
    }

    func cancel(_ item: Item) {
        cancellers[item.id]?()
        cancellers[item.id] = nil
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].state = .cancelled
        changed()
    }

    func remove(_ item: Item) {
        cancellers[item.id] = nil
        items.removeAll { $0.id == item.id }
        changed()
    }

    /// Vacía la lista, no la carpeta: lo descargado se queda donde está.
    func clearFinished() {
        for item in items where !item.isRunning { cancellers[item.id] = nil }
        items.removeAll { !$0.isRunning }
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

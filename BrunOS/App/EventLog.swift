import Foundation

/// Las últimas cosas que le han pasado a la app: escenas que se conectan o se
/// van a segundo plano, el monitor que se engancha o se suelta, las vueltas
/// desde Atajos.
///
/// Sin el Modo de desarrollador no hay forma de sacar el log del iPhone, y los
/// fallos de este tipo (el iPhone en blanco al volver de Atajos, la pantalla
/// duplicada al arrancar) sólo se ven de vez en cuando. Así Bruno puede leer
/// en Ajustes › Rendimiento qué pasó justo antes. Se queda en memoria: al
/// cerrar la app se pierde, que para esto basta.
@MainActor
enum EventLog {

    private(set) static var entries: [(time: Date, text: String)] = []
    private static let limit = 30

    static func note(_ text: String) {
        entries.append((Date(), text))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        Log.display.info("\(text, privacy: .public)")
    }
}

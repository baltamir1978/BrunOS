import OSLog

/// Registro de BrunOS.
///
/// El subsistema **se saca del propio bundle** en vez de escribirlo a mano.
/// El identificador vive en `Local.xcconfig`, fuera del repositorio, así que
/// cualquiera que cambie ahí el bundle id encontraría los logs bajo un nombre
/// y el código buscándolos bajo otro.
///
/// Para leerlos, recordando que `.info` y `.debug` no salen sin `--level`:
/// ```
/// xcrun simctl spawn <sim> log stream --level debug \
///     --predicate 'subsystem == "<bundle id>"' --style compact
/// ```
enum Log {

    static let subsystem = Bundle.main.bundleIdentifier ?? "BrunOS"

    /// Pantalla externa: conexión, modos de vídeo, escala y overscan.
    static let display = Logger(subsystem: subsystem, category: "display")
    /// Escritorio: mosaico, foco y órdenes del gestor de ventanas.
    static let desktop = Logger(subsystem: subsystem, category: "desktop")
    /// Entrada: ratón, teclado y AssistiveTouch.
    static let input = Logger(subsystem: subsystem, category: "input")
}

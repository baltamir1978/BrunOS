import CoreGraphics
import Foundation

/// El escritorio tal como estaba, para dejarlo igual al volver a abrir la app:
/// qué ventanas había, dónde, y qué tenía cada una (pestañas, sesiones SSH,
/// carpeta). Lo pidió Bruno el 24-sep-2026.
///
/// Se guarda poco después de cada cambio y al irse a segundo plano, en
/// `desktop-session.json` de Application Support. **No guarda contenido**: de
/// una web, la dirección; de un terminal, a qué máquina estaba conectado.
struct SavedDesktop: Codable {

    struct Window: Codable {
        var kind: String
        /// El marco de una flotante; `nil` si estaba en el mosaico.
        var frame: CGRect?
        var isMinimized = false
        var isFocused = false

        /// Navegador: las direcciones de sus pestañas (`nil`, la de inicio).
        var tabs: [String?]?
        var activeTab: Int?
        /// Cuáles de esas pestañas iban fijadas.
        var pinnedTabs: [Bool]?

        /// Terminal: las máquinas de sus sesiones, por su id.
        var hosts: [UUID]?
        var activeHost: Int?

        /// Ficheros: la ubicación (`FileService.key(of:)`) y la carpeta.
        var location: String?
        var path: String?
    }

    var windows: [Window]
    /// El tamaño lógico del escritorio al guardar: con otra escala u otro
    /// monitor, las ventanas se reparten en proporción.
    var logicalSize: CGSize
}

@MainActor
enum SessionStore {

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "desktop-session.json")
    }

    private static var pendingSave: Task<Void, Never>?

    static func load() -> SavedDesktop? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SavedDesktop.self, from: data)
    }

    /// Se guarda un momento después del último cambio: al arrastrar una
    /// ventana llegan decenas seguidos.
    static func scheduleSave(_ make: @escaping @MainActor () -> SavedDesktop?) {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            pendingSave = nil
            if let desktop = make() { write(desktop) }
        }
    }

    static func saveNow(_ desktop: SavedDesktop?) {
        pendingSave?.cancel()
        pendingSave = nil
        if let desktop { write(desktop) }
    }

    private static func write(_ desktop: SavedDesktop) {
        guard let data = try? JSONEncoder().encode(desktop) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}

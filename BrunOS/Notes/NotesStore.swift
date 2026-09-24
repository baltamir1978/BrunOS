import Foundation
import UIKit

/// Una nota: texto plano, como las de un bloc. La primera línea hace de título.
struct Note: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var text = ""
    var modified = Date()
    var isPinned = false

    /// La primera línea con algo escrito, o «Nota nueva».
    var title: String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? "Nota nueva" : String(line.prefix(60))
    }

    /// Lo que sigue a la primera línea, para la lista.
    var preview: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1 else { return "" }
        return lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Las notas, guardadas en `notes.json` de Application Support.
///
/// Todas las ventanas de Notas comparten este almacén: escribir en una se ve
/// en las demás (`didChange`). Se guarda un momento después del último cambio,
/// no con cada tecla, y al irse la app a segundo plano.
@MainActor
final class NotesStore {

    static let didChange = Notification.Name("BrunOSNotesDidChange")

    private(set) var notes: [Note] = []
    private var pendingSave: Task<Void, Never>?

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "notes.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([Note].self, from: data) {
            notes = saved
        }
    }

    /// Fijadas primero; dentro de cada grupo, la última tocada arriba.
    var sorted: [Note] {
        notes.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.modified > b.modified
        }
    }

    func note(_ id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    @discardableResult
    func create(text: String = "") -> Note {
        let note = Note(text: text)
        notes.append(note)
        changed()
        return note
    }

    func update(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].modified = Date()
        changed()
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPinned.toggle()
        changed()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
    }
}

/// Lo que ha pasado por el portapapeles, para volver a pegarlo.
///
/// **Sólo se apunta lo que BrunOS copia o pega.** Leer el portapapeles cuando
/// lo ha llenado otra app hace que iOS pregunte «¿Permitir pegar?» en la
/// pantalla del iPhone, que con monitor está en negro: el aviso saldría a
/// ciegas cada dos por tres. Así que lo de fuera se ve cuando cambia
/// (`changeCount`, que no avisa) y se guarda al pulsar, o al pegarlo con Cmd+V.
///
/// **No se guarda en disco**: por el portapapeles pasan contraseñas y tokens
/// copiados del terminal. Se pierde al cerrar la app, y se puede vaciar.
@MainActor
final class ClipboardHistory {

    static let didChange = Notification.Name("BrunOSClipboardDidChange")

    struct Clip: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var date = Date()
    }

    /// El más reciente primero. Como mucho 50.
    private(set) var clips: [Clip] = []
    private static let limit = 50

    /// El `changeCount` del último contenido que se ha visto: lo que ponga otra
    /// app lo sube y así se sabe que hay algo nuevo sin leerlo.
    private var seenChangeCount = UIPasteboard.general.changeCount

    /// Copia texto al portapapeles y lo apunta.
    func copy(_ text: String) {
        UIPasteboard.general.string = text
        record(text)
    }

    /// Copia una dirección (va como URL, que otras apps entienden mejor).
    func copy(_ url: URL) {
        UIPasteboard.general.url = url
        record(url.absoluteString)
    }

    /// Lee el portapapeles para pegar y lo apunta. Si lo puso otra app, iOS
    /// puede preguntar antes: es lo mismo que pasaba ya al pegar.
    func readForPaste() -> String? {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return nil }
        record(text)
        return text
    }

    /// Otra app ha dejado algo que todavía no se ha visto.
    var hasUnseenExternal: Bool {
        UIPasteboard.general.hasStrings && UIPasteboard.general.changeCount != seenChangeCount
    }

    /// Vuelve a poner un recorte en el portapapeles, arriba de la lista.
    func restore(_ clip: Clip) {
        copy(clip.text)
    }

    func remove(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func clear() {
        clips = []
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func record(_ text: String) {
        seenChangeCount = UIPasteboard.general.changeCount
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Lo mismo otra vez sube arriba, no se repite.
        clips.removeAll { $0.text == text }
        clips.insert(Clip(text: text), at: 0)
        if clips.count > Self.limit { clips.removeLast(clips.count - Self.limit) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

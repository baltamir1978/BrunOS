import Foundation
import UIKit

/// Una nota. Su contenido, con formato, lo guarda `NotesStore`; aquí va el
/// texto plano, para la lista y el título. La primera línea hace de título.
struct Note: Identifiable, Equatable, Sendable {
    var id = UUID()
    var text = ""
    var modified = Date()
    var isPinned = false
    /// Su fichero en la carpeta de notas, con la extensión.
    var fileName = ""

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

/// El aspecto del texto de las notas.
///
/// **Helvetica Neue** y no la IBM Plex del resto de la app: Plex no trae
/// cursiva, y un RTF con Helvetica lo abre bien cualquier editor.
enum NoteStyle {
    static let size: CGFloat = 15

    static var baseFont: UIFont {
        UIFont(name: "HelveticaNeue", size: size) ?? .systemFont(ofSize: size)
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont]
    }

    /// Lo que se guarda sin colores: el del texto lo pone el modo claro u
    /// oscuro al enseñarlo, y en el fichero quedaría fijo.
    static func stripped(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: copy.length)
        copy.removeAttribute(.foregroundColor, range: whole)
        copy.removeAttribute(.backgroundColor, range: whole)
        return copy
    }
}

/// Las notas, **como ficheros RTF en `Documentos/Notas`** (Bruno, 24-sep-2026):
/// se ven desde la app Archivos y desde Ficheros, y las abre cualquier editor.
/// Un `.rtf` o un `.txt` que se deje en esa carpeta sale como nota.
///
/// Lo que el RTF no guarda —cuál es cada nota y si está fijada— va en un
/// índice pequeño en Application Support. Antes todo iba en `notes.json` en
/// texto plano; se pasa a ficheros la primera vez.
///
/// Todas las ventanas de Notas comparten este almacén: escribir en una se ve
/// en las demás (`didChange`). Se guarda un momento después del último cambio,
/// no con cada tecla, y al irse la app a segundo plano.
@MainActor
final class NotesStore {

    static let didChange = Notification.Name("BrunOSNotesDidChange")

    private(set) var notes: [Note] = []
    /// El contenido de cada nota, con formato.
    private var contents: [UUID: NSAttributedString] = [:]
    /// Las que han cambiado y falta escribir.
    private var dirty: Set<UUID> = []
    private var pendingSave: Task<Void, Never>?

    /// La carpeta de las notas, dentro de lo que se ve en Archivos.
    static var folder: URL {
        URL.documentsDirectory.appending(path: "Notas", directoryHint: .isDirectory)
    }

    private static var indexURL: URL {
        URL.applicationSupportDirectory.appending(path: "notes-index.json")
    }

    /// Donde iban las notas antes, en texto plano.
    private static var legacyURL: URL {
        URL.applicationSupportDirectory.appending(path: "notes.json")
    }

    private struct IndexEntry: Codable {
        var id: UUID
        var fileName: String
        var isPinned: Bool
    }

    private struct LegacyNote: Codable {
        var id: UUID
        var text: String
        var modified: Date
        var isPinned: Bool
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        migrateLegacy()
        loadFromDisk()
    }

    // MARK: - Leer

    /// Lee la carpeta: lo del índice conserva su id y si estaba fijado; lo
    /// nuevo (un fichero dejado desde Archivos) entra como nota.
    private func loadFromDisk() {
        let index = (try? Data(contentsOf: Self.indexURL))
            .flatMap { try? JSONDecoder().decode([IndexEntry].self, from: $0) } ?? []
        let byName = Dictionary(index.map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })

        var loaded: [Note] = []
        var texts: [UUID: NSAttributedString] = [:]
        for url in Self.noteFiles() {
            guard let content = Self.read(url) else { continue }
            let entry = byName[url.lastPathComponent]
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let note = Note(
                id: entry?.id ?? UUID(),
                text: content.string,
                modified: modified,
                isPinned: entry?.isPinned ?? false,
                fileName: url.lastPathComponent
            )
            loaded.append(note)
            texts[note.id] = content
        }
        notes = loaded
        contents = texts
        // Un fichero nuevo (dejado desde Archivos) se apunta ya en el índice:
        // si no, cada vez que se relee la carpeta tendría un id distinto, y
        // la nota abierta saltaría a otra.
        if loaded.contains(where: { byName[$0.fileName] == nil }) { writeIndex() }
    }

    /// Los ficheros de notas de la carpeta: `.rtf` y `.txt`.
    private static func noteFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { ["rtf", "txt"].contains($0.pathExtension.lowercased()) }
    }

    private static func read(_ url: URL) -> NSAttributedString? {
        if url.pathExtension.lowercased() == "txt" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return NSAttributedString(string: text, attributes: NoteStyle.baseAttributes)
        }
        guard let text = try? NSAttributedString(
            url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
        ) else { return nil }
        return NoteStyle.stripped(text)
    }

    /// Pasa las notas de `notes.json` a ficheros, una vez.
    private func migrateLegacy() {
        guard let data = try? Data(contentsOf: Self.legacyURL),
              let legacy = try? JSONDecoder().decode([LegacyNote].self, from: data)
        else { return }
        var index: [IndexEntry] = []
        var used = Set<String>()
        for old in legacy {
            let note = Note(id: old.id, text: old.text, modified: old.modified, isPinned: old.isPinned)
            let name = Self.fileName(for: note.title, avoiding: used)
            used.insert(name.lowercased())
            let url = Self.folder.appending(path: name)
            let content = NSAttributedString(string: old.text, attributes: NoteStyle.baseAttributes)
            guard Self.write(content, to: url) else { return }
            try? FileManager.default.setAttributes([.modificationDate: old.modified], ofItemAtPath: url.path)
            index.append(IndexEntry(id: old.id, fileName: name, isPinned: old.isPinned))
        }
        if let encoded = try? JSONEncoder().encode(index) { try? encoded.write(to: Self.indexURL, options: .atomic) }
        // Se deja con otro nombre en vez de borrarlo, por si acaso.
        try? FileManager.default.moveItem(at: Self.legacyURL, to: Self.legacyURL.appendingPathExtension("migrado"))
    }

    /// Al volver a la app: lo que se haya cambiado desde Archivos u otra app,
    /// salvo lo que esté a medio guardar aquí.
    func refreshFromDisk() {
        guard dirty.isEmpty else { return }
        let before = notes
        loadFromDisk()
        if notes != before { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    // MARK: - Consultar

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

    /// El contenido con formato, sin colores.
    func content(_ id: UUID) -> NSAttributedString {
        contents[id] ?? NSAttributedString(string: "", attributes: NoteStyle.baseAttributes)
    }

    // MARK: - Cambiar

    @discardableResult
    func create(text: String = "") -> Note {
        var note = Note(text: text)
        note.fileName = Self.fileName(for: note.title, avoiding: Set(notes.map { $0.fileName.lowercased() }))
        notes.append(note)
        contents[note.id] = NSAttributedString(string: text, attributes: NoteStyle.baseAttributes)
        dirty.insert(note.id)
        changed()
        return note
    }

    /// Cambia el contenido, con su formato.
    func update(_ id: UUID, content: NSAttributedString) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let stripped = NoteStyle.stripped(content)
        guard contents[id].map({ !$0.isEqual(to: stripped) }) ?? true else { return }
        contents[id] = stripped
        notes[index].text = stripped.string
        notes[index].modified = Date()
        dirty.insert(id)
        changed()
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPinned.toggle()
        changed()
    }

    func delete(_ id: UUID) {
        guard let note = note(id) else { return }
        try? FileManager.default.removeItem(at: Self.folder.appending(path: note.fileName))
        notes.removeAll { $0.id == id }
        contents[id] = nil
        dirty.remove(id)
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

    // MARK: - Guardar

    /// Escribe lo cambiado. Si el título ha cambiado, el fichero se renombra
    /// con él: en Archivos se reconoce cada nota por su nombre.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)

        for id in dirty {
            guard let index = notes.firstIndex(where: { $0.id == id }), let content = contents[id] else { continue }
            var note = notes[index]
            let others = Set(notes.filter { $0.id != id }.map { $0.fileName.lowercased() })
            let wanted = Self.fileName(for: note.title, avoiding: others)
            // Un .txt que llega de fuera se queda como .txt si sigue sin formato.
            let keepsText = note.fileName.lowercased().hasSuffix(".txt") && !Self.hasFormatting(content)
            let target = keepsText ? (wanted as NSString).deletingPathExtension + ".txt" : wanted
            if !note.fileName.isEmpty, note.fileName != target {
                try? FileManager.default.removeItem(at: Self.folder.appending(path: note.fileName))
            }
            note.fileName = target
            let url = Self.folder.appending(path: target)
            if keepsText {
                try? content.string.write(to: url, atomically: true, encoding: .utf8)
            } else {
                _ = Self.write(content, to: url)
            }
            notes[index] = note
        }
        dirty.removeAll()
        writeIndex()
    }

    private func writeIndex() {
        let index = notes.map { IndexEntry(id: $0.id, fileName: $0.fileName, isPinned: $0.isPinned) }
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? FileManager.default.createDirectory(
            at: Self.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: Self.indexURL, options: [.atomic, .completeFileProtection])
    }

    @discardableResult
    private static func write(_ content: NSAttributedString, to url: URL) -> Bool {
        let whole = NSRange(location: 0, length: content.length)
        guard let data = try? content.data(
            from: whole, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else { return false }
        return (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil
    }

    /// Si hay algo más que texto: negrita, cursiva, subrayado o enlaces.
    private static func hasFormatting(_ content: NSAttributedString) -> Bool {
        var found = false
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, _, stop in
            if attributes[.link] != nil || attributes[.underlineStyle] != nil {
                found = true
            } else if let font = attributes[.font] as? UIFont,
                      !font.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic]).isEmpty {
                found = true
            }
            if found { stop.pointee = true }
        }
        return found
    }

    /// Un nombre de fichero a partir del título, sin caracteres que no valgan
    /// y sin repetir el de otra nota.
    static func fileName(for title: String, avoiding taken: Set<String>) -> String {
        var base = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base.hasPrefix(".") { base = "Nota" }
        base = String(base.prefix(60))
        var name = base + ".rtf"
        var number = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(number).rtf"
            number += 1
        }
        return name
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

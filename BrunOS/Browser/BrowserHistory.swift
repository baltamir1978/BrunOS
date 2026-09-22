import Foundation

/// Historial y marcadores del navegador, para el lanzador (Cmd+P).
///
/// Se guardan en un JSON en Application Support y no salen del iPhone. Del
/// historial se queda **una entrada por dirección**, la última visita, y como
/// mucho 500: es para volver a encontrar una página, no un registro de todo lo
/// que se ha hecho.
@MainActor
final class BrowserHistory {

    struct Page: Codable, Equatable, Sendable {
        var url: String
        var title: String
        var visited: Date
    }

    private(set) var visits: [Page] = []
    private(set) var bookmarks: [Page] = []

    private static let limit = 500

    private let fileURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("browser-history.json")
    }()

    private struct Stored: Codable {
        var visits: [Page]
        var bookmarks: [Page]
    }

    init() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        visits = stored.visits
        bookmarks = stored.bookmarks
    }

    /// Apunta una visita. Sólo webs: ni la página de inicio ni ficheros locales.
    func record(url: URL, title: String?) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let address = url.absoluteString
        visits.removeAll { $0.url == address }
        visits.insert(Page(url: address, title: Self.clean(title, url: url), visited: Date()), at: 0)
        if visits.count > Self.limit { visits.removeLast(visits.count - Self.limit) }
        save()
    }

    func isBookmarked(_ url: URL) -> Bool {
        bookmarks.contains { $0.url == url.absoluteString }
    }

    /// Aviso para la barra de favoritos y la página de inicio, que se dibujan
    /// solas y no tienen forma de enterarse de otro modo.
    static let bookmarksDidChange = Notification.Name("BrunOSBookmarksDidChange")

    @discardableResult
    func toggleBookmark(url: URL, title: String?) -> Bool {
        let address = url.absoluteString
        let added: Bool
        if isBookmarked(url) {
            bookmarks.removeAll { $0.url == address }
            added = false
        } else {
            bookmarks.append(Page(url: address, title: Self.clean(title, url: url), visited: Date()))
            added = true
        }
        saveBookmarks()
        return added
    }

    func removeBookmark(_ page: Page) {
        bookmarks.removeAll { $0.url == page.url }
        saveBookmarks()
    }

    /// El nombre del favorito es de Bruno, no de la web: el `<title>` de
    /// muchas páginas es una frase entera y en la barra no cabe.
    func renameBookmark(_ page: Page, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = bookmarks.firstIndex(where: { $0.url == page.url }) else { return }
        bookmarks[index].title = clean
        saveBookmarks()
    }

    /// Mueve un favorito una posición: así se ordena la barra sin arrastrar,
    /// que con un cursor propio es incómodo.
    func moveBookmark(_ page: Page, by offset: Int) {
        guard let index = bookmarks.firstIndex(where: { $0.url == page.url }) else { return }
        let target = index + offset
        guard bookmarks.indices.contains(target) else { return }
        bookmarks.swapAt(index, target)
        saveBookmarks()
    }

    private func saveBookmarks() {
        save()
        NotificationCenter.default.post(name: Self.bookmarksDidChange, object: nil)
    }

    func clearHistory() {
        visits.removeAll()
        save()
    }

    private static func clean(_ title: String?, url: URL) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? (url.host() ?? url.absoluteString) : trimmed
    }

    private func save() {
        let stored = Stored(visits: visits, bookmarks: bookmarks)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

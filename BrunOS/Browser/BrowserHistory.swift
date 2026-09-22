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

    func toggleBookmark(url: URL, title: String?) {
        let address = url.absoluteString
        if isBookmarked(url) {
            bookmarks.removeAll { $0.url == address }
        } else {
            bookmarks.append(Page(url: address, title: Self.clean(title, url: url), visited: Date()))
        }
        save()
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

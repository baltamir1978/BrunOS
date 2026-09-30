import Foundation

/// Lee los favoritos del fichero HTML que exportan todos los navegadores
/// (Safari: Archivo › Exportar › Favoritos; Chrome y Firefox, desde su gestor
/// de marcadores). Es el formato de Netscape de toda la vida: una lista de
/// `<DT><A HREF="…">Título</A>`, con carpetas `<H3>` y listas `<DL>` anidadas.
///
/// Las carpetas se aplanan: la barra de favoritos de BrunOS no tiene
/// carpetas. **La lista de lectura de Safari se salta**: va en el mismo
/// fichero, en la carpeta `com.apple.ReadingList`, y son artículos para leer
/// una vez, no favoritos.
enum BookmarkImporter {

    struct Bookmark: Equatable {
        var url: String
        var title: String
    }

    static func parse(_ html: String) -> [Bookmark] {
        let pattern = #"<(/?)(dl|h3|a)\b([^>]*)>(?:([^<]*)</a>)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let text = html as NSString
        var result: [Bookmark] = []
        var seen = Set<String>()
        var depth = 0
        // Profundidad a la que empieza la lista de lectura, mientras se salta.
        var skipFrom: Int?
        var pendingReadingList = false

        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let closing = text.substring(with: match.range(at: 1)) == "/"
            let tag = text.substring(with: match.range(at: 2)).lowercased()
            let attributes = text.substring(with: match.range(at: 3))

            switch tag {
            case "h3" where !closing:
                pendingReadingList = attributes.contains("com.apple.ReadingList")
            case "dl" where !closing:
                depth += 1
                if pendingReadingList, skipFrom == nil { skipFrom = depth }
                pendingReadingList = false
            case "dl":
                if let start = skipFrom, depth == start { skipFrom = nil }
                depth -= 1
            case "a" where !closing:
                guard skipFrom == nil,
                      let href = attribute("href", in: attributes).map(decode),
                      let url = URL(string: href),
                      url.scheme == "http" || url.scheme == "https",
                      seen.insert(href).inserted
                else { continue }
                let rawTitle = match.range(at: 4).location == NSNotFound ? "" : text.substring(with: match.range(at: 4))
                let title = decode(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(Bookmark(url: href, title: title.isEmpty ? (url.host() ?? href) : title))
            default:
                break
            }
        }
        return result
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes))
        else { return nil }
        for group in [2, 3] {
            if let range = Range(match.range(at: group), in: attributes) { return String(attributes[range]) }
        }
        return nil
    }

    /// Las entidades que salen en estos ficheros: las cinco de siempre y las
    /// numéricas (`&#39;`, `&#x27;`).
    private static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let text = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: text.length)).reversed() {
                let hex = text.substring(with: match.range(at: 1)) == "x"
                let digits = text.substring(with: match.range(at: 2))
                guard let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) else { continue }
                result = (result as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        // `&amp;` al final: si no, `&amp;lt;` acabaría en «<».
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Escribe los favoritos en el mismo HTML de Netscape que lee
/// `BookmarkImporter`, el que importan Safari, Chrome y Firefox.
///
/// Van dentro de una carpeta «Barra de favoritos» marcada con
/// `PERSONAL_TOOLBAR_FOLDER`: Chrome y Firefox la llevan a su barra; Safari lo
/// deja todo en una carpeta de importados. `ADD_DATE` es cuándo se añadió.
enum BookmarkExporter {

    static func html(_ pages: [BrowserHistory.Page]) -> String {
        let now = Int(Date().timeIntervalSince1970)
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file.",
            "     It will be read and overwritten.",
            "     DO NOT EDIT! -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
            "    <DT><H3 ADD_DATE=\"\(now)\" LAST_MODIFIED=\"\(now)\" PERSONAL_TOOLBAR_FOLDER=\"true\">Barra de favoritos</H3>",
            "    <DL><p>",
        ]
        for page in pages {
            let added = Int(page.visited.timeIntervalSince1970)
            lines.append("        <DT><A HREF=\"\(escape(page.url))\" ADD_DATE=\"\(added)\">\(escape(page.title))</A>")
        }
        lines += ["    </DL><p>", "</DL><p>", ""]
        return lines.joined(separator: "\n")
    }

    /// El nombre del fichero, con la fecha: dos exportaciones del mismo día
    /// las numera `BrowserTab.uniqueDownloadURL`.
    static func fileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Favoritos de BrunOS \(formatter.string(from: date)).html"
    }

    /// Las entidades que deshace `BookmarkImporter.decode`, `&` la primera.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

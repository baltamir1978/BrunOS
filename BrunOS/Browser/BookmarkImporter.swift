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

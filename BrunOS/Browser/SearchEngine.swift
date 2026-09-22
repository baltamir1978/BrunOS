import Foundation

/// El buscador de la barra de direcciones. Se elige en Ajustes; Google por
/// defecto, que es lo que espera casi todo el mundo.
enum SearchEngine: String, CaseIterable, Sendable {
    case google
    case duckDuckGo
    case bing
    case startpage
    case ecosia

    private static let key = "browser.searchEngine"

    static var current: SearchEngine {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(SearchEngine.init(rawValue:)) ?? .google
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var label: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .startpage: "Startpage"
        case .ecosia: "Ecosia"
        }
    }

    /// Todos usan `q` para el texto buscado.
    private var base: String {
        switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .startpage: "https://www.startpage.com/do/search"
        case .ecosia: "https://www.ecosia.org/search"
        }
    }

    func url(for query: String) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

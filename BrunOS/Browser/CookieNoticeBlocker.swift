import Foundation
import JavaScriptCore
import Observation
import OSLog
import WebKit

/// Quita los avisos de cookies con las reglas de la extensión «I Still Don't
/// Care About Cookies» (ISDCAC), como hace ella en Safari o Firefox.
///
/// **No se redistribuye nada de la extensión**: es GPL-3 y BrunOS, MIT. Sus
/// reglas y sus scripts se bajan de su repositorio en el propio iPhone, igual
/// que las listas del bloqueador, y se renuevan cada 4 días.
///
/// **Lo que hace, lo mismo que la extensión** (`activateDomain` y
/// `doTheMagic` de su `background.js`): en cada marco, su CSS común
/// (`common.css`, que esconde los avisos y devuelve el scroll), el de las
/// incrustaciones y, si el sitio tiene regla propia, su CSS y su script
/// (pulsar el botón, poner la cookie o el `localStorage` que el aviso
/// espera); si no, el script genérico que busca el botón de aceptar.
///
/// **Lo que no**: su bloqueo de red (`rules.json`, reglas de
/// `declarativeNetRequest`), que ya cubren «Avisos de cookies» de uBlock y
/// EasyList en el bloqueador.
///
/// Sus scripts corren en un mundo de contenido **aparte** (`world`), sin los
/// canales del inyector de BrunOS: es código de fuera y no tiene por qué
/// poder fabricar clics por Swift.
@MainActor
@Observable
final class CookieNoticeBlocker {

    /// El mundo de contenido de los scripts de la extensión.
    static let world = WKContentWorld.world(name: "brunos-cookies")

    /// Interruptor general.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "browser.cookies") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "browser.cookies")
            notify()
        }
    }

    /// Sitios donde se apaga a mano, desde la galleta de la barra.
    private(set) var exceptions: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "browser.cookies.exceptions") ?? [])
    }()

    func isEnabled(for host: String?) -> Bool {
        guard isEnabled, let host else { return isEnabled }
        return !exceptions.contains(ContentBlocker.normalized(host))
    }

    func toggleException(for host: String) {
        let host = ContentBlocker.normalized(host)
        if exceptions.contains(host) {
            exceptions.remove(host)
        } else {
            exceptions.insert(host)
        }
        UserDefaults.standard.set(Array(exceptions), forKey: "browser.cookies.exceptions")
        notify()
    }

    private(set) var isReady = false
    private(set) var updated: Date?
    private(set) var lastError: String?
    private(set) var isUpdating = false
    /// Sitios con regla propia.
    private(set) var siteCount = 0

    var statusLine: String {
        if isUpdating { return "Descargando las reglas…" }
        guard isReady else { return lastError ?? "Sin bajar todavía" }
        var line = "\(siteCount.formatted()) sitios con regla propia"
        if let updated {
            line += " · " + Self.relative.localizedString(for: updated, relativeTo: Date())
        }
        return line
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    // MARK: - Reglas

    /// Lo que se saca de `rules.js`, ya listo para usar.
    private struct Rules: Codable, Sendable {
        struct Site: Codable, Sendable {
            /// CSS propio del sitio.
            var s: String?
            /// Uno de los CSS comunes (`commons`).
            var c: String?
            /// Uno de los scripts (`handlers`).
            var j: String?
        }

        var rules: [String: Site]
        var commons: [String: String]
        var handlers: [String: String]
    }

    private var rules: Rules?
    private var commonCSS = ""
    /// Nombre del script → su código.
    private var scripts: [String: String] = [:]

    private static let source = "https://raw.githubusercontent.com/OhMyGuus/I-Still-Dont-Care-About-Cookies/master/src/data/"
    private static let scriptNames = [
        "0_defaultClickHandler", "2_sessionStorageHandler", "3_localStorageHandler",
        "5_clickHandler", "6_cookieHandler", "8_googleHandler", "embedsHandler",
    ]
    private static let maxAge: TimeInterval = 4 * 24 * 3600

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "CookieNotices", directoryHint: .isDirectory)
    }()

    /// Lo bajado, si lo hay, y luego se renueva si ha caducado.
    func prepare() async {
        var directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        updated = UserDefaults.standard.object(forKey: "browser.cookies.updated") as? Date
        await load()
        let age = updated.map { -$0.timeIntervalSinceNow } ?? .infinity
        if !isReady || age > Self.maxAge {
            await update()
        }
    }

    func updateNow() {
        Task { await update() }
    }

    private func update() async {
        guard !isUpdating else { return }
        isUpdating = true
        notify()
        defer {
            isUpdating = false
            notify()
        }
        do {
            let directory = Self.directory
            // Todo o nada: con la mitad de los ficheros nuevos y la otra mitad
            // viejos, un script podría llamar a lo que el otro ya no tiene.
            var files: [(String, Data)] = []
            files.append(("rules.js", try await Self.fetch("rules.js")))
            files.append(("common.css", try await Self.fetch("css/common.css")))
            for name in Self.scriptNames {
                files.append(("\(name).js", try await Self.fetch("js/\(name).js")))
            }
            for (name, data) in files {
                try data.write(to: directory.appending(path: name), options: .atomic)
            }
            updated = Date()
            UserDefaults.standard.set(updated, forKey: "browser.cookies.updated")
            lastError = nil
            await load()
        } catch {
            lastError = "No se pudieron bajar las reglas de cookies: \(error.localizedDescription)"
            Log.browser.error("\(self.lastError ?? "")")
        }
    }

    private nonisolated static func fetch(_ path: String) async throws -> Data {
        guard let url = URL(string: source + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        return data
    }

    /// Lee lo bajado. `rules.js` es JavaScript, no JSON: se evalúa con
    /// JavaScriptCore, fuera del hilo principal, y se saca como JSON.
    private func load() async {
        let directory = Self.directory
        let names = Self.scriptNames
        let loaded: (Rules, String, [String: String])? = await Task.detached(priority: .utility) {
            guard let source = try? String(contentsOf: directory.appending(path: "rules.js"), encoding: .utf8),
                  let css = try? String(contentsOf: directory.appending(path: "common.css"), encoding: .utf8),
                  let rules = Self.parse(rules: source)
            else { return nil }
            var scripts: [String: String] = [:]
            for name in names {
                scripts[name] = try? String(contentsOf: directory.appending(path: "\(name).js"), encoding: .utf8)
            }
            return (rules, css, scripts)
        }.value

        guard let loaded else { return }
        let (rules, css, scripts) = loaded
        self.rules = rules
        commonCSS = css
        self.scripts = scripts
        siteCount = rules.rules.count
        isReady = true
        notify()
    }

    private nonisolated static func parse(rules source: String) -> Rules? {
        // Es un módulo: el `export` final no lo entiende un script suelto.
        let body = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("export ") }
            .joined(separator: "\n")
        let script = """
            (function () {
            \(body)
            ;
            const flat = {};
            for (const [host, rule] of Object.entries(rules)) {
                flat[host] = {
                    s: rule.s,
                    c: rule.c == null ? undefined : String(rule.c),
                    j: rule.j == null ? undefined : String(rule.j),
                };
            }
            return JSON.stringify({ rules: flat, commons: commons, handlers: commonJSHandlers });
            })()
            """
        guard let context = JSContext(),
              let json = context.evaluateScript(script)?.toString(),
              context.exception == nil,
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Rules.self, from: data)
    }

    // MARK: - Inyección

    /// El script que se mete en un marco de ese sitio, o `nil` si no toca.
    func injection(forHost rawHost: String) -> String? {
        guard isReady, let rules else { return nil }
        let host = Self.withoutWWW(rawHost.lowercased())

        var css = commonCSS
        var handler = "0_defaultClickHandler"
        // El sitio y luego sus padres, del más largo al más corto, como la
        // extensión: `a.b.ejemplo.com`, `b.ejemplo.com`, `ejemplo.com`.
        let parts = host.split(separator: ".")
        let levels = [host] + (stride(from: parts.count, through: 2, by: -1).map {
            parts.suffix($0).joined(separator: ".")
        })
        if let site = levels.lazy.compactMap({ rules.rules[$0] }).first {
            if let own = site.s { css += "\n" + own }
            if let common = site.c.flatMap({ rules.commons[$0] }) { css += "\n" + common }
            // Con regla propia, su script o ninguno: el genérico sólo va donde
            // no hay regla.
            handler = site.j.flatMap { rules.handlers[$0] } ?? ""
        }

        guard let cssLiteral = try? JSONEncoder().encode(css) else { return nil }
        var pieces = [
            """
            if (!window.__brunosCookies) {
            window.__brunosCookies = true;
            (function () {
                const css = \(String(decoding: cssLiteral, as: UTF8.self));
                function add() {
                    const style = document.createElement('style');
                    style.textContent = css;
                    (document.head || document.documentElement).appendChild(style);
                }
                if (document.documentElement) add();
                else document.addEventListener('readystatechange', add, { once: true });
            })();
            """,
        ]
        for name in ["embedsHandler", handler] where !name.isEmpty {
            guard let code = scripts[name] else { continue }
            pieces.append("try { (function () {\n\(code)\n})(); } catch (error) {}")
        }
        pieces.append("}")
        return pieces.joined(separator: "\n")
    }

    /// `www.`, `ww2.`, `www3.`… fuera, como `getHostname` de la extensión.
    private static func withoutWWW(_ host: String) -> String {
        guard let dot = host.firstIndex(of: ".") else { return host }
        let label = host[..<dot]
        let ws = label.prefix(while: { $0 == "w" })
        let rest = label.dropFirst(ws.count)
        guard (2...3).contains(ws.count), rest.allSatisfy(\.isNumber) else { return host }
        return String(host[host.index(after: dot)...])
    }

    /// Lo mismo que el bloqueador: las pestañas lo escuchan.
    private func notify() {
        NotificationCenter.default.post(name: ContentBlocker.didChangeNotification, object: nil)
    }
}

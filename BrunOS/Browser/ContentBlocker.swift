import Observation
import OSLog
import WebKit

/// Bloqueo de anuncios y rastreadores con `WKContentRuleList`.
///
/// Las listas las convierte un script en `Tools/` a partir de EasyList y
/// EasyPrivacy. **Lo generado no se versiona**: esas listas tienen licencia
/// propia y no se redistribuyen aquí.
///
/// **Sobre el contador de bloqueados.** `WKContentRuleList` no informa de
/// cuántas peticiones detiene: el filtrado ocurre dentro de WebKit y no hay
/// callback. Se puede fingir un número —contando peticiones que cuadren con las
/// reglas desde el lado de la app— pero sería un número inventado presentado
/// como un dato. **Se decidió quitar el contador** y rotular sólo si el
/// bloqueador está activo para el sitio actual. Un dato falso es peor que
/// ninguno.
@MainActor
@Observable
final class ContentBlocker {

    /// Reglas compiladas y listas para usar.
    private(set) var compiledLists: [WKContentRuleList] = []
    private(set) var isReady = false
    private(set) var lastError: String?

    /// Interruptor general.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "browser.blocker") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "browser.blocker")
            Task { await apply() }
        }
    }

    /// Sitios donde se desactiva a mano.
    private(set) var exceptions: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "browser.blocker.exceptions") ?? [])
    }()

    func isEnabled(for host: String?) -> Bool {
        guard isEnabled, let host else { return isEnabled }
        return !exceptions.contains(host)
    }

    func toggleException(for host: String) {
        if exceptions.contains(host) {
            exceptions.remove(host)
        } else {
            exceptions.insert(host)
        }
        UserDefaults.standard.set(Array(exceptions), forKey: "browser.blocker.exceptions")
    }

    // MARK: - Compilación

    /// Compila las listas que haya en el bundle y las deja en caché.
    ///
    /// `WKContentRuleListStore` guarda lo compilado en disco, así que sólo la
    /// primera vez cuesta tiempo. Se identifican por nombre de fichero.
    func prepare() async {
        guard let store = WKContentRuleListStore.default() else {
            lastError = "No hay almacén de reglas disponible."
            return
        }

        let files = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil)?
            .filter { $0.lastPathComponent.hasPrefix("blocklist-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        guard !files.isEmpty else {
            // Sin listas la app funciona igual, sólo que sin bloquear nada.
            // Se genera con Tools/fetch-blocklists.sh.
            lastError = "No hay listas. Ejecuta Tools/fetch-blocklists.sh y recompila."
            return
        }

        var compiled: [WKContentRuleList] = []
        for file in files {
            let identifier = file.deletingPathExtension().lastPathComponent
            // **La consulta de caché va en su propio `try?`, y no es un
            // detalle.** Cuando la lista todavía no está compilada,
            // `contentRuleList(forIdentifier:)` **lanza** en vez de devolver
            // nil, con un "Rule list lookup failed". Metiéndola en el mismo
            // `do` que la compilación, ese fallo saltaba al `catch` y la lista
            // no se compilaba nunca: el bloqueador no llegó a funcionar ni una
            // vez, y el error que se veía hacía pensar que las reglas estaban
            // mal escritas.
            if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                compiled.append(cached)
                continue
            }

            do {
                let source = try String(contentsOf: file, encoding: .utf8)
                if let list = try await store.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: source
                ) {
                    compiled.append(list)
                }
            } catch {
                // WebKit mete el motivo real en el userInfo; el
                // localizedDescription es siempre el mismo texto inútil.
                let details = (error as NSError).userInfo
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " · ")
                lastError = "No se pudo compilar \(identifier): \(error.localizedDescription)"
                Log.browser.error("\(self.lastError ?? "") · \(details)")
            }
        }

        compiledLists = compiled
        isReady = !compiled.isEmpty
        Log.browser.info("""
            Bloqueador listo: \(compiled.count) de \(files.count) listas compiladas\
            \(self.lastError.map { " · " + $0 } ?? "")
            """)
        await apply()
    }

    /// Mete o saca las reglas de todas las pestañas abiertas.
    private func apply() async {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    static let didChangeNotification = Notification.Name("BrunOSContentBlockerDidChange")

    /// Aplica las reglas a una configuración concreta.
    func install(into controller: WKUserContentController, host: String?) {
        controller.removeAllContentRuleLists()
        guard isEnabled(for: host) else { return }
        for list in compiledLists {
            controller.add(list)
        }
    }
}

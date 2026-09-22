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

    /// Una fuente de reglas: EasyList (anuncios), EasyPrivacy (rastreadores).
    ///
    /// Cada una llega troceada en varios ficheros, porque WebKit se atraganta
    /// por encima de unas 150.000 reglas por lista; aquí se agrupan otra vez
    /// para poder apagarlas por separado.
    struct Source: Identifiable, Sendable {
        var id: String
        var ruleCount: Int

        var label: String {
            switch id {
            case "easylist": "EasyList · anuncios"
            case "easyprivacy": "EasyPrivacy · rastreadores"
            default: id
            }
        }
    }

    /// Una regla de ocultación: un selector CSS, en todos los sitios o en uno.
    struct HideRule: Codable, Hashable, Sendable {
        var selector: String
        /// `nil` es en todas partes.
        var domain: String?
    }

    /// Reglas compiladas y listas para usar, por fuente.
    private var compiledBySource: [String: [WKContentRuleList]] = [:]
    /// Las reglas propias, compiladas aparte: cambian a menudo y recompilar las
    /// 114.000 de las fuentes cada vez sería absurdo.
    private var userList: WKContentRuleList?

    private(set) var sources: [Source] = []
    private(set) var isReady = false
    private(set) var lastError: String?

    var compiledLists: [WKContentRuleList] {
        compiledBySource.values.flatMap { $0 }
    }

    /// Interruptor general.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "browser.blocker") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "browser.blocker")
            notify()
        }
    }

    /// Fuentes apagadas a mano.
    private(set) var disabledSources: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "browser.blocker.disabledSources") ?? [])
    }()

    func isSourceEnabled(_ source: Source) -> Bool {
        !disabledSources.contains(source.id)
    }

    func setSource(_ source: Source, enabled: Bool) {
        if enabled {
            disabledSources.remove(source.id)
        } else {
            disabledSources.insert(source.id)
        }
        UserDefaults.standard.set(Array(disabledSources), forKey: "browser.blocker.disabledSources")
        notify()
    }

    /// Sitios donde se desactiva a mano.
    private(set) var exceptions: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "browser.blocker.exceptions") ?? [])
    }()

    func isEnabled(for host: String?) -> Bool {
        guard isEnabled, let host else { return isEnabled }
        return !exceptions.contains(Self.normalized(host))
    }

    func toggleException(for host: String) {
        let host = Self.normalized(host)
        if exceptions.contains(host) {
            exceptions.remove(host)
        } else {
            exceptions.insert(host)
        }
        UserDefaults.standard.set(Array(exceptions), forKey: "browser.blocker.exceptions")
        notify()
    }

    // MARK: - Reglas propias

    /// Dominios que se bloquean además de lo que traigan las listas.
    private(set) var blockedDomains: [String] = {
        UserDefaults.standard.stringArray(forKey: "browser.blocker.userDomains") ?? []
    }()

    /// Elementos que se ocultan, como el aviso fijo de una web concreta.
    private(set) var hideRules: [HideRule] = {
        guard let data = UserDefaults.standard.data(forKey: "browser.blocker.hideRules") else { return [] }
        return (try? JSONDecoder().decode([HideRule].self, from: data)) ?? []
    }()

    func addBlockedDomain(_ text: String) {
        let domain = Self.normalized(text)
        guard Self.isValidDomain(domain), !blockedDomains.contains(domain) else { return }
        blockedDomains.append(domain)
        saveUserRules()
    }

    func removeBlockedDomain(_ domain: String) {
        blockedDomains.removeAll { $0 == domain }
        saveUserRules()
    }

    func addHideRule(_ rule: HideRule) {
        let selector = rule.selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else { return }
        let domain = rule.domain.map(Self.normalized).flatMap { $0.isEmpty ? nil : $0 }
        let clean = HideRule(selector: selector, domain: domain)
        guard !hideRules.contains(clean) else { return }
        hideRules.append(clean)
        saveUserRules()
    }

    func removeHideRule(_ rule: HideRule) {
        hideRules.removeAll { $0 == rule }
        saveUserRules()
    }

    private func saveUserRules() {
        UserDefaults.standard.set(blockedDomains, forKey: "browser.blocker.userDomains")
        if let data = try? JSONEncoder().encode(hideRules) {
            UserDefaults.standard.set(data, forKey: "browser.blocker.hideRules")
        }
        Task { await compileUserRules() }
    }

    /// Lo que se escribe a mano llega con `https://`, barras o mayúsculas.
    /// WebKit quiere el dominio pelado y en minúsculas.
    static func normalized(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: value), let host = url.host() {
            value = host
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// **ASCII puro**: WebKit rechaza la lista entera, sin decir qué regla
    /// era, si un dominio lleva un carácter que no lo sea.
    static func isValidDomain(_ domain: String) -> Bool {
        domain.contains(".") && domain.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }
    }

    /// Compila las reglas propias en una lista aparte.
    private func compileUserRules() async {
        guard let store = WKContentRuleListStore.default() else { return }

        var rules: [[String: Any]] = []
        for domain in blockedDomains {
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            rules.append([
                "trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)[/:?#]"],
                "action": ["type": "block"],
            ])
        }
        for rule in hideRules {
            var trigger: [String: Any] = ["url-filter": ".*"]
            if let domain = rule.domain { trigger["if-domain"] = ["*" + domain] }
            rules.append([
                "trigger": trigger,
                "action": ["type": "css-display-none", "selector": rule.selector],
            ])
        }

        guard !rules.isEmpty else {
            userList = nil
            try? await store.removeContentRuleList(forIdentifier: Self.userIdentifier)
            notify()
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: rules)
            userList = try await store.compileContentRuleList(
                forIdentifier: Self.userIdentifier,
                encodedContentRuleList: String(decoding: data, as: UTF8.self)
            )
            lastError = nil
        } catch {
            // Un selector CSS mal escrito tumba la lista entera. Se dice cuál
            // es el problema en vez de dejar de bloquear en silencio.
            lastError = "Las reglas propias no compilan: \(error.localizedDescription)"
            Log.browser.error("\(self.lastError ?? "") · \((error as NSError).userInfo)")
        }
        notify()
    }

    private static let userIdentifier = "brunos-user-rules"

    // MARK: - Compilación

    /// Compila las listas que haya en el bundle y las deja en caché.
    ///
    /// `WKContentRuleListStore` guarda lo compilado en disco, así que sólo la
    /// primera vez cuesta tiempo. Se identifican por nombre de fichero, que es
    /// `blocklist-<fuente>-NN`.
    func prepare() async {
        guard let store = WKContentRuleListStore.default() else {
            lastError = "No hay almacén de reglas disponible."
            return
        }

        await compileUserRules()

        let files = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil)?
            .filter { $0.lastPathComponent.hasPrefix("blocklist-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        guard !files.isEmpty else {
            // Sin listas la app funciona igual, sólo que sin bloquear nada.
            // Se genera con Tools/fetch-blocklists.sh.
            lastError = "No hay listas. Ejecuta Tools/fetch-blocklists.sh y recompila."
            return
        }

        let manifest: [String: Int] = Bundle.main
            .url(forResource: "manifest-blocklists", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]

        var compiled: [String: [WKContentRuleList]] = [:]
        for file in files {
            let identifier = file.deletingPathExtension().lastPathComponent
            let source = Self.source(of: identifier)
            // **La consulta de caché va en su propio `try?`, y no es un
            // detalle.** Cuando la lista todavía no está compilada,
            // `contentRuleList(forIdentifier:)` **lanza** en vez de devolver
            // nil, con un "Rule list lookup failed". Metiéndola en el mismo
            // `do` que la compilación, ese fallo saltaba al `catch` y la lista
            // no se compilaba nunca: el bloqueador no llegó a funcionar ni una
            // vez, y el error que se veía hacía pensar que las reglas estaban
            // mal escritas.
            if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                compiled[source, default: []].append(cached)
                continue
            }

            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                if let list = try await store.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: text
                ) {
                    compiled[source, default: []].append(list)
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

        compiledBySource = compiled
        sources = compiled.keys.sorted().map { Source(id: $0, ruleCount: manifest[$0] ?? 0) }
        isReady = !compiled.isEmpty
        Log.browser.info("""
            Bloqueador listo: \(compiled.values.map(\.count).reduce(0, +)) de \(files.count) listas\
            \(self.lastError.map { " · " + $0 } ?? "")
            """)
        notify()
    }

    /// `blocklist-easylist-01` → `easylist`. Las de la generación anterior,
    /// `blocklist-01`, se agrupan como una sola fuente.
    private static func source(of identifier: String) -> String {
        let parts = identifier.split(separator: "-")
        return parts.count >= 3 ? String(parts[1]) : "listas"
    }

    /// Avisa a las pestañas para que vuelvan a instalar las reglas.
    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    static let didChangeNotification = Notification.Name("BrunOSContentBlockerDidChange")

    /// Aplica las reglas a una configuración concreta.
    func install(into controller: WKUserContentController, host: String?) {
        controller.removeAllContentRuleLists()
        guard isEnabled(for: host) else { return }
        for (source, lists) in compiledBySource where !disabledSources.contains(source) {
            for list in lists {
                controller.add(list)
            }
        }
        if let userList {
            controller.add(userList)
        }
    }
}

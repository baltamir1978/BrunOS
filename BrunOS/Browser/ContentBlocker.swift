import Observation
import OSLog
import WebKit

/// Bloqueo de anuncios y rastreadores con `WKContentRuleList`.
///
/// **Las listas se bajan en el propio iPhone** (24-sep-2026): las de uBlock
/// Origin (`FilterList.catalog`) y las que se añadan por dirección. Se
/// convierten con `FilterListConverter`, se compilan en el almacén de WebKit,
/// que las guarda en disco, y se renuevan cada 4 días. Antes venían en el
/// bundle, generadas en el Mac con un script, y sólo eran EasyList y
/// EasyPrivacy. **No se redistribuye ninguna lista**: tienen licencia propia.
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

    /// Una regla de ocultación: un selector CSS, en todos los sitios o en uno.
    struct HideRule: Codable, Hashable, Sendable {
        var selector: String
        /// `nil` es en todas partes.
        var domain: String?

        /// Con la sintaxis de AdBlock: `ejemplo.com##.banner` es el selector
        /// `.banner` en `ejemplo.com`; `##.banner` o `.banner`, en todas.
        static func parse(_ text: String) -> HideRule? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let range = trimmed.range(of: "##") else {
                return HideRule(selector: trimmed, domain: nil)
            }
            let domain = String(trimmed[..<range.lowerBound])
            let selector = String(trimmed[range.upperBound...])
            guard !selector.isEmpty else { return nil }
            return HideRule(selector: selector, domain: domain.isEmpty ? nil : domain)
        }
    }

    /// Las reglas propias, compiladas aparte: cambian a menudo y recompilar
    /// las de las listas cada vez sería absurdo.
    private var userList: WKContentRuleList?

    private(set) var isReady = false
    private(set) var lastError: String?

    /// Interruptor general.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "browser.blocker") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "browser.blocker")
            notify()
        }
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

    // MARK: - Listas

    /// Las del catálogo de uBlock Origin y las añadidas a mano.
    var catalog: [FilterList] {
        FilterList.catalog + customLists
    }

    /// Las encendidas. Sin tocar nada, las que trae uBlock Origin de serie.
    private(set) var enabledListIDs: Set<String> = {
        if let saved = UserDefaults.standard.stringArray(forKey: "browser.blocker.lists") {
            return Set(saved)
        }
        return Set(FilterList.catalog.filter(\.isDefault).map(\.id))
    }()

    func isListEnabled(_ list: FilterList) -> Bool {
        enabledListIDs.contains(list.id)
    }

    func setList(_ list: FilterList, enabled: Bool) {
        if enabled {
            enabledListIDs.insert(list.id)
        } else {
            enabledListIDs.remove(list.id)
        }
        UserDefaults.standard.set(Array(enabledListIDs), forKey: "browser.blocker.lists")
        notify()
        // Al encender o apagar varias seguidas, se convierte una sola vez.
        scheduleSync(after: 1.5)
    }

    /// Cuándo se bajó cada lista y cuántas reglas salieron de ella.
    struct ListInfo: Codable, Sendable {
        var updated: Date?
        var ruleCount: Int?
        var error: String?
    }

    private(set) var info: [String: ListInfo] = [:]

    /// Lo que está haciendo ahora: «Descargando EasyList…». `nil` en reposo.
    private(set) var activity: String?

    /// Cuántas reglas hay compiladas en total, de todas las listas.
    private(set) var totalRules = 0

    /// La línea de debajo de cada lista en los ajustes: «12.345 reglas · hace
    /// 2 días», o por qué no hay nada.
    func summary(of list: FilterList) -> String? {
        let entry = info[list.id]
        var parts: [String] = []
        if let count = entry?.ruleCount, entry?.updated != nil, isListEnabled(list) {
            parts.append("\(count.formatted()) reglas")
        }
        if let updated = entry?.updated {
            parts.append(Self.relative.localizedString(for: updated, relativeTo: Date()))
        } else if isListEnabled(list) {
            parts.append("sin bajar todavía")
        }
        if let error = entry?.error {
            parts.append("no se pudo bajar: \(error)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Lo de arriba del todo: qué hace ahora, o cuántas reglas hay.
    var statusLine: String {
        if let activity { return activity }
        let count = catalog.filter(isListEnabled).count
        guard isReady else { return count == 0 ? "Ninguna lista encendida" : "Sin compilar todavía" }
        return "\(totalRules.formatted()) reglas de \(count) listas"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    // MARK: - Listas propias

    private struct CustomList: Codable {
        var id: String
        var title: String
        var url: URL
    }

    private var customEntries: [CustomList] = {
        guard let data = UserDefaults.standard.data(forKey: "browser.blocker.customLists") else { return [] }
        return (try? JSONDecoder().decode([CustomList].self, from: data)) ?? []
    }()

    private var customLists: [FilterList] {
        customEntries.map { FilterList(id: $0.id, title: $0.title, group: .custom, url: $0.url) }
    }

    /// Añade una lista por su dirección y la enciende. El título sale de la
    /// cabecera `! Title:` de la propia lista al bajarla.
    func addCustomList(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http",
              url.host() != nil,
              !catalog.contains(where: { $0.url == url })
        else {
            lastError = "«\(trimmed)» no es la dirección de una lista (https://…)."
            notify()
            return
        }
        let entry = CustomList(id: "custom-" + UUID().uuidString, title: url.lastPathComponent, url: url)
        customEntries.append(entry)
        saveCustomLists()
        enabledListIDs.insert(entry.id)
        UserDefaults.standard.set(Array(enabledListIDs), forKey: "browser.blocker.lists")
        notify()
        scheduleSync(after: 0)
    }

    func removeCustomList(_ list: FilterList) {
        customEntries.removeAll { $0.id == list.id }
        saveCustomLists()
        enabledListIDs.remove(list.id)
        UserDefaults.standard.set(Array(enabledListIDs), forKey: "browser.blocker.lists")
        info[list.id] = nil
        try? FileManager.default.removeItem(at: Self.file(for: list.id))
        saveInfo()
        notify()
        scheduleSync(after: 0)
    }

    private func saveCustomLists() {
        if let data = try? JSONEncoder().encode(customEntries) {
            UserDefaults.standard.set(data, forKey: "browser.blocker.customLists")
        }
    }

    // MARK: - Plegar lo bloqueado

    /// Esconder los huecos que deja lo bloqueado, como uBlock: las imágenes
    /// que no llegan y los iframes de dominios de anuncios. Ver
    /// `BlockerCollapse.js`.
    var collapsesBlocked: Bool {
        get { UserDefaults.standard.object(forKey: "browser.blocker.collapse") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "browser.blocker.collapse")
            notify()
        }
    }

    /// Dominios bloqueados enteros, de las listas y de los propios.
    private var blockedHosts: Set<String> = []

    /// Si un iframe de ese dominio se ha quedado vacío por el bloqueador.
    /// Mira el dominio y sus padres: `ads.x.doubleclick.net` → … →
    /// `doubleclick.net`.
    func isBlockedHost(_ host: String) -> Bool {
        var candidate = Substring(host.lowercased())
        while candidate.contains(".") {
            if blockedHosts.contains(String(candidate)) || blockedDomains.contains(String(candidate)) {
                return true
            }
            guard let dot = candidate.firstIndex(of: ".") else { break }
            candidate = candidate[candidate.index(after: dot)...]
        }
        return false
    }

    // MARK: - Descarga, conversión y compilación

    /// Cada cuánto se vuelven a bajar: uBlock las renueva cada 4 o 5 días.
    private static let maxAge: TimeInterval = 4 * 24 * 3600

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Blocklists", directoryHint: .isDirectory)
    }()

    private static func file(for id: String) -> URL {
        directory.appending(path: "\(id).txt")
    }

    private static let infoFile = directory.appending(path: "info.json")
    private static let hostsFile = directory.appending(path: "blocked-hosts.txt")

    /// Lo compilado de las listas: los trozos de red y la ocultación.
    private var compiled: [WKContentRuleList] = []

    private var isSyncing = false
    private var syncAgain = false
    private var forceNextSync = false
    private var syncTimer: Timer?

    /// Al arrancar: lo que ya estaba compilado se usa enseguida, y luego se
    /// bajan las listas que falten o hayan caducado.
    func prepare() async {
        prepareDirectory()
        loadInfo()
        await removeLegacyLists()
        await compileUserRules()
        await loadCompiled()
        await sync(force: false)
    }

    /// «Actualizar ahora»: vuelve a bajar todas las encendidas.
    func updateNow() {
        forceNextSync = true
        scheduleSync(after: 0)
    }

    private func scheduleSync(after delay: TimeInterval) {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                let blocker = AppServices.shared.blocker
                let force = blocker.forceNextSync
                blocker.forceNextSync = false
                Task { await blocker.sync(force: force) }
            }
        }
    }

    /// Baja lo que haga falta y, si algo cambió, convierte y compila. Si llega
    /// otra petición mientras tanto, se da otra vuelta al terminar.
    private func sync(force: Bool) async {
        if isSyncing {
            syncAgain = true
            forceNextSync = forceNextSync || force
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            activity = nil
            notify()
        }

        var force = force
        repeat {
            syncAgain = false
            let lists = catalog.filter { enabledListIDs.contains($0.id) }
            for list in lists {
                let age = info[list.id]?.updated.map { -$0.timeIntervalSinceNow } ?? .infinity
                let missing = !FileManager.default.fileExists(atPath: Self.file(for: list.id).path)
                guard force || missing || age > Self.maxAge else { continue }
                activity = "Descargando \(list.title)…"
                notify()
                await download(list)
            }
            force = false
            if signature(for: lists) != UserDefaults.standard.string(forKey: "browser.blocker.signature") {
                await rebuild(lists)
            }
            if forceNextSync {
                forceNextSync = false
                force = true
                syncAgain = true
            }
        } while syncAgain
    }

    private func download(_ list: FilterList) async {
        var entry = info[list.id] ?? ListInfo()
        do {
            var text = try await Self.fetch(list.url)
            text = try await Self.expandIncludes(in: text, base: list.url)
            try Data(text.utf8).write(to: Self.file(for: list.id), options: .atomic)
            entry.updated = Date()
            entry.error = nil
            if list.group == .custom, let title = Self.title(of: text),
               let index = customEntries.firstIndex(where: { $0.id == list.id }) {
                customEntries[index].title = title
                saveCustomLists()
            }
        } catch {
            // Se queda con la copia anterior, si la había.
            entry.error = error.localizedDescription
            Log.browser.error("No se pudo bajar \(list.id): \(error.localizedDescription)")
        }
        info[list.id] = entry
        saveInfo()
    }

    private nonisolated static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { throw URLError(.zeroByteResource) }
        return text
    }

    /// `!#include filters-2026.txt`: la lista de uBlock «Anuncios» es casi
    /// toda trozos así. Sólo de la misma carpeta, como exige uBlock, y sólo
    /// los que caen fuera de un `!#if` falso (el de móviles, por ejemplo).
    private nonisolated static func expandIncludes(in text: String, base: URL) async throws -> String {
        guard text.contains("!#include ") else { return text }
        var output: [String] = []
        var conditions: [Bool] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("!#if ") {
                conditions.append(FilterListConverter.condition(String(trimmed.dropFirst(5))))
            } else if trimmed.hasPrefix("!#else") {
                if let last = conditions.popLast() { conditions.append(!last) }
            } else if trimmed.hasPrefix("!#endif") {
                _ = conditions.popLast()
            } else if trimmed.hasPrefix("!#include "), !conditions.contains(false) {
                let name = trimmed.dropFirst("!#include ".count).trimmingCharacters(in: .whitespaces)
                guard !name.contains("/"), !name.contains(".."), !name.isEmpty,
                      let url = URL(string: name, relativeTo: base)?.absoluteURL
                else { continue }
                output.append(try await fetch(url))
                continue
            }
            output.append(String(line))
        }
        return output.joined(separator: "\n")
    }

    private nonisolated static func title(of text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline).prefix(40) where line.hasPrefix("! Title:") {
            let title = line.dropFirst("! Title:".count).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    /// Qué hay compilado: si cambia, hay que volver a convertir.
    private func signature(for lists: [FilterList]) -> String {
        let parts = lists.map { list in
            "\(list.id)@\(info[list.id]?.updated?.timeIntervalSince1970 ?? 0)"
        }
        return "v\(FilterListConverter.version);" + parts.sorted().joined(separator: ";")
    }

    private static let networkPrefix = "brunos-filters-"
    private static let cosmeticIdentifier = "brunos-cosmetic"

    /// Convierte todas las listas encendidas juntas y las compila.
    private func rebuild(_ lists: [FilterList]) async {
        guard let store = WKContentRuleListStore.default() else { return }
        // La de lo que se convierte ahora: si mientras tanto se enciende otra,
        // la siguiente vuelta de `sync` verá que no cuadra.
        let builtSignature = signature(for: lists)
        activity = "Convirtiendo \(lists.count) listas…"
        notify()

        let files = lists.map { ($0.id, Self.file(for: $0.id)) }
        let output: FilterListConverter.Output
        do {
            output = try await Task.detached(priority: .utility) {
                var converter = FilterListConverter()
                for (id, url) in files {
                    guard let data = try? Data(contentsOf: url) else { continue }
                    converter.add(String(decoding: data, as: UTF8.self), list: id)
                }
                return try converter.build()
            }.value
        } catch {
            lastError = "No se pudieron convertir las listas: \(error.localizedDescription)"
            return
        }

        var compiledLists: [WKContentRuleList] = []
        var identifiers: [String] = []
        let sources: [(String, String)] = output.networkLists.enumerated().map {
            (Self.networkPrefix + String(format: "%02d", $0.offset), $0.element)
        } + (output.cosmeticList.map { [(Self.cosmeticIdentifier, $0)] } ?? [])

        var failed = false
        for (index, (identifier, json)) in sources.enumerated() {
            activity = "Compilando \(index + 1) de \(sources.count)…"
            notify()
            do {
                if let list = try await store.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: json
                ) {
                    compiledLists.append(list)
                    identifiers.append(identifier)
                }
            } catch {
                // WebKit mete el motivo real en el userInfo; el
                // localizedDescription es siempre el mismo texto inútil.
                let details = (error as NSError).userInfo
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " · ")
                lastError = "No se pudo compilar \(identifier): \(error.localizedDescription)"
                Log.browser.error("\(self.lastError ?? "") · \(details)")
                failed = true
            }
        }

        // Los trozos de una compilación anterior que ya no hacen falta.
        let previous = UserDefaults.standard.stringArray(forKey: "browser.blocker.compiled") ?? []
        for identifier in previous where !identifiers.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }

        for (id, count) in output.ruleCounts {
            info[id, default: ListInfo()].ruleCount = count
        }
        saveInfo()

        compiled = compiledLists
        blockedHosts = Set(output.blockedHosts)
        totalRules = output.ruleCounts.values.reduce(0, +)
        isReady = !compiledLists.isEmpty
        UserDefaults.standard.set(identifiers, forKey: "browser.blocker.compiled")
        UserDefaults.standard.set(totalRules, forKey: "browser.blocker.totalRules")
        // Si algo no compiló, que se vuelva a intentar en el próximo arranque.
        UserDefaults.standard.set(failed ? nil : builtSignature, forKey: "browser.blocker.signature")
        if !failed, lastError?.hasPrefix("No se pudo") == true { lastError = nil }

        let hosts = output.blockedHosts.joined(separator: "\n")
        let hostsFile = Self.hostsFile
        Task.detached(priority: .utility) {
            try? Data(hosts.utf8).write(to: hostsFile, options: .atomic)
        }
        Log.browser.info("Bloqueador listo: \(identifiers.count) listas de WebKit, \(self.totalRules) reglas")
        notify()
    }

    /// Lo compilado en un arranque anterior, sin volver a convertir nada.
    private func loadCompiled() async {
        guard let store = WKContentRuleListStore.default() else {
            lastError = "No hay almacén de reglas disponible."
            return
        }
        let identifiers = UserDefaults.standard.stringArray(forKey: "browser.blocker.compiled") ?? []
        var lists: [WKContentRuleList] = []
        for identifier in identifiers {
            // **La consulta va en su propio `try?`, y no es un detalle**:
            // cuando la lista no está compilada, `contentRuleList(forIdentifier:)`
            // **lanza** en vez de devolver nil. Ver CLAUDE.md del navegador.
            if let list = try? await store.contentRuleList(forIdentifier: identifier) {
                lists.append(list)
            }
        }
        guard !lists.isEmpty else { return }
        if lists.count < identifiers.count {
            // Falta algún trozo: la próxima pasada lo vuelve a compilar.
            UserDefaults.standard.removeObject(forKey: "browser.blocker.signature")
        }
        compiled = lists
        totalRules = UserDefaults.standard.integer(forKey: "browser.blocker.totalRules")
        isReady = true
        notify()

        let hostsFile = Self.hostsFile
        let hosts = await Task.detached(priority: .utility) {
            (try? String(contentsOf: hostsFile, encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
        }.value
        blockedHosts = Set(hosts)
    }

    /// Las listas que se generaban en el Mac con `Tools/fetch-blocklists.sh`
    /// (hasta el 24-sep-2026) iban en el bundle y se compilaban como
    /// `blocklist-*`. Ocupan sitio en el almacén de WebKit: fuera.
    private func removeLegacyLists() async {
        guard !UserDefaults.standard.bool(forKey: "browser.blocker.legacyRemoved"),
              let store = WKContentRuleListStore.default()
        else { return }
        let identifiers: [String] = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for identifier in identifiers where identifier.hasPrefix("blocklist-") {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
        UserDefaults.standard.removeObject(forKey: "browser.blocker.disabledSources")
        UserDefaults.standard.set(true, forKey: "browser.blocker.legacyRemoved")
    }

    private func prepareDirectory() {
        var directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Se vuelven a bajar solas: no tienen por qué ir en la copia de iCloud.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private func loadInfo() {
        guard let data = try? Data(contentsOf: Self.infoFile),
              let saved = try? JSONDecoder().decode([String: ListInfo].self, from: data)
        else { return }
        info = saved
    }

    private func saveInfo() {
        if let data = try? JSONEncoder().encode(info) {
            try? data.write(to: Self.infoFile, options: .atomic)
        }
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
        for list in compiled {
            controller.add(list)
        }
        if let userList {
            controller.add(userList)
        }
    }
}

import Foundation

/// Traduce listas con la sintaxis de AdBlock y uBlock Origin al JSON de
/// `WKContentRuleList`. Corre en la propia app, lejos del hilo principal.
///
/// **Lo que entra**: bloqueos y excepciones de red (`||dominio^`, comodines,
/// `$domain=`, `$third-party`, tipos de recurso), ficheros *hosts*, y la
/// ocultación de elementos (`##selector`, `dominio##selector`, `#@#`), que es
/// lo que **absorbe los huecos grises** donde iba un anuncio.
///
/// **Lo que no**: expresiones regulares en crudo, scriptlets (`##+js`), los
/// selectores procedurales de uBlock (`:has-text`, `:upward`…), `$redirect`,
/// `$removeparam`, `$csp` y demás opciones que WebKit no sabe expresar. Una
/// regla con algo que no se sabe traducir se descarta entera: traducirla a
/// medias cambiaría lo que hace.
///
/// **Por qué todas las listas van juntas.** En WebKit, `ignore-previous-rules`
/// sólo anula reglas **de su misma lista**: las excepciones de «uBlock ·
/// Arreglos» no servirían de nada contra un bloqueo de EasyList compilado
/// aparte. Así que se juntan, se trocean los bloqueos, y **cada trozo lleva
/// detrás todas las excepciones**.
///
/// El algoritmo se probó primero en Python con las listas reales (24-sep-2026:
/// 116.000 bloqueos y 27.000 selectores de uBlock, EasyList y EasyPrivacy), y
/// los selectores se validaron uno a uno con el analizador de CSS de Chromium.
struct FilterListConverter {

    /// Se sube cuando cambia lo que sale, para que se vuelva a convertir.
    static let version = 1

    struct Output: Sendable {
        /// Cada una, el JSON de una `WKContentRuleList`.
        var networkLists: [String]
        var cosmeticList: String?
        /// Dominios bloqueados enteros (`||dominio^` sin más). Con ellos se
        /// pliegan los iframes de anuncios: ver `BlockerCollapse.js`.
        var blockedHosts: [String]
        var ruleCounts: [String: Int]
    }

    // MARK: - Formato de WebKit

    struct Trigger: Codable, Hashable {
        var urlFilter: String
        var caseSensitive: Bool?
        var resourceType: [String]?
        var loadType: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case caseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
        }
    }

    struct Action: Codable, Hashable {
        var type: String
        var selector: String?
    }

    struct Rule: Codable, Hashable {
        var trigger: Trigger
        var action: Action
    }

    // MARK: - Estado

    private var blocks: [(raw: String, rule: Rule)] = []
    private var allows: [(raw: String, rule: Rule)] = []
    private var badFilters: Set<String> = []
    /// `@@||dominio^$document`: el sitio entero sin filtrar.
    private var documentAllowed: Set<String> = []
    /// `@@||dominio^$elemhide`: sin ocultar nada.
    private var elemhideAllowed: Set<String> = []
    /// `@@||dominio^$generichide`: sin los selectores genéricos.
    private var generichideAllowed: Set<String> = []
    /// Selector genérico → dominios donde **no** se aplica.
    private var generic: [String: Set<String>] = [:]
    /// Selector de sitio → dominios donde sí.
    private var specific: [String: Set<String>] = [:]
    private var hosts: Set<String> = []
    private var unblockedHosts: Set<String> = []
    private var ruleCounts: [String: Int] = [:]
    private var added = 0

    // MARK: - Lectura

    /// Añade una lista. `id` sólo sirve para contar sus reglas.
    mutating func add(_ text: String, list id: String) {
        added = 0
        // Una línea con un dominio suelto es una regla de dominio en una lista
        // de dominios, pero en una de AdBlock es un trozo de dirección
        // cualquiera (`ad.js`): sólo se traduce en las primeras.
        let isDomainList = !text.contains("||") && !text.contains("##")
        var conditions: [Bool] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#if ") {
                conditions.append(Self.condition(String(line.dropFirst(5))))
                continue
            }
            if line.hasPrefix("!#else") {
                if let last = conditions.popLast() { conditions.append(!last) }
                continue
            }
            if line.hasPrefix("!#endif") {
                _ = conditions.popLast()
                continue
            }
            guard !conditions.contains(false) else { continue }
            addLine(line, isDomainList: isDomainList)
        }
        ruleCounts[id] = added
    }

    /// Las directivas `!#if` de uBlock: BrunOS es un Safari, sin filtrado de
    /// HTML ni scriptlets, y no es un móvil (se usa con monitor y ratón).
    static func condition(_ expression: String) -> Bool {
        let trueTokens: Set<String> = ["env_safari", "ext_ublock", "ext_abp", "adguard_ext_safari"]
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "()"))
        for part in expression.components(separatedBy: "||") {
            var holds = true
            for term in part.components(separatedBy: "&&") {
                var token = term.trimmingCharacters(in: trim)
                let negated = token.hasPrefix("!")
                if negated { token = String(token.dropFirst()).trimmingCharacters(in: trim) }
                if trueTokens.contains(token) == negated { holds = false }
            }
            if holds { return true }
        }
        return false
    }

    private mutating func addLine(_ original: String, isDomainList: Bool) {
        guard let first = original.first, first != "!", first != "[" else { return }
        // En los ficheros hosts, `#` es un comentario; en los de AdBlock
        // empieza una regla de ocultación (`##.anuncio`).
        if first == "#", !original.hasPrefix("##"), !original.hasPrefix("#@#") { return }

        var line = original
        if let host = Self.hostsEntry(original) {
            line = "||\(host)^"
        } else if isDomainList, Self.isPlainDomain(original) {
            line = "||\(original.lowercased())^"
        }

        // Las de AdGuard y uBlock que no son CSS (`#?#`, `#$#`, `#%#`) y sus
        // excepciones: fuera.
        for marker in ["#?#", "#$#", "#%#", "#@?#", "#@$#", "#@%#"] where line.contains(marker) {
            return
        }
        if line.contains("##") || line.contains("#@#") {
            addCosmetic(line)
        } else {
            addNetwork(line)
        }
    }

    /// `0.0.0.0 anuncios.ejemplo.com` → `anuncios.ejemplo.com`.
    private static func hostsEntry(_ line: String) -> String? {
        guard line.hasPrefix("0.0.0.0") || line.hasPrefix("127.0.0.1") else { return nil }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else { return nil }
        let host = parts[1].lowercased()
        guard !["localhost", "local", "0.0.0.0", "broadcasthost", "localhost.localdomain"].contains(host),
              isPlainDomain(host)
        else { return nil }
        return host
    }

    private static func isPlainDomain(_ text: String) -> Bool {
        guard text.contains("."), !text.contains(".."),
              let first = text.first, let last = text.last,
              first.isASCII, last.isASCII, first.isLetter || first.isNumber, last.isLetter || last.isNumber
        else { return false }
        return text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        }
    }

    // MARK: - Red

    /// Las opciones de tipo de recurso, con los alias de uBlock.
    private static let types: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
        "font": "font", "media": "media", "popup": "popup",
        "subdocument": "document", "frame": "document", "document": "document", "doc": "document",
        "xmlhttprequest": "fetch", "xhr": "fetch", "websocket": "websocket", "ping": "ping", "beacon": "ping",
    ]
    /// Los que WebKit acepta y aquí se usan. Un valor fuera de su lista
    /// cerrada tumba la lista entera.
    private static let allTypes = [
        "document", "image", "style-sheet", "script", "font", "media", "popup", "ping", "fetch", "websocket",
    ]
    /// Opciones que no cambian qué se bloquea, o que aquí dan igual.
    private static let harmless: Set<String> = ["match-case", "important", "all", "strict1p", "strict3p"]

    private mutating func addNetwork(_ original: String) {
        var line = original
        let isException = line.hasPrefix("@@")
        if isException { line.removeFirst(2) }

        var types: [String] = []
        var excludedTypes: [String] = []
        var included: [String] = []
        var excluded: [String] = []
        var loadType: String?
        var caseSensitive = false
        var hideException: String?

        let isRegex = line.hasPrefix("/") && line.count > 2 && line.hasSuffix("/")
        if !isRegex, let dollar = line.lastIndex(of: "$") {
            let options = line[line.index(after: dollar)...]
            line = String(line[..<dollar])
            for rawOption in options.split(separator: ",") {
                var option = rawOption.trimmingCharacters(in: .whitespaces)
                let negated = option.hasPrefix("~")
                if negated { option.removeFirst() }

                if option.hasPrefix("domain=") || option.hasPrefix("from=") {
                    let value = option[option.index(after: option.firstIndex(of: "=")!)...]
                    guard let domains = Self.domains(String(value), separator: "|") else { return }
                    (included, excluded) = domains
                } else if option == "third-party" || option == "3p" {
                    loadType = negated ? "first-party" : "third-party"
                } else if option == "first-party" || option == "1p" {
                    loadType = negated ? "third-party" : "first-party"
                } else if let type = Self.types[option] {
                    if negated { excludedTypes.append(type) } else { types.append(type) }
                } else if option == "match-case" {
                    caseSensitive = true
                } else if Self.harmless.contains(option) {
                    continue
                } else if ["elemhide", "ehide", "generichide", "ghide"].contains(option) {
                    hideException = option
                } else if ["specifichide", "shide"].contains(option) {
                    return
                } else if option == "badfilter" {
                    badFilters.insert(Self.withoutBadfilter(original))
                    return
                } else {
                    return
                }
            }
        }

        if let hideException {
            guard isException, let host = Self.anchoredHost(line) else { return }
            if hideException.hasPrefix("e") {
                elemhideAllowed.insert("*" + host)
            } else {
                generichideAllowed.insert("*" + host)
            }
            added += 1
            return
        }
        if isException, types == ["document"], included.isEmpty, excluded.isEmpty,
           let host = Self.anchoredHost(line) {
            documentAllowed.insert("*" + host)
            added += 1
            return
        }
        // Expresiones regulares en crudo, también con opciones (`/…/$script`):
        // la sintaxis de WebKit es demasiado limitada para traducirlas.
        let isRegexWithOptions = line.hasPrefix("/") && line.count > 2 && line.hasSuffix("/")
        guard !isRegex, !isRegexWithOptions, line.allSatisfy(\.isASCII) else { return }

        var trigger = Trigger(urlFilter: Self.urlFilter(line))
        if caseSensitive { trigger.caseSensitive = true }
        if types.isEmpty, !excludedTypes.isEmpty {
            types = Self.allTypes.filter { !excludedTypes.contains($0) }
        }
        if !types.isEmpty { trigger.resourceType = Array(Set(types)).sorted() }
        if let loadType { trigger.loadType = [loadType] }
        // **Nunca `if-domain` y `unless-domain` a la vez**: WebKit rechaza la
        // lista entera.
        if !included.isEmpty {
            trigger.ifDomain = included
        } else if !excluded.isEmpty {
            trigger.unlessDomain = excluded
        }

        let rule = Rule(trigger: trigger, action: Action(type: isException ? "ignore-previous-rules" : "block"))
        if isException {
            allows.append((original, rule))
        } else {
            blocks.append((original, rule))
        }
        added += 1

        // Un dominio bloqueado entero, sea cual sea el recurso: sirve para
        // plegar sus iframes.
        if line.hasPrefix("||"), line.hasSuffix("^"), included.isEmpty, excluded.isEmpty,
           types.isEmpty || types.contains("document"),
           let host = Self.anchoredHost(line) {
            if isException {
                unblockedHosts.insert(host)
            } else {
                hosts.insert(host)
            }
        }
    }

    /// `||ejemplo.com^` → `ejemplo.com`; `nil` si lleva ruta o comodines.
    private static func anchoredHost(_ pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var host = String(pattern.dropFirst(2))
        while let last = host.last, last == "^" || last == "|" { host.removeLast() }
        guard isPlainDomain(host) else { return nil }
        return host.lowercased()
    }

    private static func withoutBadfilter(_ line: String) -> String {
        line.replacingOccurrences(of: ",badfilter", with: "")
            .replacingOccurrences(of: "$badfilter,", with: "$")
            .replacingOccurrences(of: "$badfilter", with: "")
    }

    /// El patrón de AdBlock pasado a la expresión regular, muy limitada, de
    /// WebKit: sin alternativas (`|`) ni cuantificadores con llaves.
    static func urlFilter(_ pattern: String) -> String {
        var body = Substring(pattern)
        var head = ""
        var tail = ""
        if body.hasPrefix("||") {
            body = body.dropFirst(2)
            head = "^https?://([^/]+\\.)?"
        } else if body.hasPrefix("|") {
            body = body.dropFirst()
            head = "^"
        }
        if body.hasSuffix("|") {
            body = body.dropLast()
            tail = "$"
        }
        if head.isEmpty {
            while body.hasPrefix("*") { body = body.dropFirst() }
        }
        var escaped = ""
        for character in body {
            switch character {
            case "*": escaped += ".*"
            // El separador de AdBlock: cualquier cosa que no sea parte de un
            // nombre. Sin alternativas en WebKit, el «o el final» se pierde,
            // pero una dirección siempre lleva al menos la `/` de la ruta.
            case "^": escaped += "[/:?=&]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\\", "$":
                escaped += "\\" + String(character)
            default: escaped.append(character)
            }
        }
        let result = head + escaped + tail
        return result.isEmpty ? ".*" : result
    }

    /// `a.com|~b.a.com` → (`*a.com`, `*b.a.com`). `nil` si alguno no se
    /// puede expresar (`google.*` de uBlock, expresiones regulares, no ASCII).
    private static func domains(_ text: String, separator: Character) -> (included: [String], excluded: [String])? {
        var included: [String] = []
        var excluded: [String] = []
        for part in text.split(separator: separator) {
            var domain = part.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() }
            guard !domain.isEmpty, isPlainDomain(domain) else { return nil }
            if negated {
                excluded.append("*" + domain)
            } else {
                included.append("*" + domain)
            }
        }
        return (included, excluded)
    }

    // MARK: - Ocultación

    /// Lo de uBlock y AdGuard que no es CSS. Un selector inválido en un grupo
    /// hace que WebKit se salte el grupo entero, así que se filtra con ganas.
    private static let procedural = [
        ":has-text(", ":upward(", ":xpath(", ":matches-", ":min-text-length(", ":others(", ":remove(",
        ":style(", ":watch-attr(", ":-abp-", ":contains(", ":if(", ":if-not(", ":nth-ancestor(",
        ":remove-attr(", ":remove-class(", ":shadow(", ":spath(", "-ext-",
    ]

    private mutating func addCosmetic(_ line: String) {
        let exceptionRange = line.range(of: "#@#")
        let hideRange = line.range(of: "##")
        let range: Range<String.Index>
        let isException: Bool
        switch (exceptionRange, hideRange) {
        case let (exception?, hide?):
            isException = exception.lowerBound < hide.lowerBound
            range = isException ? exception : hide
        case let (exception?, nil):
            isException = true
            range = exception
        case let (nil, hide?):
            isException = false
            range = hide
        case (nil, nil):
            return
        }

        let domainText = String(line[..<range.lowerBound])
        let selector = String(line[range.upperBound...])
        guard Self.isUsableSelector(selector) else { return }

        var included: [String] = []
        var excluded: [String] = []
        if !domainText.isEmpty {
            guard let domains = Self.domains(domainText, separator: ",") else { return }
            (included, excluded) = domains
        }

        if isException {
            if included.isEmpty {
                generic[selector] = nil
                specific[selector] = nil
            } else {
                generic[selector]?.formUnion(included)
                specific[selector]?.subtract(included)
            }
            return
        }
        if included.isEmpty {
            generic[selector, default: []].formUnion(excluded)
        } else {
            specific[selector, default: []].formUnion(included)
        }
        added += 1
    }

    static func isUsableSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.allSatisfy(\.isASCII),
              !selector.hasPrefix("+js"), !selector.hasPrefix("^"), !selector.hasPrefix(":"),
              !selector.contains("{"), !selector.contains("}")
        else { return false }
        if procedural.contains(where: { selector.contains($0) }) { return false }
        // `:has` dentro de `:has` no es CSS válido; salen unas pocas así.
        return selector.components(separatedBy: ":has(").count <= 2
    }

    // MARK: - Salida

    /// Bloqueos por lista de WebKit: por encima de unas 150.000 se atraganta.
    private static let chunkSize = 50_000
    /// Selectores por regla. Si uno sale inválido, WebKit se salta la regla
    /// entera (no la lista): grupos pequeños para perder poco.
    private static let selectorsPerRule = 100
    private static let domainsPerRule = 500

    func build() throws -> Output {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        let blockRules = Self.unique(blocks.filter { !badFilters.contains($0.raw) }.map(\.rule))
        let allowRules = Self.unique(allows.filter { !badFilters.contains($0.raw) }.map(\.rule))
        let documentRules = Self.ignoring(domains: documentAllowed)

        // Detrás de cada trozo, todas las excepciones: `ignore-previous-rules`
        // sólo anula lo de su propia lista.
        var networkLists: [String] = []
        var start = 0
        while start < blockRules.count {
            let end = min(start + Self.chunkSize, blockRules.count)
            let rules = Array(blockRules[start..<end]) + allowRules + documentRules
            networkLists.append(String(decoding: try encoder.encode(rules), as: UTF8.self))
            start = end
        }

        // La ocultación va en su propia lista, para que una excepción de red
        // sin tipo (`@@||sitio.com^`) no la anule al coincidir con la página.
        // Orden: genéricos, sitios sin genéricos, de sitio, sitios sin nada.
        var cosmetic: [Rule] = []
        let plain = generic.filter { $0.value.isEmpty }.keys.sorted()
        for start in stride(from: 0, to: plain.count, by: Self.selectorsPerRule) {
            let group = plain[start..<min(start + Self.selectorsPerRule, plain.count)]
            cosmetic.append(Self.hide(group.joined(separator: ", ")))
        }
        for (selector, unless) in generic.sorted(by: { $0.key < $1.key }) where !unless.isEmpty {
            var rule = Self.hide(selector)
            rule.trigger.unlessDomain = unless.sorted()
            cosmetic.append(rule)
        }
        cosmetic += Self.ignoring(domains: generichideAllowed)

        var bySites: [[String]: [String]] = [:]
        for (selector, sites) in specific where !sites.isEmpty {
            bySites[sites.sorted(), default: []].append(selector)
        }
        for (sites, selectors) in bySites.sorted(by: { $0.key.joined() < $1.key.joined() }) {
            let sorted = selectors.sorted()
            for start in stride(from: 0, to: sorted.count, by: Self.selectorsPerRule) {
                var rule = Self.hide(sorted[start..<min(start + Self.selectorsPerRule, sorted.count)]
                    .joined(separator: ", "))
                rule.trigger.ifDomain = sites
                cosmetic.append(rule)
            }
        }
        cosmetic += Self.ignoring(domains: elemhideAllowed.union(documentAllowed))

        let cosmeticList = cosmetic.isEmpty ? nil : String(decoding: try encoder.encode(cosmetic), as: UTF8.self)

        return Output(
            networkLists: networkLists,
            cosmeticList: cosmeticList,
            blockedHosts: hosts.subtracting(unblockedHosts).sorted(),
            ruleCounts: ruleCounts
        )
    }

    private static func hide(_ selector: String) -> Rule {
        Rule(trigger: Trigger(urlFilter: ".*"), action: Action(type: "css-display-none", selector: selector))
    }

    /// `ignore-previous-rules` para las páginas de esos dominios, en grupos.
    private static func ignoring(domains: Set<String>) -> [Rule] {
        let sorted = domains.sorted()
        return stride(from: 0, to: sorted.count, by: domainsPerRule).map { start in
            var trigger = Trigger(urlFilter: ".*")
            trigger.ifDomain = Array(sorted[start..<min(start + domainsPerRule, sorted.count)])
            return Rule(trigger: trigger, action: Action(type: "ignore-previous-rules"))
        }
    }

    /// Sin repetidas, conservando el orden.
    private static func unique(_ rules: [Rule]) -> [Rule] {
        var seen: Set<Rule> = []
        return rules.filter { seen.insert($0).inserted }
    }
}

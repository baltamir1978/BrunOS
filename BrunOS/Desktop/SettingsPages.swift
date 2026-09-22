import UIKit

/// Qué ajustes se abren: los globales, desde la rueda del dock, o los de un
/// tipo de panel, desde la rueda de su propia barra.
///
/// **Cada cosa donde se usa.** Lo del navegador en el navegador, lo del
/// terminal en el terminal; la rueda del dock se queda para lo que afecta a
/// todo el escritorio: modo, fondo, pantalla y ratón.
enum SettingsScope {
    case global
    case browser
    case terminal
    case files
}

@MainActor
enum SettingsPages {

    static func window(for scope: SettingsScope) -> (title: String, symbol: String, pages: [SettingsPage]) {
        switch scope {
        case .global: ("Ajustes", "gearshape.fill", [general, display, mouse, about])
        case .browser: ("Navegador", "safari.fill", [browserGeneral, bookmarks, blocking, downloads])
        case .terminal: ("Terminal", "terminal.fill", [machines, sshKey, terminalLook, knownHosts])
        case .files: ("Ficheros", "folder.fill", [filesView, locations])
        }
    }

    private static var services: AppServices { .shared }
    private static var desktop: DesktopViewController? { services.desktopViewController }

    private static let gray = UIColor(hex: 0x8A9099)
    private static let blue = UIColor(hex: 0x3A86E8)
    private static let teal = UIColor(hex: 0x2FA596)
    private static let orange = UIColor(hex: 0xE8913D)
    private static let red = UIColor(hex: 0xE0574B)
    private static let purple = UIColor(hex: 0x8E63D2)
    private static let green = UIColor(hex: 0x4FA85C)

    // MARK: - Globales

    private static var general: SettingsPage {
        SettingsPage(title: "General", symbol: "switch.2", tint: gray) {
            let appearances = DesktopAppearance.allCases
            return [
                SettingsGroup(
                    "Apariencia",
                    footer: "«Como el iPhone» cambia el escritorio en cuanto cambia el modo del teléfono, "
                        + "también si lo tienes en automático.",
                    rows: [
                        SettingsRow("Modo", .choice(
                            ["Como el iPhone", "Claro", "Oscuro"],
                            selected: appearances.firstIndex(of: DesktopTheme.appearance) ?? 0
                        ) { DesktopTheme.appearance = appearances[$0] }),
                    ]
                ),
                SettingsGroup(
                    "Ventanas",
                    footer: "Cualquier panel se suelta del mosaico arrastrándolo por la parte vacía de "
                        + "su barra, y se redimensiona por los bordes. Doble clic en la barra, o "
                        + "Cmd + Mayús + Espacio, lo pasa de flotante a mosaico y al revés. "
                        + "Rojo cierra, amarillo lo manda al dock y verde maximiza.",
                    rows: [
                        SettingsRow("Paneles nuevos", .choice(
                            ["En mosaico", "Flotantes"],
                            selected: DesktopPreferences.newPanesFloat ? 1 : 0
                        ) { DesktopPreferences.newPanesFloat = $0 == 1 }),
                    ]
                ),
                SettingsGroup(
                    "Fondo de escritorio",
                    footer: "Los degradados tienen versión clara y oscura, y cambian con el modo. "
                        + "Las fotos son los fondos de macOS que copia Tools/fetch-wallpapers.sh; "
                        + "iOS no deja leer el fondo del iPhone.",
                    rows: [SettingsRow("Fondo", .wallpapers)]
                ),
            ]
        }
    }

    private static var display: SettingsPage {
        SettingsPage(title: "Pantalla", symbol: "display", tint: blue) {
            guard let profile = services.externalDisplay.currentProfile else {
                return [SettingsGroup(rows: [SettingsRow("Sin pantalla externa conectada")])]
            }
            let scales = DisplayProfile.Scale.allCases
            let overscans = DisplayProfile.Overscan.allCases
            return [
                SettingsGroup(
                    footer: "La escala decide cuánto cabe: a 1× todo va a píxel nativo y se ve pequeño; "
                        + "a 2× se ve como una pantalla Retina. Se guarda por monitor, así que cada "
                        + "pantalla recuerda la suya.",
                    rows: [
                        SettingsRow("Resolución", .value(profile.summary)),
                        SettingsRow("Escala", .choice(
                            scales.map(\.label),
                            selected: scales.firstIndex(of: profile.scale) ?? 0
                        ) { services.externalDisplay.setScale(scales[$0]) }),
                        SettingsRow("Overscan", subtitle: "Para televisores que recortan los bordes", .choice(
                            overscans.map(\.label),
                            selected: overscans.firstIndex(of: profile.overscan) ?? 0
                        ) { services.externalDisplay.setOverscan(overscans[$0]) }),
                    ]
                ),
                SettingsGroup(
                    footer: "A pantalla completa se esconden el dock y la barra superior. El dock vuelve "
                        + "a salir al llevar el cursor al borde de abajo.",
                    rows: [
                        SettingsRow("Pantalla completa", subtitle: "Ctrl + Cmd + F",
                                    .toggle(services.desktop.isFullScreen) { _ in
                                        desktop?.perform(.toggleFullScreen)
                                    }),
                    ]
                ),
            ]
        }
    }

    private static var mouse: SettingsPage {
        SettingsPage(title: "Ratón y teclado", symbol: "computermouse.fill", tint: teal) {
            let pointer = services.pointer.settings
            let steps: [Double] = [0.6, 0.8, 1.0, 1.3, 1.6, 2.0, 2.5]
            let current = steps.enumerated().min { abs($0.element - pointer.sensitivity) < abs($1.element - pointer.sensitivity) }?.offset ?? 2

            return [
                SettingsGroup(
                    "Rueda",
                    footer: "Natural es la de Apple: el contenido sigue al dedo, y al girar la rueda "
                        + "hacia ti la página sube. Inversa es la de Windows y la de siempre: la "
                        + "página baja.",
                    rows: [
                        SettingsRow("Dirección del scroll", .choice(
                            ["Natural", "Inversa"],
                            selected: pointer.naturalScrolling ? 0 : 1
                        ) { index in update { $0.naturalScrolling = index == 0 } }),
                    ]
                ),
                SettingsGroup(
                    "Ratón",
                    footer: "Con AssistiveTouch, el cursor del monitor sigue la posición del puntero "
                        + "en el iPhone: el borde del teléfono es el borde del monitor, y no se "
                        + "atasca. La velocidad se ajusta en iOS: Accesibilidad › Control del puntero "
                        + "› Velocidad de seguimiento. La sensibilidad y la aceleración de aquí valen "
                        + "para el trackpad del iPhone y para GCMouse.",
                    rows: [
                        SettingsRow("Fuente activa", .value(services.mouse.activeSourceName)),
                        SettingsRow("Sensibilidad", .choice(
                            steps.map { String(format: "%.1f×", $0).replacingOccurrences(of: ".", with: ",") },
                            selected: current
                        ) { index in update { $0.sensitivity = steps[index] } }),
                        SettingsRow("Aceleración", subtitle: "Lento para apuntar fino, rápido para cruzar",
                                    .toggle(pointer.acceleration) { value in update { $0.acceleration = value } }),
                    ]
                ),
                SettingsGroup("Atajos", rows: [
                    SettingsRow("Cambiar de espacio", .value("Cmd + 1 · 2 · 3")),
                    SettingsRow("Mover el foco", .value("Cmd + Opción + flechas")),
                    SettingsRow("Mover el panel", .value("Cmd + Mayús + flechas")),
                    SettingsRow("Maximizar el panel", .value("Cmd + Intro")),
                    SettingsRow("Flotar o volver al mosaico", .value("Cmd + Mayús + Espacio")),
                    SettingsRow("Pantalla completa", .value("Ctrl + Cmd + F")),
                    SettingsRow("Nueva pestaña · cerrarla", .value("Cmd + T · Cmd + W")),
                    SettingsRow("Nuevo panel", .value("Cmd + N")),
                    SettingsRow("Lanzador", .value("Cmd + P")),
                ]),
            ]
        }
    }

    private static func update(_ change: (inout PointerSettings) -> Void) {
        var settings = services.pointer.settings
        change(&settings)
        services.pointer.settings = settings
        settings.save()
    }

    private static var about: SettingsPage {
        SettingsPage(title: "Acerca de", symbol: "info.circle.fill", tint: gray) {
            let assistive = services.assistiveTouch
            return [
                SettingsGroup(rows: [
                    SettingsRow("BrunOS", .value(AppInfo.version)),
                    SettingsRow("AssistiveTouch", .value(assistive.statusLabel)),
                    SettingsRow("Ratón", .value(assistive.mouseDetected ? "conectado" : "no detectado")),
                ]),
                SettingsGroup(
                    footer: "Los ajustes de cada panel están en la rueda de su propia barra: "
                        + "navegador, terminal y ficheros.",
                    rows: []
                ),
            ]
        }
    }

    // MARK: - Navegador

    private static var browserGeneral: SettingsPage {
        SettingsPage(title: "General", symbol: "safari", tint: blue) {
            let engines = SearchEngine.allCases
            let zooms: [CGFloat] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5]
            let zoomIndex = zooms.enumerated()
                .min { abs($0.element - BrowserZoom.default) < abs($1.element - BrowserZoom.default) }?.offset ?? 2
            return [
                SettingsGroup(
                    footer: "Lo que se escribe en la barra y no parece una dirección se busca aquí.",
                    rows: [
                        SettingsRow("Buscador", .choice(
                            engines.map(\.label),
                            selected: engines.firstIndex(of: SearchEngine.current) ?? 0
                        ) { SearchEngine.current = engines[$0] }),
                    ]
                ),
                SettingsGroup(
                    footer: "Cmd + y Cmd − cambian el zoom de la pestaña; Cmd 0 vuelve a éste.",
                    rows: [
                        SettingsRow("Zoom de las páginas", .choice(
                            zooms.map { "\(Int(($0 * 100).rounded())) %" },
                            selected: zoomIndex
                        ) { index in
                            BrowserZoom.remember(zooms[index])
                            NotificationCenter.default.post(name: .brunosBrowserZoomChanged, object: nil)
                        }),
                    ]
                ),
            ]
        }
    }

    private static var bookmarks: SettingsPage {
        SettingsPage(title: "Favoritos", symbol: "star.fill", tint: orange) {
            let history = services.history
            var groups: [SettingsGroup] = [
                SettingsGroup(
                    footer: "La barra va debajo de la de direcciones y se come 28 puntos de página. "
                        + "Se añade la página que se esté viendo con Cmd+D o con la estrella de la "
                        + "barra del panel, y los que no caben salen en el menú » del final.",
                    rows: [
                        SettingsRow("Enseñar la barra de favoritos",
                                    .toggle(BookmarksBar.isVisible) { BookmarksBar.isVisible = $0 }),
                    ]
                ),
            ]

            let pages = history.bookmarks
            groups.append(SettingsGroup(
                "Favoritos",
                footer: pages.isEmpty
                    ? nil
                    : "El nombre es tuyo, no el de la web: el título de muchas páginas es una frase "
                        + "entera y en la barra no cabe. Las flechas los ordenan.",
                rows: pages.isEmpty
                    ? [SettingsRow("Todavía no hay ninguno")]
                    : pages.map { page in
                        SettingsRow(
                            page.title,
                            subtitle: URL(string: page.url)?.host() ?? page.url,
                            symbol: "star.fill",
                            .buttons([
                                SettingsButton("←") { history.moveBookmark(page, by: -1) },
                                SettingsButton("→") { history.moveBookmark(page, by: 1) },
                                SettingsButton("Renombrar…") {
                                    desktop?.presentPrompt(title: "Nombre del favorito", value: page.title) { text in
                                        guard let text else { return }
                                        history.renameBookmark(page, to: text)
                                    }
                                },
                                SettingsButton("Quitar", style: .destructive) { history.removeBookmark(page) },
                            ])
                        )
                    }
            ))

            groups.append(SettingsGroup(
                "Historial",
                footer: "Se guarda una entrada por dirección, como mucho 500, y no sale del iPhone. "
                    + "Sirve para el lanzador (Cmd+P).",
                rows: [
                    SettingsRow(
                        "Páginas recordadas",
                        subtitle: "\(history.visits.count)",
                        .buttons([
                            SettingsButton("Borrar", style: .destructive) { history.clearHistory() },
                        ])
                    ),
                ]
            ))
            return groups
        }
    }

    private static var blocking: SettingsPage {
        SettingsPage(title: "Bloqueo de anuncios", symbol: "shield.fill", tint: red) {
            let blocker = services.blocker
            var groups: [SettingsGroup] = []

            groups.append(SettingsGroup(
                footer: blocker.lastError,
                rows: [
                    SettingsRow("Bloquear anuncios y rastreadores",
                                .toggle(blocker.isEnabled) { blocker.isEnabled = $0 }),
                ]
            ))

            groups.append(SettingsGroup(
                "Listas",
                footer: "Se descargan y convierten con Tools/fetch-blocklists.sh. WebKit no dice "
                    + "cuántas peticiones detiene, así que BrunOS no se inventa un contador.",
                rows: blocker.sources.isEmpty
                    ? [SettingsRow("No hay listas cargadas")]
                    : blocker.sources.map { source in
                        SettingsRow(
                            source.label,
                            subtitle: "\(source.ruleCount.formatted()) reglas",
                            .toggle(blocker.isSourceEnabled(source)) { blocker.setSource(source, enabled: $0) }
                        )
                    }
            ))

            var domainRows = blocker.blockedDomains.map { domain in
                SettingsRow(domain, symbol: "nosign", .buttons([
                    SettingsButton("Quitar", style: .destructive) { blocker.removeBlockedDomain(domain) },
                ]))
            }
            domainRows.append(SettingsRow("Bloquear otro dominio", .buttons([
                SettingsButton("Añadir…") {
                    desktop?.presentPrompt(title: "Dominio que bloquear", value: "") { text in
                        guard let text else { return }
                        blocker.addBlockedDomain(text)
                    }
                },
            ])))
            groups.append(SettingsGroup(
                "Dominios bloqueados",
                footer: "Se bloquea el dominio y todos sus subdominios, en cualquier web.",
                rows: domainRows
            ))

            var siteRows = blocker.exceptions.sorted().map { host in
                SettingsRow(host, symbol: "checkmark.shield", .buttons([
                    SettingsButton("Quitar") { blocker.toggleException(for: host) },
                ]))
            }
            siteRows.append(SettingsRow("Permitir otro sitio", .buttons([
                SettingsButton("Añadir…") {
                    desktop?.presentPrompt(title: "Sitio sin bloqueo", value: "") { text in
                        guard let text, !text.isEmpty else { return }
                        blocker.toggleException(for: text)
                    }
                },
            ])))
            groups.append(SettingsGroup(
                "Sitios sin bloqueo",
                footer: "Para las webs que se rompen con el bloqueador. También se cambia desde el "
                    + "escudo de la barra del navegador o con el clic derecho.",
                rows: siteRows
            ))

            var hideRows = blocker.hideRules.map { rule in
                SettingsRow(rule.selector, subtitle: rule.domain ?? "todas las webs", symbol: "eye.slash",
                            .buttons([
                                SettingsButton("Quitar", style: .destructive) { blocker.removeHideRule(rule) },
                            ]))
            }
            hideRows.append(SettingsRow("Ocultar un elemento", .buttons([
                SettingsButton("Añadir…") {
                    desktop?.presentPrompt(title: "Regla (dominio##selector)", value: "") { text in
                        guard let text, let rule = ContentBlocker.HideRule.parse(text) else { return }
                        blocker.addHideRule(rule)
                    }
                },
            ])))
            groups.append(SettingsGroup(
                "Elementos ocultos",
                footer: "Con la sintaxis de AdBlock: «ejemplo.com##.banner» oculta lo que tenga la "
                    + "clase banner sólo en ejemplo.com; «##.banner» lo oculta en todas.",
                rows: hideRows
            ))
            return groups
        }
    }

    private static var downloads: SettingsPage {
        SettingsPage(title: "Descargas", symbol: "arrow.down.circle.fill", tint: green) {
            let directory = BrowserTab.downloadsDirectory
            let files = ((try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { modified($0) > modified($1) }
                .prefix(10)

            var rows = [SettingsRow("Carpeta", subtitle: "iPhone › Descargas", .buttons([
                SettingsButton("Abrir en Ficheros") { desktop?.revealInFiles(directory) },
            ]))]
            rows += files.map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return SettingsRow(
                    url.lastPathComponent,
                    subtitle: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                    symbol: "doc",
                    .buttons([SettingsButton("Mostrar") { desktop?.revealInFiles(url) }])
                )
            }
            return [SettingsGroup(
                footer: "Lo descargado también se ve desde la app Archivos del iPhone, en "
                    + "En mi iPhone › BrunOS.",
                rows: rows
            )]
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    // MARK: - Terminal

    private static var machines: SettingsPage {
        SettingsPage(title: "Máquinas", symbol: "server.rack", tint: purple) {
            var rows = services.hosts.hosts.map { host in
                SettingsRow(
                    host.displayName,
                    subtitle: "\(host.username)@\(host.host):\(host.port) · \(host.authentication.label)",
                    symbol: "desktopcomputer",
                    .buttons([
                        SettingsButton("Editar") { desktop?.presentHostEditor(for: host) },
                        SettingsButton("Conectar", style: .accent) {
                            desktop?.dismissSettings()
                            desktop?.connectTerminal(to: host)
                        },
                    ])
                )
            }
            rows.append(SettingsRow("Nueva máquina", .buttons([
                SettingsButton("Añadir…") { desktop?.presentHostEditor(for: nil) },
            ])))

            let tailscale = services.tailscale.isLikelyUp
            return [
                SettingsGroup(
                    footer: "Las máquinas salen también en Ficheros, para entrar por SFTP. Las "
                        + "contraseñas van al llavero del iPhone, nunca a iCloud.",
                    rows: rows
                ),
                SettingsGroup(
                    "Tailscale",
                    footer: "Con el método Tailscale se entra sin contraseña a las máquinas del tailnet. "
                        + "Es una deducción por las interfaces de red: puede fallar, y nunca impide "
                        + "conectar.",
                    rows: [SettingsRow("Estado", .value(tailscale ? "parece activo" : "no detectado"))]
                ),
            ]
        }
    }

    private static var sshKey: SettingsPage {
        SettingsPage(title: "Clave SSH", symbol: "key.horizontal.fill", tint: green) {
            guard let line = SSHKeyStore.publicKeyLine, let fingerprint = SSHKeyStore.fingerprint else {
                return [SettingsGroup(
                    footer: "Una clave ed25519, como la de ssh-keygen: se genera aquí y se guarda en el "
                        + "llavero del iPhone, sin pasar por iCloud. También puedes importar la tuya: "
                        + "copia el contenido de ~/.ssh/id_ed25519 al portapapeles del iPhone y pulsa "
                        + "Importar.",
                    rows: [
                        SettingsRow("Todavía no hay clave", .buttons([
                            SettingsButton("Importar…") { importKey() },
                            SettingsButton("Generar", style: .accent) { SSHKeyStore.generate() },
                        ])),
                    ]
                )]
            }
            let short = line.count > 46 ? String(line.prefix(26)) + "…" + String(line.suffix(18)) : line
            return [
                SettingsGroup(
                    footer: "Pega la clave pública en ~/.ssh/authorized_keys de cada máquina y elige "
                        + "«Clave ed25519» como método al darla de alta. Hay una sola para todas, como "
                        + "en un Mac. La privada no sale nunca del llavero.",
                    rows: [
                        SettingsRow("Clave pública", subtitle: short, symbol: "key", .buttons([
                            SettingsButton("Copiar", style: .accent) { UIPasteboard.general.string = line },
                        ])),
                        SettingsRow("Huella", .value(fingerprint)),
                    ]
                ),
                SettingsGroup(
                    footer: "Cambiarla deja fuera a las máquinas que tenían la anterior hasta que se les "
                        + "ponga la nueva.",
                    rows: [
                        SettingsRow("Cambiar la clave", .buttons([
                            SettingsButton("Importar…") { importKey() },
                            SettingsButton("Generar otra", style: .destructive) {
                                desktop?.presentConfirm(
                                    title: "¿Generar una clave nueva?",
                                    message: "Las máquinas que tienen la actual dejarán de aceptarla.",
                                    destructive: "Generar"
                                ) { confirmed in
                                    if confirmed { SSHKeyStore.generate() }
                                }
                            },
                        ])),
                    ]
                ),
            ]
        }
    }

    /// Importa la clave del portapapeles del iPhone. Si está cifrada, pide la
    /// frase de paso.
    private static func importKey() {
        guard let text = UIPasteboard.general.string, text.contains("OPENSSH PRIVATE KEY") else {
            desktop?.presentConfirm(
                title: "No hay clave en el portapapeles",
                message: "Copia al portapapeles del iPhone el contenido de ~/.ssh/id_ed25519 y vuelve a pulsar Importar.",
                destructive: "Entendido"
            ) { _ in }
            return
        }
        do {
            try SSHKeyStore.importOpenSSH(text, passphrase: nil)
        } catch {
            desktop?.presentPrompt(title: "Frase de paso de la clave", value: "") { passphrase in
                guard let passphrase else { return }
                do {
                    try SSHKeyStore.importOpenSSH(text, passphrase: passphrase)
                } catch {
                    desktop?.presentConfirm(
                        title: "No se pudo importar",
                        message: error.localizedDescription,
                        destructive: "Entendido"
                    ) { _ in }
                }
            }
        }
    }

    private static var terminalLook: SettingsPage {
        SettingsPage(title: "Apariencia", symbol: "paintbrush.fill", tint: orange) {
            let appearances = DesktopAppearance.allCases
            let sizes: [CGFloat] = [11, 12, 13, 14, 15, 16, 18]
            return [
                SettingsGroup(
                    footer: "Por defecto sigue al escritorio, como Terminal en macOS.",
                    rows: [
                        SettingsRow("Modo", .choice(
                            appearances.map { TerminalTheme.label(for: $0).capitalizedFirst },
                            selected: appearances.firstIndex(of: TerminalTheme.appearance) ?? 0
                        ) { TerminalTheme.appearance = appearances[$0] }),
                        SettingsRow("Tamaño de letra", .choice(
                            sizes.map { "\(Int($0))" },
                            selected: sizes.firstIndex(of: TerminalTheme.fontSize) ?? 2
                        ) { TerminalTheme.fontSize = sizes[$0] }),
                    ]
                ),
            ]
        }
    }

    private static var knownHosts: SettingsPage {
        SettingsPage(title: "Claves conocidas", symbol: "key.fill", tint: gray) {
            let store = services.knownHosts
            var groups: [SettingsGroup] = []

            if !store.pendingChanges.isEmpty {
                groups.append(SettingsGroup(
                    "Claves que han cambiado",
                    footer: "Una máquina ha presentado una clave distinta de la guardada y se cortó la "
                        + "conexión. Si la has reinstalado, confía en la nueva; si no, puede haber "
                        + "alguien en medio: compárala con ssh-keyscan antes.",
                    rows: store.pendingChanges.sorted { $0.key < $1.key }.map { id, fingerprint in
                        SettingsRow(id, subtitle: "SHA256:\(fingerprint)", symbol: "exclamationmark.triangle",
                                    .buttons([
                                        SettingsButton("Confiar en la nueva", style: .destructive) {
                                            let (host, port) = splitHostPort(id)
                                            store.trust(fingerprint: fingerprint, host: host, port: port)
                                        },
                                    ]))
                    }
                ))
            }

            groups.append(SettingsGroup(
                footer: "La primera vez que se conecta a una máquina se guarda su huella, y a partir "
                    + "de ahí tiene que coincidir. Olvidarla hace que la próxima conexión la acepte "
                    + "de nuevo sin preguntar.",
                rows: store.entries.isEmpty
                    ? [SettingsRow("Todavía no hay ninguna")]
                    : store.entries.map { entry in
                        SettingsRow(entry.id, subtitle: entry.displayFingerprint, .buttons([
                            SettingsButton("Olvidar", style: .destructive) { store.forget(entry) },
                        ]))
                    }
            ))
            return groups
        }
    }

    private static func splitHostPort(_ id: String) -> (String, Int) {
        guard let colon = id.lastIndex(of: ":"), let port = Int(id[id.index(after: colon)...]) else {
            return (id, 22)
        }
        return (String(id[..<colon]), port)
    }

    // MARK: - Ficheros

    private static var filesView: SettingsPage {
        SettingsPage(title: "Vista", symbol: "square.grid.2x2.fill", tint: blue) {
            let modes = FilesPane.ViewMode.allCases
            return [SettingsGroup(
                footer: "También se cambia con los botones de la cabecera del panel y con el clic "
                    + "derecho. En iconos, las flechas se mueven por la rejilla.",
                rows: [
                    SettingsRow("Ver como", .choice(
                        modes.map(\.label),
                        selected: modes.firstIndex(of: FilesPane.ViewMode.current) ?? 0
                    ) { index in
                        FilesPane.ViewMode.current = modes[index]
                        NotificationCenter.default.post(name: FilesPane.viewModeDidChange, object: nil)
                    }),
                ]
            )]
        }
    }

    private static var locations: SettingsPage {
        SettingsPage(title: "Ubicaciones", symbol: "externaldrive.fill", tint: teal) {
            let files = services.files
            var rows: [SettingsRow] = []
            for provider in files.providers {
                switch provider {
                case is LocalProvider:
                    rows.append(SettingsRow(provider.name, subtitle: "La carpeta de BrunOS, con Descargas",
                                            symbol: provider.symbol))
                case let external as ExternalFolderProvider:
                    let folder = external.folder
                    let subtitle = external.isAvailable
                        ? folder.kind.label
                        : "No disponible · \(folder.kind.unavailableHint)"
                    rows.append(SettingsRow(provider.name, subtitle: subtitle, symbol: provider.symbol,
                                            .buttons([
                                                SettingsButton("Renombrar…") {
                                                    desktop?.presentPrompt(
                                                        title: "Nombre de la ubicación",
                                                        value: folder.name
                                                    ) { text in
                                                        guard let text else { return }
                                                        files.externalFolders.rename(id: folder.id, to: text)
                                                        files.rebuild()
                                                    }
                                                },
                                                SettingsButton("Quitar", style: .destructive) {
                                                    files.externalFolders.remove(id: folder.id)
                                                    files.rebuild()
                                                },
                                            ])))
                default:
                    rows.append(SettingsRow(provider.name, subtitle: "SFTP · se gestiona en Terminal › Máquinas",
                                            symbol: provider.symbol))
                }
            }
            rows.append(SettingsRow("Otra carpeta", subtitle: "iCloud Drive, En mi iPhone, un USB…", .buttons([
                SettingsButton("Añadir…") {
                    NotificationCenter.default.post(name: .brunosPickFolder, object: nil)
                },
            ])))

            return [
                SettingsGroup(
                    "Ubicaciones",
                    footer: "iOS no deja a ninguna app recorrer el iPhone entero: cada carpeta de fuera "
                        + "de BrunOS hay que abrirla una vez con el selector del sistema, y a partir de "
                        + "ahí queda a mano. Vale cualquier carpeta que se vea en la app Archivos, "
                        + "incluidas las de otras apps, los discos USB y los servidores de red. El "
                        + "selector sale en la pantalla del iPhone, que es la única donde iOS lo deja "
                        + "aparecer.",
                    rows: rows
                ),
                SettingsGroup(
                    "Servidores de red (SMB)",
                    footer: "El SDK de iOS no trae cliente SMB, así que quien se conecta es la app "
                        + "Archivos del iPhone y BrunOS entra por la puerta que deja abierta. Se hace "
                        + "una sola vez:\n"
                        + "1. Abre Archivos › Examinar › ⋯ › Conectar a servidor.\n"
                        + "2. Escribe smb://dirección, con usuario y contraseña; iOS las guarda.\n"
                        + "3. Vuelve aquí, pulsa Añadir… y elige el servidor dentro del selector.\n"
                        + "A partir de ahí es una ubicación más: se copia y se pega con cualquier otra. "
                        + "Si el servidor no está montado, la ubicación sigue en la lista en gris, y "
                        + "vuelve sola en cuanto Archivos se reconecta.",
                    rows: [
                        SettingsRow("Conectar un servidor", subtitle: "Se hace en la app Archivos", .buttons([
                            SettingsButton("Abrir Archivos") { openFilesApp() },
                            SettingsButton("Añadir…", style: .accent) {
                                NotificationCenter.default.post(name: .brunosPickFolder, object: nil)
                            },
                        ])),
                    ]
                ),
            ]
        }
    }

    /// Abre la app Archivos del iPhone, que es la que sabe conectarse a un SMB.
    ///
    /// **Sin `canOpenURL`**: quedó obsoleto exactamente en iOS 27. Se abre y se
    /// mira el resultado, que es lo que Apple pide ahora.
    private static func openFilesApp() {
        guard let url = URL(string: "shareddocuments://") else { return }
        UIApplication.shared.open(url) { opened in
            guard !opened else { return }
            Log.desktop.error("No se pudo abrir la app Archivos")
        }
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

extension String {
    /// «como el iPhone» → «Como el iPhone».
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}

import UIKit
import WebKit

/// Panel de navegador: pestañas, barra de direcciones y la página.
///
/// **Nada de esto recibe eventos del sistema.** Como el resto de la pantalla
/// externa, los clics llegan del escritorio y se resuelven por geometría, y el
/// ratón sobre la página se sintetiza con JavaScript (ver `ClickInjector.js`).
@MainActor
final class BrowserPane: UIView, Pane {

    /// Cuántas pestañas se mantienen cargadas a la vez, **entre todos los
    /// navegadores**.
    ///
    /// Cada `WKWebView` vivo es un proceso de WebKit con su memoria. Pasado un
    /// punto, iOS mata la app entera sin avisar. Las que llevan más tiempo sin
    /// usarse se descargan guardando URL y scroll, y vuelven al mirarlas.
    ///
    /// Antes eran 8 **por ventana**: con tres navegadores, hasta 24. Y desde
    /// que la página se dibuja a píxel nativo (`BrowserTab.place`), a 1,5×
    /// cada una gasta más memoria gráfica.
    private static let maxLiveTabs = 5
    /// Una pestaña que no se ve se duerme pasado este rato, aunque no se haya
    /// llegado al tope.
    private static let idleLimit: TimeInterval = 10 * 60

    /// Todos los navegadores abiertos, para repartir el tope entre ellos.
    private static let all = NSHashTable<BrowserPane>.weakObjects()
    private static var idleTimer: Timer?

    private let chrome = BrowserChrome()
    private let bookmarksBar = BookmarksBar()
    private let content = UIView()

    /// Los medios de la página, para el botón de descargar vídeo.
    ///
    /// Se vuelven a pedir al cargar **y cuando la página avisa** de que ha
    /// aparecido o arrancado un vídeo (`brunosMedia`): casi ningún reproductor
    /// tiene el `<video>` puesto cuando la página termina. Antes se preguntaba
    /// cada 3 segundos en todos los navegadores, se vieran o no.
    private var media: [BrowserTab.Media] = []

    /// Las últimas pestañas cerradas, para Cmd+Mayús+T. Sólo la dirección: no
    /// tiene sentido mantener vivo un `WKWebView` por si acaso.
    private var closedTabs: [String] = []

    private var tabs: [BrowserTab] = []
    private var activeIndex = 0
    private var isEditingAddress = false
    private var addressDraft = ""
    /// Todo el texto de la barra está seleccionado y la próxima tecla lo
    /// sustituye.
    private var isAddressSelected = false

    /// La lista que cae de la barra de direcciones al escribir.
    private let suggestions = AddressSuggestions()

    /// Cmd+F.
    private let findBar = FindBar()
    private var isFinding = false

    /// El aviso de descarga, abajo del panel.
    private let downloadToast = UILabel()
    private var downloadToastTimer: Timer?
    /// Lo último que se descargó, para abrirlo al pulsar el aviso.
    private var lastDownload: URL?

    var title: String { activeTab?.title ?? "Navegador" }
    var view: UIView { self }

    /// Abre una dirección en la pestaña que se está viendo.
    func openInCurrentTab(_ url: URL) {
        guard let activeTab else {
            newTab(url: url.absoluteString)
            return
        }
        activeTab.load(url.absoluteString)
    }

    private var activeTab: BrowserTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        Self.all.add(self)
        if Self.idleTimer == nil {
            Self.idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated { BrowserPane.reclaimMemory() }
            }
        }

        backgroundColor = .white
        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = Tokens.Metric.focusBorderWidth
        layer.borderColor = Tokens.Color.border.desktopCGColor
        clipsToBounds = true

        addSubview(content)
        addSubview(chrome)
        addSubview(bookmarksBar)
        addSubview(findBar)
        // Encima de la página: se añade después que `content`, que es lo que
        // decide quién tapa a quién.
        addSubview(suggestions)
        suggestions.isHidden = true
        findBar.isHidden = true
        findBar.placeholder = "Buscar en la página"
        findBar.onChange = { [weak self] text in self?.find(text, backwards: false) }
        findBar.onNext = { [weak self] in self.map { $0.find($0.findBar.query, backwards: false) } }
        findBar.onPrevious = { [weak self] in self.map { $0.find($0.findBar.query, backwards: true) } }
        findBar.onClose = { [weak self] in self?.hideFind() }

        downloadToast.font = Tokens.sans(12, weight: .medium)
        downloadToast.textColor = Tokens.Color.text
        downloadToast.backgroundColor = Tokens.Color.panelElevated
        downloadToast.textAlignment = .center
        downloadToast.layer.cornerRadius = 9
        downloadToast.layer.masksToBounds = true
        downloadToast.alpha = 0
        addSubview(downloadToast)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(blockerChanged),
            name: ContentBlocker.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(zoomChanged),
            name: .brunosBrowserZoomChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bookmarksChanged),
            name: BrowserHistory.bookmarksDidChange,
            object: nil
        )
        // Un icono que acaba de llegar de la red: la barra lo dibuja en cuanto
        // se repinta, pero nadie le ha dicho que se repinte.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(faviconsChanged),
            name: FaviconStore.didChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(downloadsChanged),
            name: DownloadCenter.didChange,
            object: nil
        )

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()
        chrome.frame = CGRect(x: 0, y: 0, width: bounds.width, height: BrowserChrome.height)

        let showBookmarks = BookmarksBar.isVisible
        bookmarksBar.isHidden = !showBookmarks
        bookmarksBar.frame = CGRect(
            x: 0, y: chrome.frame.maxY,
            width: bounds.width, height: showBookmarks ? BookmarksBar.height : 0
        )

        let findY = showBookmarks ? bookmarksBar.frame.maxY : chrome.frame.maxY
        let findHeight = isFinding ? FindBar.height : 0
        findBar.isHidden = !isFinding
        findBar.frame = CGRect(x: 0, y: findY, width: bounds.width, height: FindBar.height)
        let top = findY + findHeight
        content.frame = CGRect(
            x: 0,
            y: top,
            width: bounds.width,
            height: max(0, bounds.height - top)
        )
        let factor = AppServices.shared.desktopViewController?.canvasFactor ?? 1
        for tab in tabs {
            tab.place(in: content.bounds, factor: factor)
        }
        suggestions.frame = bounds
        layoutDownloadToast()
        refreshChrome()
    }

    // MARK: - Descargas

    private func showDownload(_ name: String, _ state: BrowserTab.DownloadState) {
        switch state {
        case .started:
            downloadToast.text = "Descargando \(name)…"
        case .progress(let fraction, let done, let total):
            let percent = Int((fraction * 100).rounded())
            let sizes = total > 0
                ? " · \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) de "
                    + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                : ""
            downloadToast.text = "Descargando \(name) · \(percent) %\(sizes)"
        case .finished(let url):
            lastDownload = url
            downloadToast.text = "\(name) en Descargas · pulsa para verlo"
        case .failed:
            downloadToast.text = "La descarga falló: \(name)"
        }
        layoutDownloadToast()
        UIView.animate(withDuration: 0.2) { self.downloadToast.alpha = 1 }

        downloadToastTimer?.invalidate()
        if case .progress = state { return }
        guard case .started = state else {
            downloadToastTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    UIView.animate(withDuration: 0.3) { self?.downloadToast.alpha = 0 }
                }
            }
            return
        }
    }

    /// Un aviso corto abajo del panel, que se va solo. El mismo sitio que las
    /// descargas: si no, cada mensaje aparecería en una esquina distinta.
    private func toast(_ text: String) {
        downloadToast.text = text
        lastDownload = nil
        layoutDownloadToast()
        UIView.animate(withDuration: 0.2) { self.downloadToast.alpha = 1 }
        downloadToastTimer?.invalidate()
        downloadToastTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                UIView.animate(withDuration: 0.3) { self?.downloadToast.alpha = 0 }
            }
        }
    }

    private func layoutDownloadToast() {
        let size = downloadToast.intrinsicContentSize
        let width = min(bounds.width - 40, size.width + 28)
        downloadToast.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: bounds.height - 46,
            width: width,
            height: 28
        )
    }

    /// Abre las descargas en el gestor de ficheros.
    private func revealDownloads() {
        downloadToast.alpha = 0
        AppServices.shared.desktopViewController?.revealInFiles(
            lastDownload ?? BrowserTab.downloadsDirectory
        )
    }

    private func refreshChrome() {
        let url = activeTab?.webView.url
        chrome.update(
            tabs: tabs.map { tab in
                BrowserChrome.Tab(
                    title: tab.title,
                    host: tab.webView.url?.host() ?? (tab.isSuspended ? tab.sessionURL?.host() : nil),
                    isPinned: tab.isPinned,
                    audio: tab.isMuted ? .muted : (tab.isPlayingMedia ? .playing : .silent)
                )
            },
            active: activeIndex,
            address: isEditingAddress ? addressDraft : (activeTab?.urlText ?? ""),
            isEditing: isEditingAddress,
            isSelected: isAddressSelected,
            canGoBack: activeTab?.canGoBack ?? false,
            canGoForward: activeTab?.canGoForward ?? false,
            isLoading: activeTab?.isLoading ?? false,
            progress: activeTab?.loadProgress ?? 1,
            blockerOn: AppServices.shared.blocker.isEnabled(for: url?.host()),
            isBookmarked: url.map { AppServices.shared.history.isBookmarked($0) } ?? false,
            isReading: activeTab?.isReading ?? false,
            isWebPage: url?.scheme == "http" || url?.scheme == "https",
            hasMedia: !media.isEmpty,
            hasDownloads: !AppServices.shared.downloads.items.isEmpty,
            isDownloading: AppServices.shared.downloads.hasRunning
        )
        bookmarksBar.update(pages: AppServices.shared.history.bookmarks)
        updateSuggestions()
    }

    // MARK: - Sugerencias de la barra de direcciones

    private func updateSuggestions() {
        guard isEditingAddress, !addressDraft.isEmpty else {
            suggestions.isHidden = true
            return
        }
        suggestions.update(
            items: AddressSuggestions.build(for: addressDraft),
            under: chrome.addressFieldFrame,
            in: bounds.width
        )
    }

    /// Abre una sugerencia. La de búsqueda **no pasa por `load`**: si lo que
    /// se escribió parece una dirección, `load` la abriría como tal y elegir
    /// «Buscar» no habría servido de nada.
    private func openSuggestion(_ item: AddressSuggestions.Item) {
        isEditingAddress = false
        isAddressSelected = false
        suggestions.isHidden = true
        switch item.kind {
        case .search:
            if let url = SearchEngine.current.url(for: item.target) {
                activeTab?.load(url.absoluteString)
            }
        case .address, .bookmark, .history:
            activeTab?.load(item.target)
        }
        refreshChrome()
    }

    @objc private func bookmarksChanged() {
        setNeedsLayout()
        refreshChrome()
    }

    @objc private func downloadsChanged() {
        refreshChrome()
    }

    /// El menú del ⤓: lo que se está bajando y lo último que terminó.
    private func downloadsMenu() -> [ContextMenu.Entry] {
        let center = AppServices.shared.downloads
        var entries: [ContextMenu.Entry] = center.items.prefix(8).map { item in
            // El detalle va en el mismo renglón: el menú no tiene subtítulos, y
            // «45 % · 12 MB de 30 MB» es justo lo que hace falta ver.
            return ContextMenu.Entry(
                title: "\(item.name) · \(item.detail)",
                symbol: item.isRunning ? "arrow.down.circle" : (item.url == nil ? "exclamationmark.triangle" : "doc")
            ) { [weak self] in
                if item.isRunning {
                    center.cancel(item)
                } else if let url = item.url {
                    self?.downloadToast.alpha = 0
                    AppServices.shared.desktopViewController?.revealInFiles(url)
                }
            }
        }
        if entries.isEmpty {
            entries.append(ContextMenu.Entry(title: "No hay descargas", symbol: "tray", isEnabled: false) {})
        }
        entries.append(ContextMenu.Entry(title: "Abrir la carpeta Descargas", symbol: "folder") {
            AppServices.shared.desktopViewController?.revealInFiles(BrowserTab.downloadsDirectory)
        })
        if center.items.contains(where: { !$0.isRunning }) {
            entries.append(ContextMenu.Entry(title: "Vaciar la lista", symbol: "xmark.circle") {
                center.clearFinished()
            })
        }
        return entries
    }

    @objc private func faviconsChanged() {
        bookmarksBar.setNeedsDisplay()
    }

    // MARK: - Favoritos

    /// Cmd+D, la estrella de la barra y el clic derecho: los tres pasan por
    /// aquí para que el aviso y el icono digan siempre lo mismo.
    func toggleBookmark() {
        guard let tab = activeTab, let url = tab.webView.url,
              url.scheme == "http" || url.scheme == "https"
        else { return }
        let added = AppServices.shared.history.toggleBookmark(url: url, title: tab.title)
        AppServices.shared.favicons.remember(host: url.host(), iconURL: nil)
        toast(added ? "Añadido a favoritos" : "Quitado de favoritos")
        refreshChrome()
    }

    /// Modo lectura, como el de Safari: el artículo sin lo demás.
    func toggleReader() {
        guard let tab = activeTab else { return }
        let wasReading = tab.isReading
        Task { [weak self] in
            let worked = await tab.toggleReader()
            guard let self else { return }
            if !worked {
                self.toast("Esta página no tiene un artículo que leer")
            } else if !wasReading {
                self.toast("Modo lectura · pulsa otra vez para salir")
            }
            self.refreshChrome()
        }
    }

    private func openBookmark(_ page: BrowserHistory.Page, inNewTab: Bool) {
        guard !page.url.isEmpty else { return }
        if inNewTab {
            newTab(url: page.url)
        } else {
            activeTab?.load(page.url)
        }
    }

    /// El menú de un favorito: abrir, renombrar, ordenar y quitar.
    private func bookmarkMenu(for page: BrowserHistory.Page) -> [ContextMenu.Entry] {
        let history = AppServices.shared.history
        return [
            ContextMenu.Entry(title: "Abrir", symbol: "arrow.forward") { [weak self] in
                self?.openBookmark(page, inNewTab: false)
            },
            ContextMenu.Entry(title: "Abrir en pestaña nueva", symbol: "plus.square.on.square") { [weak self] in
                self?.openBookmark(page, inNewTab: true)
            },
            ContextMenu.Entry(title: "Copiar enlace", symbol: "link") {
                AppServices.shared.clipboard.copy(page.url)
            },
            ContextMenu.Entry(title: "Renombrar…", symbol: "pencil") {
                AppServices.shared.desktopViewController?.presentPrompt(
                    title: "Nombre del favorito",
                    value: page.title
                ) { text in
                    guard let text else { return }
                    history.renameBookmark(page, to: text)
                }
            },
            ContextMenu.Entry(title: "Mover a la izquierda", symbol: "arrow.left") {
                history.moveBookmark(page, by: -1)
            },
            ContextMenu.Entry(title: "Mover a la derecha", symbol: "arrow.right") {
                history.moveBookmark(page, by: 1)
            },
            ContextMenu.Entry(title: "Quitar de favoritos", symbol: "trash", isDestructive: true) {
                history.removeBookmark(page)
            },
        ]
    }

    // MARK: - Medios

    /// Vuelve a mirar qué vídeos hay en la página.
    /// Al volver del dock: lo que la página avisó mientras estaba escondida
    /// no se atendió.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // Puede haberse dormido mientras estaba en el dock.
            activeTab?.resumeIfNeeded()
            refreshMedia()
        } else {
            activeTab?.markUsed()
        }
    }

    private func refreshMedia() {
        guard window != nil, !isHidden, let tab = activeTab, !tab.isSuspended else { return }
        Task { [weak self] in
            let found = await tab.media()
            guard let self, self.activeTab === tab, found != self.media else { return }
            self.media = found
            self.refreshChrome()
        }
    }

    /// El menú del botón de medios.
    ///
    /// Lo que no se puede guardar **también sale**, apagado y diciendo por qué:
    /// enterarse de que un vídeo va por trozos vale más que un menú vacío que
    /// parece un fallo.
    private func mediaMenu() -> [ContextMenu.Entry] {
        guard let tab = activeTab else { return [] }
        var entries: [ContextMenu.Entry] = []
        for item in media {
            if item.isDownloadable {
                entries.append(ContextMenu.Entry(
                    title: "Descargar \(item.label)" + (item.isHLS ? " · por trozos" : ""),
                    symbol: item.symbol
                ) {
                    tab.download(item)
                })
            } else {
                entries.append(ContextMenu.Entry(
                    title: "\(item.label) · por trozos",
                    symbol: "exclamationmark.triangle",
                    isEnabled: false
                ) {})
            }
        }
        if media.contains(where: { !$0.isDownloadable }) {
            entries.append(ContextMenu.Entry(
                title: "Los apagados no son un fichero (DASH o sin lista)",
                symbol: "info.circle",
                isEnabled: false
            ) {})
        }
        return entries
    }

    // MARK: - Pestañas

    /// Una configuración nueva **por pestaña**.
    ///
    /// Antes compartían una, y con ella el `WKUserContentController`: cada
    /// pestaña nueva volvía a meter sus scripts en el mismo sitio, así que con
    /// cinco pestañas cada página cargaba el inyector cinco veces, y cambiar el
    /// bloqueador en una lo cambiaba en todas.
    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        // User-agent de escritorio: con el de iPhone, media web sirve la
        // versión móvil, que en un monitor de 27 pulgadas es ridícula.
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        // El vídeo se queda dentro de la página. Sin esto, en un iPhone se
        // abre el reproductor del sistema a pantalla completa... en el
        // teléfono, que con monitor puesto está apagado.
        configuration.allowsInlineMediaPlayback = true
        // Los clics de BrunOS son sintéticos y WebKit no los cuenta como
        // gesto del usuario: con la restricción puesta, ningún vídeo arrancaría.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        // Pantalla completa de un elemento (el botón de un reproductor web):
        // se queda en el panel en vez de irse al teléfono.
        configuration.preferences.isElementFullscreenEnabled = true
        // Por lo mismo que con el vídeo: un `window.open` desde un clic
        // sintético se bloquearía siempre.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return configuration
    }

    // MARK: - Sesión

    /// Las direcciones de las pestañas, para el próximo arranque.
    var sessionTabs: (urls: [String?], pinned: [Bool], active: Int) {
        (tabs.map { $0.sessionURL?.absoluteString }, tabs.map(\.isPinned), activeIndex)
    }

    /// Recupera las pestañas guardadas. Sólo carga la que se ve; las demás
    /// esperan dormidas a que se pulsen.
    func restore(urls: [String?], pinned: [Bool] = [], active: Int) {
        guard !urls.isEmpty else {
            newTab()
            return
        }
        let active = min(max(active, 0), urls.count - 1)
        for (index, address) in urls.enumerated() {
            let tab: BrowserTab
            if index != active, let address, let url = URL(string: address) {
                tab = makeTab()
                tab.prepareSuspended(at: url)
                tab.webView.isHidden = true
            } else {
                tab = newTab(url: address)
            }
            tab.isPinned = pinned.indices.contains(index) && pinned[index]
        }
        activate(active)
    }

    @discardableResult
    func newTab(url: String? = nil) -> BrowserTab {
        let tab = makeTab()
        activate(tabs.count - 1)

        if let url {
            // Las cookies guardadas, antes de la primera petición: si no, la
            // primera página de cada arranque volvería a pedir el aviso.
            Task { [weak tab] in
                await CookieVault.shared.restore()
                tab?.load(url)
            }
        } else {
            // Página de inicio propia: una en blanco no dice ni dónde estás ni
            // qué puedes hacer.
            tab.loadStartPage()
            Task { await CookieVault.shared.restore() }
        }
        setNeedsLayout()
        return tab
    }

    /// Una pestaña nueva, ya en el panel, sin activar ni cargar nada.
    private func makeTab() -> BrowserTab {
        let tab = BrowserTab(configuration: Self.makeConfiguration())
        tab.onChange = { [weak self] in
            self?.refreshChrome()
            AppServices.shared.desktop.notifyTitleChange()
        }
        tab.onOpenInNewTab = { [weak self] url in
            self?.newTab(url: url.absoluteString)
        }
        tab.onMediaHint = { [weak self, weak tab] in
            guard let self, self.activeTab === tab else { return }
            self.refreshMedia()
        }
        tab.onDownloadChange = { [weak self] name, state in
            self?.showDownload(name, state)
        }
        tabs.append(tab)
        content.addSubview(tab.webView)
        return tab
    }

    /// Cmd+W. Una fijada no se cierra así, como en Safari: se pierde sin
    /// querer justo la que se quería tener siempre a mano.
    func closeActiveTab() {
        if activeTab?.isPinned == true {
            toast("Pestaña fijada · suéltala o ciérrala desde su menú")
            return
        }
        close(at: activeIndex)
    }

    // MARK: - Fijar y silenciar

    /// Fija o suelta una pestaña. Las fijadas van siempre delante: al fijarla
    /// pasa al final de las fijadas, y al soltarla, justo detrás de ellas.
    func togglePin(_ tab: BrowserTab) {
        let pinnedCount = tabs.filter(\.isPinned).count
        tab.isPinned.toggle()
        move(tab, to: tab.isPinned ? pinnedCount : pinnedCount - 1)
        refreshChrome()
        AppServices.shared.desktop.notifyTitleChange()
    }

    /// Cambia una pestaña de sitio sin perder cuál es la que se ve.
    private func move(_ tab: BrowserTab, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let shown = activeTab
        tabs.remove(at: from)
        tabs.insert(tab, at: max(0, min(destination, tabs.count)))
        if let shown, let index = tabs.firstIndex(where: { $0 === shown }) {
            activeIndex = index
        }
    }

    func toggleMute(_ tab: BrowserTab) {
        tab.setMuted(!tab.isMuted)
        refreshChrome()
    }

    /// Silencia o devuelve el sonido a la pestaña que se ve.
    func toggleMuteActiveTab() {
        guard let tab = activeTab else { return }
        toggleMute(tab)
        toast(tab.isMuted ? "Pestaña silenciada" : "Sonido activado")
    }

    private func close(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        if let url = tab.webView.url, url.scheme == "http" || url.scheme == "https" {
            closedTabs.append(url.absoluteString)
            if closedTabs.count > 10 { closedTabs.removeFirst() }
        }
        tab.webView.removeFromSuperview()
        if index < activeIndex { activeIndex -= 1 }
        if tabs.isEmpty {
            newTab()
        } else {
            activate(min(activeIndex, tabs.count - 1))
        }
        setNeedsLayout()
    }

    /// Cmd+Mayús+T, como en Safari.
    func reopenClosedTab() {
        guard let url = closedTabs.popLast() else {
            toast("No hay ninguna pestaña que recuperar")
            return
        }
        newTab(url: url)
    }

    /// El menú del clic derecho sobre una pestaña.
    private func tabMenu(at index: Int) -> [ContextMenu.Entry] {
        guard tabs.indices.contains(index) else { return [] }
        let tab = tabs[index]
        var entries: [ContextMenu.Entry] = [
            ContextMenu.Entry(title: "Recargar", symbol: "arrow.clockwise") { tab.reload() },
            ContextMenu.Entry(title: "Duplicar", symbol: "plus.square.on.square") { [weak self] in
                guard let url = tab.webView.url else { return }
                self?.newTab(url: url.absoluteString)
            },
            ContextMenu.Entry(
                title: tab.isPinned ? "Soltar pestaña" : "Fijar pestaña",
                symbol: tab.isPinned ? "pin.slash" : "pin"
            ) { [weak self] in
                self?.togglePin(tab)
            },
            ContextMenu.Entry(
                title: tab.isMuted ? "Activar el sonido" : "Silenciar pestaña",
                symbol: tab.isMuted ? "speaker.wave.2" : "speaker.slash"
            ) { [weak self] in
                self?.toggleMute(tab)
            },
        ]
        if tabs.contains(where: { $0 !== tab && $0.isPlayingMedia && !$0.isMuted }) {
            entries.append(ContextMenu.Entry(title: "Silenciar las demás", symbol: "speaker.slash.circle") {
                [weak self] in
                guard let self else { return }
                for other in self.tabs where other !== tab && other.isPlayingMedia {
                    other.setMuted(true)
                }
                self.refreshChrome()
            })
        }
        if let url = tab.webView.url, url.scheme == "http" || url.scheme == "https" {
            entries.append(ContextMenu.Entry(title: "Copiar enlace", symbol: "link") {
                AppServices.shared.clipboard.copy(url)
            })
        }
        entries.append(ContextMenu.Entry(title: "Cerrar", symbol: "xmark") { [weak self] in
            self?.close(at: index)
        })
        // Las fijadas se quedan, como en Safari.
        entries.append(ContextMenu.Entry(
            title: "Cerrar las demás",
            symbol: "xmark.square",
            isEnabled: tabs.contains { $0 !== tab && !$0.isPinned }
        ) { [weak self] in
            guard let self else { return }
            for position in self.tabs.indices.reversed()
            where self.tabs[position] !== tab && !self.tabs[position].isPinned {
                self.close(at: position)
            }
            if let index = self.tabs.firstIndex(where: { $0 === tab }) { self.activate(index) }
        })
        if !closedTabs.isEmpty {
            entries.append(ContextMenu.Entry(title: "Reabrir la última cerrada", symbol: "arrow.uturn.left") {
                [weak self] in self?.reopenClosedTab()
            })
        }
        return entries
    }

    private func activate(_ index: Int) {
        if isFinding { hideFind() }
        // La que se deja de ver empieza a contar desde ahora.
        activeTab?.markUsed()
        activeIndex = max(0, min(index, tabs.count - 1))
        for (position, tab) in tabs.enumerated() {
            tab.webView.isHidden = position != activeIndex
        }
        activeTab?.resumeIfNeeded()
        Self.reclaimMemory()
        // Otra pestaña, otros vídeos.
        media = []
        refreshMedia()
        refreshChrome()
        AppServices.shared.desktop.notifyTitleChange()
    }

    /// Duerme las pestañas que llevan más tiempo sin mirarse, entre todos los
    /// navegadores: las que pasan de `idleLimit` sin verse, y las más viejas
    /// si hay más de `maxLiveTabs` despiertas. **Nunca la que se está
    /// viendo**: la activa de un navegador que está en el escritorio.
    /// Cuántas pestañas hay y cuántas despiertas, para Ajustes › Rendimiento.
    static var tabCounts: (live: Int, total: Int) {
        let tabs = all.allObjects.flatMap(\.tabs)
        return (tabs.filter { !$0.isSuspended }.count, tabs.count)
    }

    static func reclaimMemory() {
        let now = Date()
        var candidates: [BrowserTab] = []
        var live = 0
        for pane in all.allObjects {
            for tab in pane.tabs where !tab.isSuspended {
                live += 1
                let visible = pane.window != nil && tab === pane.activeTab
                if !visible { candidates.append(tab) }
            }
        }
        candidates.sort { $0.lastUsed < $1.lastUsed }

        var excess = max(0, live - maxLiveTabs)
        for tab in candidates {
            if excess > 0 {
                tab.suspend()
                excess -= 1
            } else if now.timeIntervalSince(tab.lastUsed) > idleLimit {
                tab.suspend()
            }
        }
    }

    @objc private func zoomChanged() {
        for tab in tabs {
            tab.pageZoom = BrowserZoom.default
        }
    }

    @objc private func blockerChanged() {
        for tab in tabs {
            AppServices.shared.blocker.install(
                into: tab.webView.configuration.userContentController,
                host: tab.webView.url?.host()
            )
        }
        refreshChrome()
    }

    // MARK: - Órdenes

    /// Abre la barra de direcciones con **todo el texto seleccionado**, como
    /// cualquier navegador: al escribir la primera letra se sustituye entero.
    ///
    /// Sin esto había que borrar a mano la dirección anterior antes de poder
    /// escribir otra, que con `about:blank` delante es de todo menos cómodo.
    func focusAddressBar() {
        isEditingAddress = true
        addressDraft = activeTab?.urlText ?? ""
        isAddressSelected = !addressDraft.isEmpty
        refreshChrome()
    }

    func reload() { activeTab?.reload() }
    func goBack() { activeTab?.goBack() }
    func goForward() { activeTab?.goForward() }

    func changeZoom(by delta: CGFloat) {
        guard let tab = activeTab else { return }
        tab.pageZoom = min(max(tab.pageZoom + delta, 0.5), 3)
        showZoom(tab.pageZoom)
    }

    /// Cmd+0 vuelve al zoom que corresponde a la escala de la pantalla, no a 1.
    func resetZoom() {
        BrowserZoom.reset()
        activeTab?.pageZoom = BrowserZoom.default
        showZoom(BrowserZoom.default)
    }

    // MARK: - Indicador de zoom

    private let zoomBadge = UILabel()
    private var zoomBadgeTask: Task<Void, Never>?

    /// «125 %» en el centro de la página durante un segundo, como Safari:
    /// sin él, con Cmd + / − no se sabía en qué proporción se estaba (Bruno,
    /// 24-sep-2026).
    private func showZoom(_ zoom: CGFloat) {
        if zoomBadge.superview == nil {
            zoomBadge.font = Tokens.sans(22, weight: .semibold)
            zoomBadge.textColor = Tokens.Color.text
            zoomBadge.textAlignment = .center
            zoomBadge.backgroundColor = Tokens.Color.panelElevated.withAlphaComponent(0.94)
            zoomBadge.layer.cornerRadius = 14
            zoomBadge.layer.masksToBounds = true
            zoomBadge.alpha = 0
            addSubview(zoomBadge)
        }
        zoomBadge.text = "\(Int((zoom * 100).rounded())) %"
        let size = CGSize(width: 120, height: 56)
        zoomBadge.frame = CGRect(
            x: content.frame.midX - size.width / 2, y: content.frame.midY - size.height / 2,
            width: size.width, height: size.height
        )
        bringSubviewToFront(zoomBadge)
        UIView.animate(withDuration: 0.12) { self.zoomBadge.alpha = 1 }

        zoomBadgeTask?.cancel()
        zoomBadgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            UIView.animate(withDuration: 0.3) { self.zoomBadge.alpha = 0 }
        }
    }

    func copySelection() {
        activeTab?.copySelection()
    }

    func paste() {
        guard let text = AppServices.shared.clipboard.readForPaste() else { return }
        activeTab?.insertText(text)
    }

    /// Interruptor del bloqueador para el sitio que se está viendo.
    func toggleBlockerForCurrentSite() {
        guard let host = activeTab?.webView.url?.host() else { return }
        AppServices.shared.blocker.toggleException(for: host)
    }

    func isDragArea(_ point: CGPoint) -> Bool {
        guard chrome.frame.contains(point) else { return false }
        return chrome.hit(at: CGPoint(x: point.x, y: point.y - chrome.frame.minY)) == .none
    }

    // MARK: - Contraseñas

    /// Aviso de que la contraseña se elige en el iPhone.
    private let loginBanner = UILabel()

    /// Si el clic ha caído en un campo de inicio de sesión, se ofrecen las
    /// contraseñas de iOS en el iPhone. Ver `PasswordBridge`.
    private func offerPasswordIfLogin(tab: BrowserTab, at point: CGPoint) {
        Task { [weak self] in
            guard let hit = await tab.describe(at: point), hit.login != nil,
                  let url = tab.webView.url, url.scheme == "https" || url.scheme == "http",
                  let host = url.host()
            else { return }
            let bridge = AppServices.shared.passwords
            guard !bridge.isAsking else { return }
            bridge.ask(host: host) { [weak self] username, password in
                tab.fillLogin(username: username, password: password)
                self?.hideLoginBanner()
            } onCancel: { [weak self] in
                self?.hideLoginBanner()
            }
            if bridge.isAsking { self?.showLoginBanner() }
        }
    }

    private func showLoginBanner() {
        if loginBanner.superview == nil {
            loginBanner.font = Tokens.sans(12.5, weight: .medium)
            loginBanner.textColor = Tokens.Color.text
            loginBanner.backgroundColor = Tokens.Color.panelElevated
            loginBanner.textAlignment = .center
            loginBanner.layer.cornerRadius = 9
            loginBanner.layer.masksToBounds = true
            loginBanner.setThemedBorder(Tokens.Color.accent.withAlphaComponent(0.6))
            loginBanner.layer.borderWidth = 1
            addSubview(loginBanner)
        }
        loginBanner.text = "🔑  Elige la contraseña en el iPhone · Esc para escribirla a mano"
        let width = min(bounds.width - 40, loginBanner.intrinsicContentSize.width + 32)
        loginBanner.frame = CGRect(x: (bounds.width - width) / 2, y: content.frame.minY + 12, width: width, height: 30)
        loginBanner.isHidden = false
    }

    private func hideLoginBanner() {
        loginBanner.isHidden = true
    }

    // MARK: - Buscar

    /// Cmd+F: la barra de búsqueda bajo la de direcciones.
    func showFind() {
        isEditingAddress = false
        if !isFinding {
            isFinding = true
            findBar.reset()
        }
        setNeedsLayout()
        refreshChrome()
    }

    private func hideFind() {
        isFinding = false
        activeTab?.clearFind()
        setNeedsLayout()
    }

    private func find(_ text: String, backwards: Bool) {
        guard let tab = activeTab else { return }
        guard !text.isEmpty else {
            findBar.status = nil
            tab.clearFind()
            return
        }
        Task { [weak self] in
            let (found, count) = await tab.find(text, backwards: backwards)
            guard let self, self.findBar.query == text else { return }
            self.findBar.status = found
                ? (count == 1 ? "1 coincidencia" : "\(count) coincidencias")
                : "Sin resultados"
        }
    }

    // MARK: - Menú contextual

    /// El menú del clic derecho sobre la página.
    ///
    /// **Es de BrunOS, no de la página.** El botón derecho sintético sólo le
    /// llega a la web como un evento `contextmenu`, y el menú del sistema no
    /// sale nunca: sin esto no había forma de abrir un enlace en otra pestaña
    /// ni de descargar nada.
    func contextMenuEntries(at location: CGPoint) async -> [ContextMenu.Entry] {
        if chrome.frame.contains(location) {
            let point = CGPoint(x: location.x, y: location.y - chrome.frame.minY)
            if case .tab(let index) = chrome.hit(at: point) { return tabMenu(at: index) }
            return []
        }
        guard let tab = activeTab else { return [] }

        // El botón derecho sobre la barra de favoritos: el menú del favorito
        // que haya debajo, o el de la barra si se pulsa en el hueco.
        if !bookmarksBar.isHidden, bookmarksBar.frame.contains(location) {
            let point = CGPoint(x: location.x, y: location.y - bookmarksBar.frame.minY)
            if case .bookmark(let index) = bookmarksBar.hit(at: point),
               bookmarksBar.pages.indices.contains(index) {
                return bookmarkMenu(for: bookmarksBar.pages[index])
            }
            return [
                ContextMenu.Entry(title: "Añadir esta página", symbol: "star") { [weak self] in
                    self?.toggleBookmark()
                },
                ContextMenu.Entry(title: "Ocultar la barra de favoritos", symbol: "eye.slash") { [weak self] in
                    BookmarksBar.isVisible = false
                    self?.setNeedsLayout()
                },
            ]
        }
        guard content.frame.contains(location) else { return [] }
        let point = CGPoint(x: location.x, y: location.y - content.frame.minY)
        let hit = await tab.describe(at: point)

        var entries: [ContextMenu.Entry] = []

        if let link = hit?.link, let url = URL(string: link) {
            entries.append(ContextMenu.Entry(title: "Abrir en pestaña nueva", symbol: "plus.square.on.square") {
                [weak self] in self?.newTab(url: url.absoluteString)
            })
            entries.append(ContextMenu.Entry(title: "Descargar enlace", symbol: "arrow.down.circle") {
                tab.download(url)
            })
            entries.append(ContextMenu.Entry(title: "Copiar enlace", symbol: "link") {
                AppServices.shared.clipboard.copy(url)
            })
        }

        if let image = hit?.image, let url = URL(string: image) {
            entries.append(ContextMenu.Entry(title: "Abrir imagen en pestaña nueva", symbol: "photo") {
                [weak self] in self?.newTab(url: url.absoluteString)
            })
            entries.append(ContextMenu.Entry(title: "Guardar imagen", symbol: "square.and.arrow.down") {
                tab.download(url)
            })
            entries.append(ContextMenu.Entry(title: "Copiar dirección de la imagen", symbol: "doc.on.doc") {
                AppServices.shared.clipboard.copy(url)
            })
        }

        // Vídeo o audio bajo el cursor: se ofrece guardarlo. Lo que va por
        // trozos (HLS, o un `blob:` montado por el reproductor) no es un
        // fichero, y se dice en vez de dejar el menú sin la opción.
        if let found = await tab.media(at: point) {
            if !found.isDownloadable {
                entries.append(ContextMenu.Entry(
                    title: "El vídeo va por trozos: no se puede guardar",
                    symbol: "exclamationmark.triangle",
                    isEnabled: false
                ) {})
            } else {
                entries.append(ContextMenu.Entry(
                    title: found.isAudio ? "Descargar audio" : "Descargar vídeo",
                    symbol: found.symbol
                ) {
                    tab.download(found)
                })
                entries.append(ContextMenu.Entry(title: "Copiar dirección del vídeo", symbol: "link") {
                    AppServices.shared.clipboard.copy(found.url)
                })
            }
        }

        if let selection = hit?.selection {
            entries.append(ContextMenu.Entry(title: "Copiar", symbol: "doc.on.doc") {
                AppServices.shared.clipboard.copy(selection)
            })
            let short = selection.count > 24 ? String(selection.prefix(24)) + "…" : selection
            entries.append(ContextMenu.Entry(
                title: "Buscar «\(short)»",
                symbol: "magnifyingglass"
            ) { [weak self] in
                self?.newTab(url: selection)
            })
        }

        if hit?.isEditable == true {
            entries.append(ContextMenu.Entry(
                title: "Pegar",
                symbol: "doc.on.clipboard",
                isEnabled: UIPasteboard.general.hasStrings
            ) { [weak self] in
                self?.paste()
            })
        }

        entries.append(ContextMenu.Entry(title: "Atrás", symbol: "chevron.left", isEnabled: tab.canGoBack) {
            [weak self] in self?.goBack()
        })
        entries.append(ContextMenu.Entry(title: "Adelante", symbol: "chevron.right", isEnabled: tab.canGoForward) {
            [weak self] in self?.goForward()
        })
        entries.append(ContextMenu.Entry(title: "Recargar", symbol: "arrow.clockwise") {
            [weak self] in self?.reload()
        })
        if let url = tab.webView.url, url.scheme == "http" || url.scheme == "https" {
            entries.append(ContextMenu.Entry(
                title: tab.isReading ? "Salir del modo lectura" : "Modo lectura",
                symbol: "textformat.size"
            ) { [weak self] in
                self?.toggleReader()
            })
        }
        if tab.webView.url != nil {
            entries.append(ContextMenu.Entry(title: "Guardar como PDF", symbol: "doc.richtext") {
                [weak self] in self?.savePDF()
            })
        }
        if let url = tab.webView.url, url.scheme == "http" || url.scheme == "https" {
            let history = AppServices.shared.history
            let saved = history.isBookmarked(url)
            entries.append(ContextMenu.Entry(
                title: saved ? "Quitar de favoritos" : "Añadir a favoritos",
                symbol: saved ? "star.slash" : "star"
            ) { [weak self] in
                self?.toggleBookmark()
            })
        }
        if let host = tab.webView.url?.host() {
            let blocking = AppServices.shared.blocker.isEnabled(for: host)
            entries.append(ContextMenu.Entry(
                title: blocking ? "No bloquear en \(host)" : "Bloquear en \(host)",
                symbol: blocking ? "shield.slash" : "shield"
            ) { [weak self] in
                self?.toggleBlockerForCurrentSite()
            })
        }
        return entries
    }

    /// Guarda la página como PDF en Descargas, como el «Exportar como PDF» de
    /// Safari. Lo hace WebKit entero, con su maquetación y sus saltos de
    /// página: no es una captura de lo que se ve.
    private func savePDF() {
        guard let tab = activeTab else { return }
        let name = (tab.title.isEmpty ? "página" : tab.title)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .prefix(80)
        toast("Creando el PDF…")
        tab.webView.createPDF { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .success(let data):
                    var url = BrowserTab.downloadsDirectory.appendingPathComponent("\(name).pdf")
                    var counter = 2
                    while FileManager.default.fileExists(atPath: url.path) {
                        url = BrowserTab.downloadsDirectory.appendingPathComponent("\(name) \(counter).pdf")
                        counter += 1
                    }
                    do {
                        try data.write(to: url, options: .atomic)
                        self.showDownload(url.lastPathComponent, .finished(url))
                    } catch {
                        self.toast("No se pudo guardar el PDF")
                    }
                case .failure:
                    self.toast("No se pudo crear el PDF")
                }
            }
        }
    }

    // MARK: - Pane

    func setFocused(_ focused: Bool) {
        layer.borderColor = focused
            ? Tokens.Color.accent.desktopCGColor
            : Tokens.Color.border.desktopCGColor
        if !focused {
            isEditingAddress = false
            suggestions.isHidden = true
        }
        refreshChrome()
    }

    func handlePointer(_ event: PointerEvent) {
        if chrome.frame.contains(event.location) {
            handleChromePointer(event)
            return
        }
        chrome.hover(at: nil)

        if suggestions.contains(event.location) {
            switch event.kind {
            case .moved:
                suggestions.hover(at: event.location)
            case .down:
                if let index = suggestions.hit(at: event.location),
                   suggestions.items.indices.contains(index) {
                    openSuggestion(suggestions.items[index])
                }
            default:
                break
            }
            return
        }

        if !bookmarksBar.isHidden, bookmarksBar.frame.contains(event.location) {
            handleBookmarksPointer(event)
            return
        }
        bookmarksBar.hover(at: nil)

        if isFinding, findBar.frame.contains(event.location) {
            findBar.handlePointer(event.kind, at: CGPoint(
                x: event.location.x, y: event.location.y - findBar.frame.minY
            ))
            return
        }

        if downloadToast.alpha > 0.5, downloadToast.frame.contains(event.location) {
            if case .down = event.kind { revealDownloads() }
            return
        }

        guard let tab = activeTab else { return }
        // Coordenadas de la página, que empieza bajo la barra del panel.
        let point = CGPoint(
            x: event.location.x,
            y: event.location.y - content.frame.minY
        )

        switch event.kind {
        case .moved:
            tab.hover(at: point)
        case .down(let button):
            isEditingAddress = false
            isAddressSelected = false
            suggestions.isHidden = true
            // Cmd+clic y el botón central: el enlace, a una pestaña nueva.
            if button == .middle || (button == .left && event.modifiers.contains(.command)) {
                Task { [weak self] in
                    guard let link = await tab.describe(at: point)?.link,
                          let url = URL(string: link) else { return }
                    self?.newTab(url: url.absoluteString)
                }
                return
            }
            tab.click(at: point, button: button, modifiers: event.modifiers)
            refreshChrome()
            if button == .left { offerPasswordIfLogin(tab: tab, at: point) }
        case .scroll(let delta):
            tab.scroll(at: point, delta: delta)
        case .up:
            break
        }
    }

    private func handleBookmarksPointer(_ event: PointerEvent) {
        let point = CGPoint(x: event.location.x, y: event.location.y - bookmarksBar.frame.minY)
        bookmarksBar.hover(at: point)
        guard case .down(let button) = event.kind else { return }

        switch bookmarksBar.hit(at: point) {
        case .bookmark(let index):
            guard bookmarksBar.pages.indices.contains(index) else { return }
            // Cmd+clic y el botón central, a una pestaña nueva, como un
            // enlace. El derecho no llega aquí: el escritorio lo desvía a
            // `contextMenuEntries`, que es quien monta el menú.
            openBookmark(
                bookmarksBar.pages[index],
                inNewTab: button == .middle || event.modifiers.contains(.command)
            )
        case .overflow:
            let entries = bookmarksBar.overflowPages.map { page in
                ContextMenu.Entry(title: page.title, symbol: "star") { [weak self] in
                    self?.openBookmark(page, inNewTab: false)
                }
            }
            AppServices.shared.desktopViewController?.presentContextMenu(
                entries, from: self, at: event.location
            )
        case .none:
            break
        }
    }

    private func handleChromePointer(_ event: PointerEvent) {
        let point = CGPoint(x: event.location.x, y: event.location.y - chrome.frame.minY)
        chrome.hover(at: point)
        guard case .down = event.kind else { return }

        switch chrome.hit(at: point) {
        case .tab(let index):
            activate(index)
        case .closeTab(let index):
            close(at: index)
        case .tabAudio(let index):
            if tabs.indices.contains(index) { toggleMute(tabs[index]) }
        case .audio:
            if let activeTab { toggleMute(activeTab) }
        case .newTab:
            newTab()
        case .back:
            goBack()
        case .forward:
            goForward()
        case .reload:
            reload()
        case .address:
            focusAddressBar()
        case .blocker:
            toggleBlockerForCurrentSite()
        case .bookmark:
            toggleBookmark()
        case .reader:
            toggleReader()
        case .media:
            AppServices.shared.desktopViewController?.presentContextMenu(
                mediaMenu(), from: self, at: event.location
            )
        case .downloads:
            AppServices.shared.desktopViewController?.presentContextMenu(
                downloadsMenu(), from: self, at: event.location
            )
        case .history:
            AppServices.shared.desktopViewController?.presentHistory()
        case .settings:
            AppServices.shared.desktopViewController?.presentSettings(.browser)
        case .window(let button):
            WindowControls.perform(button, on: self)
        case BrowserChrome.Target.none:
            isEditingAddress = false
            refreshChrome()
        }
    }

    func handleKey(_ event: KeyEvent) {
        guard event.phase == .down else { return }

        // Con la barra de direcciones abierta, el teclado es suyo.
        if isEditingAddress {
            switch event.key.keyCode {
            case .keyboardReturnOrEnter:
                // Lo que esté marcado en la lista manda: es lo que se ve
                // resaltado, y en Safari Intro abre eso.
                if !suggestions.isHidden, let item = suggestions.selected {
                    openSuggestion(item)
                    return
                }
                isEditingAddress = false
                isAddressSelected = false
                activeTab?.load(addressDraft)
            case .keyboardDownArrow:
                suggestions.moveSelection(by: 1)
                return
            case .keyboardUpArrow:
                suggestions.moveSelection(by: -1)
                return
            case .keyboardEscape:
                isEditingAddress = false
                isAddressSelected = false
                suggestions.isHidden = true
            case .keyboardDeleteOrBackspace:
                // Con todo seleccionado, borrar se lleva la selección entera.
                if isAddressSelected {
                    addressDraft = ""
                    isAddressSelected = false
                } else if !addressDraft.isEmpty {
                    addressDraft.removeLast()
                }
            default:
                let characters = event.key.characters
                guard !characters.isEmpty else { break }
                if isAddressSelected {
                    addressDraft = characters
                    isAddressSelected = false
                } else {
                    addressDraft += characters
                }
            }
            refreshChrome()
            return
        }

        if isFinding {
            findBar.handleKey(event)
            return
        }

        // Mientras se espera la contraseña del iPhone, Esc es «la escribo yo».
        if AppServices.shared.passwords.isAsking, event.key.keyCode == .keyboardEscape {
            AppServices.shared.passwords.cancel()
            return
        }

        activeTab?.sendKey(event.key)
    }

    func insertText(_ text: String) {
        if isEditingAddress {
            if isAddressSelected {
                addressDraft = text
                isAddressSelected = false
            } else {
                addressDraft += text
            }
            refreshChrome()
        } else if isFinding {
            findBar.insertText(text)
        } else {
            activeTab?.insertText(text)
        }
    }
}

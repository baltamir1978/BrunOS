import UIKit
import WebKit

/// Panel de navegador: pestañas, barra de direcciones y la página.
///
/// **Nada de esto recibe eventos del sistema.** Como el resto de la pantalla
/// externa, los clics llegan del escritorio y se resuelven por geometría, y el
/// ratón sobre la página se sintetiza con JavaScript (ver `ClickInjector.js`).
@MainActor
final class BrowserPane: UIView, Pane {

    /// Cuántas pestañas se mantienen cargadas a la vez.
    ///
    /// Cada `WKWebView` vivo es un proceso de WebKit con su memoria. Pasado un
    /// punto, iOS mata la app entera sin avisar. Las que llevan más tiempo sin
    /// usarse se descargan guardando URL y scroll, y vuelven al mirarlas.
    private static let maxLiveTabs = 8

    private let chrome = BrowserChrome()
    private let bookmarksBar = BookmarksBar()
    private let content = UIView()

    /// Los medios de la página, para el botón de descargar vídeo.
    ///
    /// Se vuelven a pedir cada pocos segundos y no sólo al cargar: casi ningún
    /// reproductor tiene el `<video>` puesto cuando la página termina; aparece
    /// después, al pulsar el play o al cargar el guion del reproductor.
    private var media: [BrowserTab.Media] = []
    private var mediaTimer: Timer?

    private var tabs: [BrowserTab] = []
    private var activeIndex = 0
    private var isEditingAddress = false
    private var addressDraft = ""
    /// Todo el texto de la barra está seleccionado y la próxima tecla lo
    /// sustituye.
    private var isAddressSelected = false

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

    private var activeTab: BrowserTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .white
        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = Tokens.Metric.focusBorderWidth
        layer.borderColor = Tokens.Color.border.desktopCGColor
        clipsToBounds = true

        addSubview(content)
        addSubview(chrome)
        addSubview(bookmarksBar)
        addSubview(findBar)
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

        mediaTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMedia() }
        }
    }

    /// El `Timer` guarda una referencia fuerte hasta que se invalida, y sin
    /// esto el panel cerrado seguiría preguntándole a una pestaña muerta.
    isolated deinit {
        mediaTimer?.invalidate()
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
        for tab in tabs {
            tab.webView.frame = content.bounds
        }
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
            tabs: tabs.map(\.title),
            active: activeIndex,
            address: isEditingAddress ? addressDraft : (activeTab?.urlText ?? ""),
            isEditing: isEditingAddress,
            isSelected: isAddressSelected,
            canGoBack: activeTab?.canGoBack ?? false,
            canGoForward: activeTab?.canGoForward ?? false,
            isLoading: activeTab?.isLoading ?? false,
            blockerOn: AppServices.shared.blocker.isEnabled(for: url?.host()),
            isBookmarked: url.map { AppServices.shared.history.isBookmarked($0) } ?? false,
            hasMedia: !media.isEmpty
        )
        bookmarksBar.update(pages: AppServices.shared.history.bookmarks)
    }

    @objc private func bookmarksChanged() {
        setNeedsLayout()
        refreshChrome()
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
                UIPasteboard.general.string = page.url
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
            if item.isStream {
                entries.append(ContextMenu.Entry(
                    title: "\(item.label) · por trozos",
                    symbol: "exclamationmark.triangle",
                    isEnabled: false
                ) {})
            } else {
                entries.append(ContextMenu.Entry(
                    title: "Descargar \(item.label)",
                    symbol: item.symbol
                ) {
                    tab.download(item.url, named: item.suggestedName)
                })
            }
        }
        if media.contains(where: \.isStream) {
            entries.append(ContextMenu.Entry(
                title: "Los de «por trozos» no son un fichero",
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

    @discardableResult
    func newTab(url: String? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: Self.makeConfiguration())
        tab.onChange = { [weak self] in
            self?.refreshChrome()
            AppServices.shared.desktop.notifyChange()
        }
        tab.onOpenInNewTab = { [weak self] url in
            self?.newTab(url: url.absoluteString)
        }
        tab.onDownloadChange = { [weak self] name, state in
            self?.showDownload(name, state)
        }
        tabs.append(tab)
        content.addSubview(tab.webView)
        activate(tabs.count - 1)

        if let url {
            tab.load(url)
        } else {
            // Página de inicio propia: una en blanco no dice ni dónde estás ni
            // qué puedes hacer.
            tab.loadStartPage()
        }
        setNeedsLayout()
        return tab
    }

    func closeActiveTab() {
        guard tabs.indices.contains(activeIndex) else { return }
        let tab = tabs.remove(at: activeIndex)
        tab.webView.removeFromSuperview()
        if tabs.isEmpty {
            newTab()
        } else {
            activate(min(activeIndex, tabs.count - 1))
        }
        setNeedsLayout()
    }

    private func activate(_ index: Int) {
        if isFinding { hideFind() }
        activeIndex = max(0, min(index, tabs.count - 1))
        for (position, tab) in tabs.enumerated() {
            tab.webView.isHidden = position != activeIndex
        }
        activeTab?.resumeIfNeeded()
        reclaimMemoryIfNeeded()
        refreshChrome()
        AppServices.shared.desktop.notifyChange()
    }

    /// Descarga las pestañas que llevan más tiempo sin mirarse.
    private func reclaimMemoryIfNeeded() {
        let live = tabs.filter { !$0.isSuspended }
        guard live.count > Self.maxLiveTabs else { return }

        let victims = live
            .sorted { $0.lastUsed < $1.lastUsed }
            .prefix(live.count - Self.maxLiveTabs)
        for victim in victims where victim !== activeTab {
            victim.suspend()
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
    }

    /// Cmd+0 vuelve al zoom que corresponde a la escala de la pantalla, no a 1.
    func resetZoom() {
        BrowserZoom.reset()
        activeTab?.pageZoom = BrowserZoom.default
    }

    func copySelection() {
        activeTab?.copySelection()
    }

    func paste() {
        guard let text = UIPasteboard.general.string else { return }
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
        if chrome.frame.contains(location) { return [] }
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
                UIPasteboard.general.url = url
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
                UIPasteboard.general.url = url
            })
        }

        // Vídeo o audio bajo el cursor: se ofrece guardarlo. Lo que va por
        // trozos (HLS, o un `blob:` montado por el reproductor) no es un
        // fichero, y se dice en vez de dejar el menú sin la opción.
        if let found = await tab.media(at: point) {
            if found.isStream {
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
                    tab.download(found.url, named: found.suggestedName)
                })
                entries.append(ContextMenu.Entry(title: "Copiar dirección del vídeo", symbol: "link") {
                    UIPasteboard.general.url = found.url
                })
            }
        }

        if let selection = hit?.selection {
            entries.append(ContextMenu.Entry(title: "Copiar", symbol: "doc.on.doc") {
                UIPasteboard.general.string = selection
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

    // MARK: - Pane

    func setFocused(_ focused: Bool) {
        layer.borderColor = focused
            ? Tokens.Color.accent.desktopCGColor
            : Tokens.Color.border.desktopCGColor
        if !focused { isEditingAddress = false }
        refreshChrome()
    }

    func handlePointer(_ event: PointerEvent) {
        if chrome.frame.contains(event.location) {
            handleChromePointer(event)
            return
        }
        chrome.hover(at: nil)

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
            activate(index)
            closeActiveTab()
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
        case .media:
            AppServices.shared.desktopViewController?.presentContextMenu(
                mediaMenu(), from: self, at: event.location
            )
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
                isEditingAddress = false
                isAddressSelected = false
                activeTab?.load(addressDraft)
            case .keyboardEscape:
                isEditingAddress = false
                isAddressSelected = false
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

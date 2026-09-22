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
    private let content = UIView()

    private var tabs: [BrowserTab] = []
    private var activeIndex = 0
    private var isEditingAddress = false
    private var addressDraft = ""
    /// Todo el texto de la barra está seleccionado y la próxima tecla lo
    /// sustituye.
    private var isAddressSelected = false

    private let configuration: WKWebViewConfiguration

    var title: String { activeTab?.title ?? "Navegador" }
    var view: UIView { self }

    private var activeTab: BrowserTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        // User-agent de escritorio: con el de iPhone, media web sirve la
        // versión móvil, que en un monitor de 27 pulgadas es ridícula.
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        self.configuration = configuration

        super.init(frame: frame)

        backgroundColor = .white
        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = Tokens.Metric.focusBorderWidth
        layer.borderColor = Tokens.Color.border.desktopCGColor
        clipsToBounds = true

        addSubview(content)
        addSubview(chrome)

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()
        chrome.frame = CGRect(x: 0, y: 0, width: bounds.width, height: BrowserChrome.height)
        content.frame = CGRect(
            x: 0,
            y: BrowserChrome.height,
            width: bounds.width,
            height: max(0, bounds.height - BrowserChrome.height)
        )
        for tab in tabs {
            tab.webView.frame = content.bounds
        }
        refreshChrome()
    }

    private func refreshChrome() {
        chrome.update(
            tabs: tabs.map(\.title),
            active: activeIndex,
            address: isEditingAddress ? addressDraft : (activeTab?.urlText ?? ""),
            isEditing: isEditingAddress,
            isSelected: isAddressSelected,
            canGoBack: activeTab?.canGoBack ?? false,
            canGoForward: activeTab?.canGoForward ?? false,
            isLoading: activeTab?.isLoading ?? false,
            blockerOn: AppServices.shared.blocker.isEnabled(for: activeTab?.webView.url?.host())
        )
    }

    // MARK: - Pestañas

    @discardableResult
    func newTab(url: String? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration)
        tab.onChange = { [weak self] in
            self?.refreshChrome()
            AppServices.shared.desktop.notifyChange()
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

        guard let tab = activeTab else { return }
        // Coordenadas de la página, que empieza bajo la barra del panel.
        let point = CGPoint(
            x: event.location.x,
            y: event.location.y - BrowserChrome.height
        )

        switch event.kind {
        case .moved:
            tab.hover(at: point)
        case .down(let button):
            isEditingAddress = false
            isAddressSelected = false
            tab.click(at: point, button: button, modifiers: event.modifiers)
            refreshChrome()
        case .scroll(let delta):
            tab.scroll(at: point, delta: delta)
        case .up:
            break
        }
    }

    private func handleChromePointer(_ event: PointerEvent) {
        guard case .down = event.kind else { return }
        let point = CGPoint(x: event.location.x, y: event.location.y - chrome.frame.minY)

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
        } else {
            activeTab?.insertText(text)
        }
    }
}

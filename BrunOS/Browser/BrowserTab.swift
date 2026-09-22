import UIKit
import WebKit

/// Una pestaña del navegador.
///
/// **El ratón no llega solo al `WKWebView`.** La pantalla externa no es
/// interactiva, así que los clics, el hover y la rueda se sintetizan con
/// JavaScript. Ver `ClickInjector.js`.
@MainActor
@Observable
final class BrowserTab: NSObject {

    let id = UUID()
    let webView: WKWebView

    var title: String = "Nueva pestaña"
    var urlText: String = ""
    var isLoading = false
    var canGoBack = false
    var canGoForward = false

    /// Lo último que dijo `describe()` sobre lo que hay bajo el cursor.
    private(set) var hoveredLink: String?

    /// Cuándo se usó por última vez, para decidir a quién descargar.
    private(set) var lastUsed = Date()

    /// Estado guardado de una pestaña descargada, para poder resucitarla.
    private var suspendedURL: URL?
    private var suspendedScroll: CGPoint = .zero
    private(set) var isSuspended = false

    /// **Hay que conservar la referencia al mundo.** Los creados con
    /// `WKContentWorld(configuration:)` no se pueden recuperar después: si se
    /// suelta, el script se queda sin sitio donde vivir.
    private let world: WKContentWorld

    /// Para no ahogar la página con `mousemove` a cada fotograma.
    private var lastHoverTime: Date = .distantPast

    /// Zoom de la página. Cmd + / − / 0.
    var pageZoom: CGFloat = 1 {
        didSet { webView.pageZoom = pageZoom }
    }

    var onChange: (@MainActor () -> Void)?

    enum DownloadState { case started, finished, failed }
    var onDownloadChange: (@MainActor (String, DownloadState) -> Void)?

    init(configuration: WKWebViewConfiguration) {
        // Mundo propio con acceso a shadow roots cerrados, nuevo en Safari 27.
        // Sirve para llegar a los botones de los componentes web que, de otro
        // modo, no se pueden tocar desde fuera de ninguna manera.
        let worldConfiguration = WKContentWorld.Configuration()
        worldConfiguration.allowAccessingClosedShadowRoots = true
        self.world = WKContentWorld(configuration: worldConfiguration)

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.allowsBackForwardNavigationGestures = false
        // **Blanco, no el gris del escritorio.** La mayoría de la web tiene
        // fondo claro, y pintar el hueco de oscuro hacía que cada página
        // apareciera sobre negro hasta que terminaba de cargar, y que las que
        // no declaran fondo se vieran ilegibles.
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        // Que la web decida si quiere modo oscuro por su cuenta, sin que se lo
        // imponga el estilo del escritorio.
        webView.overrideUserInterfaceStyle = .unspecified
        // El indicador de scroll estorba: el cursor ya dice dónde está uno.
        webView.scrollView.showsVerticalScrollIndicator = false

        webView.navigationDelegate = self
        webView.uiDelegate = self

        AppServices.shared.blocker.install(
            into: configuration.userContentController,
            host: nil
        )

        observeProperties()
        installInjector()
    }

    // MARK: - Navegación

    func load(_ text: String) {
        guard let url = Self.url(from: text) else { return }
        lastUsed = Date()
        isSuspended = false
        webView.load(URLRequest(url: url))
    }

    /// Convierte lo que se escribe en la barra en una URL.
    ///
    /// Si no parece una dirección, se busca. El criterio es el de cualquier
    /// navegador: con espacios o sin punto, es una búsqueda.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(" ") || !trimmed.contains(".") {
            var components = URLComponents(string: "https://duckduckgo.com/")
            components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            return components?.url
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://" + trimmed)
    }

    /// Página de inicio.
    ///
    /// Una en blanco no dice ni dónde estás ni qué puedes hacer. Ésta enseña la
    /// marca y los atajos, que es lo que hace falta recordar al principio.
    func loadStartPage() {
        let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
              :root { color-scheme: dark; }
              body {
                margin: 0; height: 100vh; display: flex; flex-direction: column;
                align-items: center; justify-content: center; gap: 28px;
                background: #0B0D10; color: #9AA1AB;
                font-family: -apple-system, system-ui, sans-serif;
              }
              h1 { margin: 0; font-family: ui-monospace, monospace; font-size: 42px;
                   font-weight: 800; color: #E6E3DC; letter-spacing: -1px; }
              h1 span { color: #E8A33D; }
              table { border-collapse: collapse; font-size: 13px; }
              td { padding: 5px 14px; }
              td:first-child { text-align: right; color: #E6E3DC;
                               font-family: ui-monospace, monospace; }
            </style></head><body>
              <h1>brunOS<span>_</span></h1>
              <table>
                <tr><td>Cmd+L</td><td>escribir una dirección</td></tr>
                <tr><td>Cmd+T</td><td>pestaña nueva</td></tr>
                <tr><td>Cmd+W</td><td>cerrar la pestaña</td></tr>
                <tr><td>Cmd+R</td><td>recargar</td></tr>
                <tr><td>Cmd + / −</td><td>zoom</td></tr>
              </table>
            </body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    // MARK: - Descarga de pestañas inactivas

    /// Suelta la página pero guarda dónde estaba.
    ///
    /// Ocho `WKWebView` vivos se comen la memoria de la app y iOS acaba
    /// matándola entera. Las que no se están mirando se descargan y se
    /// recuperan al volver, con su posición de scroll.
    func suspend() {
        guard !isSuspended, let url = webView.url else { return }
        suspendedURL = url
        suspendedScroll = webView.scrollView.contentOffset
        isSuspended = true
        webView.loadHTMLString("", baseURL: nil)
    }

    func resumeIfNeeded() {
        lastUsed = Date()
        guard isSuspended, let url = suspendedURL else { return }
        isSuspended = false
        webView.load(URLRequest(url: url))
    }

    // MARK: - Ratón sintético

    func click(at point: CGPoint, button: PointerEvent.Button, modifiers: UIKeyModifierFlags) {
        let code = switch button {
        case .left: 0
        case .middle: 1
        case .right: 2
        }
        let script = """
            window.__brunos.click(\(point.x), \(point.y), \(code), {
                ctrl: \(modifiers.contains(.control)),
                alt: \(modifiers.contains(.alternate)),
                shift: \(modifiers.contains(.shift)),
                meta: \(modifiers.contains(.command))
            });
            """
        run(script)
    }

    /// Hover limitado a unas 30 veces por segundo.
    ///
    /// El movimiento llega a cada fotograma de la pantalla externa. Mandarlo
    /// todo a JavaScript ahoga la página y el cursor empieza a arrastrarse.
    func hover(at point: CGPoint) {
        let now = Date()
        guard now.timeIntervalSince(lastHoverTime) > 0.033 else { return }
        lastHoverTime = now
        run("window.__brunos.hover(\(point.x), \(point.y));")
    }

    func scroll(at point: CGPoint, delta: CGVector) {
        run("window.__brunos.wheel(\(point.x), \(point.y), \(-delta.dx), \(-delta.dy));")
    }

    /// Manda una tecla a la página.
    ///
    /// Las teclas normales se insertan como texto en el elemento con foco; las
    /// de control se sintetizan como eventos, porque Intro en un formulario o
    /// Tab entre campos no son "escribir un carácter".
    func sendKey(_ key: UIKey) {
        switch key.keyCode {
        case .keyboardReturnOrEnter: dispatchKey("Enter")
        case .keyboardTab: dispatchKey("Tab")
        case .keyboardEscape: dispatchKey("Escape")
        case .keyboardDeleteOrBackspace: dispatchKey("Backspace")
        case .keyboardUpArrow: dispatchKey("ArrowUp")
        case .keyboardDownArrow: dispatchKey("ArrowDown")
        case .keyboardLeftArrow: dispatchKey("ArrowLeft")
        case .keyboardRightArrow: dispatchKey("ArrowRight")
        default:
            let characters = key.characters
            guard !characters.isEmpty else { return }
            insertText(characters)
        }
    }

    private func dispatchKey(_ name: String) {
        run("""
            (function () {
                const target = document.activeElement || document.body;
                for (const type of ['keydown', 'keyup']) {
                    target.dispatchEvent(new KeyboardEvent(type, {
                        key: '\(name)', code: '\(name)',
                        bubbles: true, cancelable: true, composed: true
                    }));
                }
            })();
            """)
    }

    /// Copia lo que haya seleccionado en la página.
    func copySelection() {
        webView.evaluateJavaScript("window.getSelection().toString();", in: nil, in: world) { result in
            guard case .success(let value) = result,
                  let text = value as? String, !text.isEmpty
            else { return }
            UIPasteboard.general.string = text
        }
    }

    func insertText(_ text: String) {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        run("window.__brunos.insertText(\"\(escaped)\");")
    }

    /// Lo que hay bajo el cursor.
    ///
    /// Se devuelve un tipo propio y no el diccionario de JavaScript porque
    /// `[String: Any]` no es `Sendable` y Swift 6 no deja sacarlo del callback.
    struct Hit: Sendable {
        var tag: String
        var link: String?
        var image: String?
        var isEditable: Bool
        var cursor: String
    }

    /// Pregunta qué hay bajo el cursor: enlace, imagen, campo de texto.
    func describe(at point: CGPoint) async -> Hit? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "window.__brunos.describe(\(point.x), \(point.y));",
                in: nil,
                in: world
            ) { result in
                guard case .success(let value) = result,
                      let dictionary = value as? [String: Any]
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Hit(
                    tag: dictionary["tag"] as? String ?? "",
                    link: dictionary["link"] as? String,
                    image: dictionary["image"] as? String,
                    isEditable: dictionary["editable"] as? Bool ?? false,
                    cursor: dictionary["cursor"] as? String ?? "auto"
                ))
            }
        }
    }

    private func run(_ script: String) {
        webView.evaluateJavaScript(script, in: nil, in: world) { _ in }
    }

    /// Mete el inyector en el mundo propio, en cada carga.
    private func installInjector() {
        guard let url = Bundle.main.url(forResource: "ClickInjector", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            Log.desktop.error("Falta ClickInjector.js del bundle")
            return
        }

        let script = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: world
        )
        webView.configuration.userContentController.addUserScript(script)
    }

    // MARK: - Estado

    private var observations: [NSKeyValueObservation] = []

    private func observeProperties() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
    }

    private func refresh() {
        title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host() ?? "Nueva pestaña")
        urlText = webView.url?.absoluteString ?? ""
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        onChange?()
    }
}

// MARK: - Delegados

extension BrowserTab: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isSuspended == false, suspendedScroll != .zero {
            webView.scrollView.setContentOffset(suspendedScroll, animated: false)
            suspendedScroll = .zero
        }
        refresh()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        refresh()
    }

    /// Lo que el navegador no sabe enseñar, se descarga.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }
}

// MARK: - Descargas

extension BrowserTab: WKDownloadDelegate {

    /// Dónde cae lo que se descarga.
    ///
    /// En `Documentos/Descargas`, dentro del contenedor de la app, que es donde
    /// el gestor de ficheros de la Fase 4 va a poder verlo. Con la carpeta
    /// expuesta por `UIFileSharingEnabled`, también se ve desde la app Archivos
    /// del iPhone.
    static var downloadsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Descargas", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        var url = Self.downloadsDirectory.appendingPathComponent(suggestedFilename)

        // Nunca se pisa un fichero ya descargado: se numera, como hace
        // cualquier navegador.
        var counter = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            url = Self.downloadsDirectory.appendingPathComponent(name)
            counter += 1
        }

        onDownloadChange?(suggestedFilename, .started)
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        onDownloadChange?(download.originalRequest?.url?.lastPathComponent ?? "", .finished)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: any Error,
        resumeData: Data?
    ) {
        onDownloadChange?(error.localizedDescription, .failed)
    }
}

extension BrowserTab: WKUIDelegate {

    /// Las ventanas emergentes se cargan en la misma pestaña.
    ///
    /// Devolver un `WKWebView` nuevo obligaría a gestionar una jerarquía de
    /// ventanas que en un escritorio en mosaico no pinta nada.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

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
    var pageZoom: CGFloat = BrowserZoom.default {
        didSet {
            webView.pageZoom = pageZoom
            BrowserZoom.remember(pageZoom)
        }
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

        // **User-agent de Safari de macOS.** `preferredContentMode = .desktop`
        // pide la versión de escritorio, pero no cambia el user-agent: muchos
        // sitios siguen viendo un iPhone y sirven su interfaz para dedos, con
        // todo más grande. Se nota justo en las portadas, no en las páginas
        // estáticas.
        webView.customUserAgent = Self.desktopUserAgent

        installDesktopHints()
        installViewportFix()
        // El indicador de scroll estorba: el cursor ya dice dónde está uno.
        webView.scrollView.showsVerticalScrollIndicator = false

        webView.navigationDelegate = self
        webView.uiDelegate = self

        AppServices.shared.blocker.install(
            into: configuration.userContentController,
            host: nil
        )

        webView.pageZoom = pageZoom
        observeProperties()
        installInjector()
    }

    /// Safari de macOS. La versión se deja fija a propósito: seguir la del
    /// sistema aquí no aporta nada y sí puede romper la detección de algún
    /// sitio cuando iOS cambie de número.
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    /// Convence a la página de que hay un ratón y no un dedo.
    ///
    /// **El user-agent no basta.** Google y compañía miran
    /// `navigator.maxTouchPoints` y `ontouchstart`, y si los ven sirven su
    /// interfaz táctil: botones enormes y mucho aire. En BrunOS el puntero es
    /// un ratón de verdad, así que decirlo no es engañar a nadie, es describir
    /// la realidad.
    ///
    /// Va en el mundo **de la página**, no en el propio de BrunOS: tiene que
    /// verlo el JavaScript del sitio.
    private func installDesktopHints() {
        let source = """
            (function () {
                try {
                    Object.defineProperty(navigator, 'maxTouchPoints', { get: () => 0 });
                    Object.defineProperty(navigator, 'msMaxTouchPoints', { get: () => 0 });
                    delete window.ontouchstart;
                    delete window.ontouchmove;
                    delete window.ontouchend;
                } catch (error) {}
            })();
            """
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
    }

    /// Corrige el ancho del viewport en las páginas de escritorio.
    ///
    /// **Ésta era la causa de que todo se viera enorme.** Cuando una página no
    /// declara `meta viewport` —lo normal en una web de escritorio, y es el
    /// caso de la portada de Google— WebKit en iOS le asigna **980 px por
    /// defecto** y luego estira el resultado hasta el ancho real de la vista.
    /// En un panel de 1690 puntos eso son 1,72× de aumento sobre todo:
    /// tipografías, botones, márgenes.
    ///
    /// Se nota sólo en las portadas y no en las páginas sencillas, porque
    /// aquéllas sí suelen declarar su viewport.
    ///
    /// La corrección es añadir un `meta viewport` con `width=device-width`, que
    /// en un `WKWebView` es el ancho de la vista en puntos. Así un píxel CSS
    /// vuelve a ser un punto y la página se ve a su tamaño.
    ///
    /// **Sólo se añade si la página no traía uno**: pisarle el suyo a un sitio
    /// que ya se adapta sería romperlo.
    private func installViewportFix() {
        let source = """
            (function () {
                if (document.querySelector('meta[name=viewport]')) return;
                const meta = document.createElement('meta');
                meta.name = 'viewport';
                meta.content = 'width=device-width, initial-scale=1';
                (document.head || document.documentElement).appendChild(meta);
            })();
            """
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
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
            return SearchEngine.current.url(for: trimmed)
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


/// Zoom por defecto del navegador.
///
/// **Por qué no es siempre 1.** El escritorio se maqueta en puntos lógicos: en
/// un monitor 2K a escala 1,5 son 1707 puntos que luego se estiran a 2560
/// píxeles. La página recibe un viewport de 1707 y lo dibuja para ese ancho,
/// así que sus 16 px por defecto acaban midiendo 24 px reales en el monitor.
/// El resultado es una web desproporcionada frente al resto de la interfaz,
/// que sí está pensada en puntos lógicos.
///
/// Se compensa **en parte**, no del todo: compensarlo entero (1/escala) dejaría
/// el texto exactamente igual que a resolución nativa y anularía el sentido de
/// haber elegido una escala. El suelo de 0,7 evita que a escala 3 la web quede
/// ilegible.
///
/// Y se recuerda lo que Bruno ajuste a mano, que al final es lo que manda.
@MainActor
enum BrowserZoom {

    private static let key = "browser.zoom"

    static var `default`: CGFloat {
        if let stored = UserDefaults.standard.object(forKey: key) as? Double {
            return CGFloat(stored)
        }
        // Arrancar en 1 ahora que el viewport es correcto: la página se ve a su
        // tamaño, ni estirada ni encogida. Antes hacía falta compensar porque
        // WebKit estiraba un viewport de 980 px hasta el ancho del panel.
        return 1
    }

    static func remember(_ zoom: CGFloat) {
        UserDefaults.standard.set(Double(zoom), forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

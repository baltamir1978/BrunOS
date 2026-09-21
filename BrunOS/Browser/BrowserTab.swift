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

    var onChange: (@MainActor () -> Void)?

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
        webView.isOpaque = false
        webView.backgroundColor = Tokens.Color.panel
        webView.scrollView.backgroundColor = Tokens.Color.panel
        // El indicador de scroll estorba: el cursor ya dice dónde está uno.
        webView.scrollView.showsVerticalScrollIndicator = false

        webView.navigationDelegate = self
        webView.uiDelegate = self

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

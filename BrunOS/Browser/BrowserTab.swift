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
    /// De 0 a 1, para la barra de la cápsula de dirección.
    var loadProgress: Double = 1
    var canGoBack = false
    var canGoForward = false

    /// Fijada, como en Safari: a la izquierda, sólo con el icono, y no se
    /// cierra con Cmd+W ni con «Cerrar las demás».
    var isPinned = false

    /// Silenciada desde BrunOS. Ver `setMuted(_:)`.
    private(set) var isMuted = false
    /// Suena algo en la página ahora mismo, para el altavoz de la pestaña.
    private(set) var isPlayingMedia = false

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
    private var lastHoverPoint = CGPoint(x: -1, y: -1)

    /// Zoom de la página. Cmd + / − / 0.
    var pageZoom: CGFloat = BrowserZoom.default {
        didSet {
            webView.pageZoom = pageZoom * displayFactor
            BrowserZoom.remember(pageZoom)
        }
    }

    /// Cuánto estira el lienzo del escritorio, que la vista deshace.
    private var displayFactor: CGFloat = 1

    /// Coloca la página en su hueco **sin que el lienzo la estire**.
    ///
    /// El escritorio se ve nítido a 1,5× porque cada capa se dibuja a más
    /// densidad (`contentsScale`), pero **WebKit no hace caso de eso**: pinta
    /// la página a la densidad de la pantalla, y después el lienzo la
    /// estiraba ×1,5. Bruno lo vio: Google borroso a 1,5× y bien a 1×. Aquí la
    /// vista lleva la escala contraria, así que en pantalla va a 1:1 y WebKit
    /// dibuja a píxel nativo; el zoom de la página multiplica por lo mismo y
    /// todo sale del mismo tamaño que antes. Las coordenadas que recibe el
    /// inyector no cambian: un punto lógico sigue siendo un píxel CSS.
    func place(in rect: CGRect, factor: CGFloat) {
        let factor = factor > 0 ? factor : 1
        webView.transform = .identity
        webView.bounds = CGRect(x: 0, y: 0, width: rect.width * factor, height: rect.height * factor)
        webView.center = CGPoint(x: rect.midX, y: rect.midY)
        webView.transform = factor == 1 ? .identity : CGAffineTransform(scaleX: 1 / factor, y: 1 / factor)
        if displayFactor != factor {
            displayFactor = factor
            webView.pageZoom = pageZoom * factor
        }
    }

    var onChange: (@MainActor () -> Void)?
    /// Abrir algo en una pestaña nueva: lo resuelve el panel.
    var onOpenInNewTab: (@MainActor (URL) -> Void)?

    enum DownloadState {
        case started
        /// Cuánto lleva: fracción y bytes. Un vídeo tarda, y sin esto el aviso
        /// se queda en «Descargando…» sin dar señales de vida.
        case progress(Double, Int64, Int64)
        case finished(URL)
        case failed
    }
    var onDownloadChange: (@MainActor (String, DownloadState) -> Void)?

    /// Dónde va a parar cada descarga, para poder decir luego cuál terminó.
    private var destinations: [ObjectIdentifier: URL] = [:]
    /// El nombre que le queremos poner, cuando lo elegimos nosotros y no el
    /// servidor: un vídeo suele llegar como `videoplayback` o `index.mp4`.
    private var preferredNames: [ObjectIdentifier: String] = [:]
    private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var lastReportedFraction: [ObjectIdentifier: Double] = [:]

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
        installFullscreenBridge()
        // El indicador de scroll estorba: el cursor ya dice dónde está uno.
        webView.scrollView.showsVerticalScrollIndicator = false

        webView.navigationDelegate = self
        webView.uiDelegate = self

        AppServices.shared.blocker.install(
            into: configuration.userContentController,
            host: nil
        )

        webView.pageZoom = pageZoom * displayFactor
        observeProperties()
        installInjector()
    }

    /// Safari de macOS, **con la versión de Safari que trae este iOS**.
    ///
    /// Antes iba fija en la 18.6, y Google, al ver un Safari de hace años con
    /// un motor que se comporta como el de ahora, sacaba el reCAPTCHA de «no
    /// soy un robot» sólo con abrir la portada. Safari lleva el mismo número
    /// que el sistema desde la 26, y «Mac OS X 10_15_7» es lo que sigue
    /// poniendo el Safari de verdad: no se cambia.
    private static let desktopUserAgent: String = {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/\(major).0 Safari/605.1.15"
    }()

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

    // MARK: - Pantalla completa

    /// La pantalla completa de la página la hace BrunOS: la de WebKit exige un
    /// gesto de verdad, y los clics de BrunOS son sintéticos. Ver
    /// `FullscreenBridge.js`. Va en el mundo de la página, que es quien llama
    /// a `requestFullscreen`.
    private func installFullscreenBridge() {
        guard let url = Bundle.main.url(forResource: "FullscreenBridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.add(FullscreenRelay(tab: self), contentWorld: .page, name: "brunosFullscreen")
    }

    /// La página ha entrado (`true`) o salido de la pantalla completa. Lo
    /// resuelve el panel: esconde sus barras y lleva la ventana a todo el
    /// monitor.
    var onFullscreenRequest: (@MainActor (Bool) -> Void)?
    private(set) var isPageFullscreen = false

    fileprivate func fullscreenRequested(_ on: Bool) {
        isPageFullscreen = on
        onFullscreenRequest?(on)
    }

    /// Esc, cambiar de pestaña o cerrar: la página tiene que enterarse de que
    /// ya no está a pantalla completa, o su reproductor se quedaría estirado.
    func exitPageFullscreen() {
        guard isPageFullscreen else { return }
        isPageFullscreen = false
        webView.evaluateJavaScript(
            "window.__brunosFullscreen && window.__brunosFullscreen.exit();", in: nil, in: .page
        ) { _ in }
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
        // Cualquier navegación saca del modo lectura: lo que se cargue ya no
        // es el artículo que se estaba leyendo.
        readerOrigin = nil
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
              /* Los mismos colores que Tokens, en claro y en oscuro: la
                 página sigue el modo del escritorio como cualquier web. */
              :root { color-scheme: light dark;
                      --bg: #F6F4F0; --text: #16191D; --muted: #5C636D; --accent: #A96B06; }
              @media (prefers-color-scheme: dark) {
                :root { --bg: #0B0D10; --text: #E6E3DC; --muted: #9AA1AB; --accent: #E8A33D; }
              }
              body {
                margin: 0; height: 100vh; display: flex; flex-direction: column;
                align-items: center; justify-content: center; gap: 28px;
                background: var(--bg); color: var(--muted);
                font-family: -apple-system, system-ui, sans-serif;
              }
              h1 { margin: 0; font-family: ui-monospace, monospace; font-size: 42px;
                   font-weight: 800; color: var(--text); letter-spacing: -1px; }
              h1 span { color: var(--accent); }
              table { border-collapse: collapse; font-size: 13px; }
              td { padding: 5px 14px; }
              td:first-child { text-align: right; color: var(--text);
                               font-family: ui-monospace, monospace; }
              .favorites { display: flex; flex-wrap: wrap; justify-content: center;
                           gap: 10px; max-width: 720px; }
              .favorites a { display: flex; align-items: center; gap: 8px;
                             padding: 8px 12px; border-radius: 9px; text-decoration: none;
                             background: color-mix(in srgb, var(--text) 7%, transparent);
                             color: var(--text); font-size: 12.5px; max-width: 190px; }
              .favorites a:hover { background: color-mix(in srgb, var(--accent) 22%, transparent); }
              .favorites img, .favorites .letter {
                             width: 16px; height: 16px; border-radius: 4px; flex: none; }
              .favorites .letter { display: flex; align-items: center; justify-content: center;
                             color: #fff; font-size: 9px; font-weight: 700; }
              .favorites span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            </style></head><body>
              <h1>brunOS<span>_</span></h1>
              \(Self.favoritesHTML())
              <table>
                <tr><td>Cmd+L</td><td>escribir una dirección</td></tr>
                <tr><td>Cmd+T</td><td>pestaña nueva</td></tr>
                <tr><td>Cmd+W</td><td>cerrar la pestaña</td></tr>
                <tr><td>Cmd+R</td><td>recargar</td></tr>
                <tr><td>Cmd + / −</td><td>zoom</td></tr>
                <tr><td>clic derecho</td><td>abrir en pestaña nueva, descargar, copiar</td></tr>
              </table>
            </body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// Los favoritos, como la rejilla de la página de inicio de Safari.
    ///
    /// Los iconos van **incrustados en base64**: la página se carga sin
    /// `baseURL`, así que no hay desde dónde pedir un fichero local, y pedirlos
    /// a la red en cada pestaña nueva sería una ristra de peticiones para algo
    /// que ya está en disco.
    private static func favoritesHTML() -> String {
        let pages = AppServices.shared.history.bookmarks.prefix(12)
        guard !pages.isEmpty else { return "" }

        let items = pages.map { page -> String in
            let host = URL(string: page.url)?.host() ?? ""
            let icon: String
            if let image = AppServices.shared.favicons.icon(for: host), let data = image.pngData() {
                icon = "<img src=\"data:image/png;base64,\(data.base64EncodedString())\">"
            } else {
                let letter = host.replacingOccurrences(of: "www.", with: "").first.map(String.init)?.uppercased() ?? "·"
                icon = "<span class=\"letter\" style=\"background:\(colorHex(for: host))\">\(escape(letter))</span>"
            }
            return "<a href=\"\(escape(page.url))\">\(icon)<span>\(escape(page.title))</span></a>"
        }
        return "<div class=\"favorites\">" + items.joined() + "</div>"
    }

    /// El mismo color por dominio que usa la barra de favoritos.
    private static func colorHex(for seed: String) -> String {
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let hue = Double(hash % 360)
        return "hsl(\(Int(hue)) 55% 45%)"
    }

    /// Nada de lo que viene de una web se mete en el HTML sin escapar: un
    /// título con comillas rompería la página, y con una etiqueta dentro haría
    /// algo peor.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    func goBack() {
        readerOrigin = nil
        webView.goBack()
    }

    func goForward() {
        readerOrigin = nil
        webView.goForward()
    }

    func reload() {
        // Recargar en el lector recarga la página original: el HTML del
        // artículo no está en ningún servidor.
        if let origin = readerOrigin {
            readerOrigin = nil
            webView.load(URLRequest(url: origin))
            return
        }
        webView.reload()
    }

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
        refreshPlaybackState()
    }

    /// La dirección que se guarda para el próximo arranque: la de la página
    /// (la original, si se está en modo lectura), o `nil` en la de inicio.
    var sessionURL: URL? {
        if isSuspended { return suspendedURL }
        let url = readerOrigin ?? webView.url
        guard let url, url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    /// Una pestaña recuperada al arrancar que no se está viendo: **no carga
    /// nada** hasta que se mira, como las que se duermen. Abrir ocho webs a la
    /// vez al arrancar es justo lo que hace que iOS cierre la app.
    func prepareSuspended(at url: URL) {
        suspendedURL = url
        isSuspended = true
        title = url.host() ?? url.absoluteString
        urlText = url.absoluteString
    }

    /// Apunta que se acaba de usar: al dejar de verla, el rato sin mirarla
    /// cuenta desde aquí y no desde que se abrió.
    func markUsed() {
        lastUsed = Date()
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
        send("click", [point.x, point.y, code, Self.modifiersObject(modifiers)])
    }

    /// Hover limitado a unas 30 veces por segundo.
    ///
    /// El movimiento llega a cada fotograma de la pantalla externa. Mandarlo
    /// todo a JavaScript ahoga la página y el cursor empieza a arrastrarse.
    func hover(at point: CGPoint) {
        let now = Date()
        guard now.timeIntervalSince(lastHoverTime) > 0.033 else { return }
        // Medio punto no cambia lo que hay debajo, y cada aviso es una
        // búsqueda en la página entera.
        guard abs(point.x - lastHoverPoint.x) >= 1 || abs(point.y - lastHoverPoint.y) >= 1 else { return }
        lastHoverTime = now
        lastHoverPoint = point
        send("hover", [point.x, point.y])
    }

    func scroll(at point: CGPoint, delta: CGVector) {
        send("wheel", [point.x, point.y, -delta.dx, -delta.dy])
    }

    /// Manda una tecla a la página.
    ///
    /// Todo pasa por `__brunos.key`, que dispara `keydown`, `keypress` y
    /// `keyup` y, si la página no lo cancela, **hace a mano lo que haría el
    /// navegador**: un evento sintético no envía formularios ni borra nada por
    /// sí solo, y por eso Intro no buscaba en Google. Ver `ClickInjector.js`.
    func sendKey(_ key: UIKey) {
        let name: String? = switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: "Enter"
        case .keyboardTab: "Tab"
        case .keyboardEscape: "Escape"
        case .keyboardDeleteOrBackspace: "Backspace"
        case .keyboardDeleteForward: "Delete"
        case .keyboardUpArrow: "ArrowUp"
        case .keyboardDownArrow: "ArrowDown"
        case .keyboardLeftArrow: "ArrowLeft"
        case .keyboardRightArrow: "ArrowRight"
        case .keyboardPageUp: "PageUp"
        case .keyboardPageDown: "PageDown"
        case .keyboardHome: "Home"
        case .keyboardEnd: "End"
        default: nil
        }

        let modifiers = Self.modifiersObject(key.modifierFlags)
        if let name {
            send("key", [name, modifiers, NSNull()])
            return
        }

        let characters = key.characters
        guard !characters.isEmpty else { return }
        // Un carácter suelto va como tecla, para que lo vean los atajos de la
        // página (la espaciadora de un vídeo, la «k» de YouTube). Lo que llega
        // de golpe, como una composición de acentos, se escribe tal cual.
        if characters.count == 1 {
            send("key", [characters, modifiers, characters])
        } else {
            insertText(characters)
        }
    }

    private static func modifiersObject(_ flags: UIKeyModifierFlags) -> [String: Bool] {
        [
            "ctrl": flags.contains(.control),
            "alt": flags.contains(.alternate),
            "shift": flags.contains(.shift),
            "meta": flags.contains(.command),
        ]
    }

    /// Un texto cualquiera como literal de JavaScript, bien escapado.
    ///
    /// Se pasa por JSON en vez de escapar a mano: así no se escapa ni una
    /// comilla, ni un salto de línea, ni un separador de línea Unicode, que
    /// rompe un literal de JavaScript aunque en JSON sea válido... salvo que
    /// se escape también, que es lo que se hace.
    static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Inicio de sesión

    /// Rellena usuario y contraseña en el formulario de la página.
    ///
    /// Los valores viajan como literales de JavaScript bien escapados y **no
    /// se guardan en ningún sitio**: van de iOS a la página y ya.
    func fillLogin(username: String, password: String) {
        run("window.__brunos.fillLogin(\(Self.jsString(username)), \(Self.jsString(password)));")
    }

    // MARK: - Buscar

    /// Busca en la página con el buscador de WebKit, que resalta y lleva al
    /// resultado. Repetir la misma búsqueda va al siguiente.
    ///
    /// WebKit sólo dice si ha encontrado algo, no cuántas veces: el total se
    /// cuenta aparte en el texto de la página, sin distinguir mayúsculas, que
    /// es como busca WebKit por defecto.
    func find(_ text: String, backwards: Bool) async -> (found: Bool, count: Int) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        let found: Bool = await withCheckedContinuation { continuation in
            webView.find(text, configuration: configuration) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
        let script = """
            (function (needle) {
                const haystack = (document.body ? document.body.innerText : '').toLowerCase();
                needle = needle.toLowerCase();
                let count = 0, index = 0;
                while ((index = haystack.indexOf(needle, index)) !== -1) { count++; index += needle.length; }
                return count;
            })(\(Self.jsString(text)));
            """
        let count: Int = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: world) { result in
                if case .success(let value) = result, let number = value as? Int {
                    continuation.resume(returning: number)
                } else {
                    continuation.resume(returning: 0)
                }
            }
        }
        return (found, found ? max(count, 1) : 0)
    }

    /// Quita el resaltado de la última búsqueda.
    func clearFind() {
        run("window.getSelection().removeAllRanges();")
    }

    /// Copia lo que haya seleccionado en la página.
    func copySelection() {
        webView.evaluateJavaScript("window.getSelection().toString();", in: nil, in: world) { result in
            guard case .success(let value) = result,
                  let text = value as? String, !text.isEmpty
            else { return }
            AppServices.shared.clipboard.copy(text)
        }
    }

    func insertText(_ text: String) {
        send("insertText", [text])
    }

    /// Lo que hay bajo el cursor.
    ///
    /// Se devuelve un tipo propio y no el diccionario de JavaScript porque
    /// `[String: Any]` no es `Sendable` y Swift 6 no deja sacarlo del callback.
    struct Hit: Sendable {
        var tag: String
        var link: String?
        var image: String?
        var selection: String?
        /// `password` o `username` si es un campo de inicio de sesión.
        var login: String?
        var isEditable: Bool
        var cursor: String
    }

    // MARK: - Medios

    /// Un vídeo o un audio de la página.
    ///
    /// Se devuelve un tipo propio y no el diccionario de JavaScript por lo
    /// mismo que `Hit`: `[String: Any]` no es `Sendable`.
    struct Media: Sendable, Equatable {
        var url: URL
        var isAudio: Bool
        var fileExtension: String
        /// No es un fichero que se pueda guardar: un `blob:` de la propia
        /// pestaña o una lista de trozos (HLS, DASH).
        var isStream: Bool
        /// Por trozos, pero HLS: ése sí se baja, con `HLSDownloader`.
        var isHLS: Bool
        var width: Int
        var height: Int
        var duration: Int
        var pageTitle: String

        var symbol: String { isAudio ? "waveform" : "film" }

        /// Se puede guardar: un fichero directo, o una lista HLS.
        var isDownloadable: Bool { !isStream || isHLS }

        /// Lo que se lee en el menú: «1920×1080 · 4:12 · mp4».
        var label: String {
            var parts: [String] = []
            if width > 0, height > 0 { parts.append("\(width)×\(height)") }
            if duration > 0 {
                parts.append("\(duration / 60):" + String(format: "%02d", duration % 60))
            }
            if !fileExtension.isEmpty { parts.append(fileExtension) }
            if parts.isEmpty { parts.append(url.host() ?? "medio") }
            return parts.joined(separator: " · ")
        }

        /// El nombre del fichero: el título de la página, que es lo que uno
        /// reconoce después en Descargas, y no el `videoplayback` del servidor.
        var suggestedName: String {
            let title = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = title.isEmpty ? (url.deletingPathExtension().lastPathComponent) : title
            let clean = base
                .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
                .joined(separator: " ")
                .prefix(80)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ext = fileExtension.isEmpty || isHLS ? (isAudio ? "m4a" : "mp4") : fileExtension
            return "\(clean.isEmpty ? "vídeo" : clean).\(ext)"
        }
    }

    /// Todos los medios de la página.
    func media() async -> [Media] {
        await mediaList(from: "window.__brunos.media();")
    }

    /// El medio que hay bajo el cursor, para el clic derecho.
    func media(at point: CGPoint) async -> Media? {
        await mediaList(from: "[window.__brunos.mediaAt(\(point.x), \(point.y))].filter(Boolean);").first
    }

    private func mediaList(from script: String) async -> [Media] {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: world) { result in
                guard case .success(let value) = result,
                      let array = value as? [[String: Any]]
                else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: array.compactMap { entry in
                    guard let text = entry["url"] as? String, let url = URL(string: text) else { return nil }
                    return Media(
                        url: url,
                        isAudio: (entry["kind"] as? String) == "audio",
                        fileExtension: entry["extension"] as? String ?? "",
                        isStream: entry["stream"] as? Bool ?? false,
                        isHLS: entry["hls"] as? Bool ?? false,
                        width: entry["width"] as? Int ?? 0,
                        height: entry["height"] as? Int ?? 0,
                        duration: entry["duration"] as? Int ?? 0,
                        pageTitle: entry["title"] as? String ?? ""
                    )
                })
            }
        }
    }

    // MARK: - Modo lectura

    /// La dirección de la que salió el texto del lector, para poder volver.
    private(set) var readerOrigin: URL?
    var isReading: Bool { readerOrigin != nil }

    /// Entra o sale del modo lectura. Devuelve `false` si la página no tiene un
    /// artículo reconocible, para poder decirlo en vez de dejar la pantalla en
    /// blanco.
    @discardableResult
    func toggleReader() async -> Bool {
        if let origin = readerOrigin {
            readerOrigin = nil
            webView.load(URLRequest(url: origin))
            return true
        }
        guard let url = webView.url else { return false }

        let article: Article? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("window.__brunos.reader();", in: nil, in: world) { result in
                guard case .success(let value) = result,
                      let dictionary = value as? [String: Any],
                      let html = dictionary["html"] as? String, !html.isEmpty
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Article(
                    title: dictionary["title"] as? String ?? "",
                    byline: dictionary["byline"] as? String ?? "",
                    html: html
                ))
            }
        }
        guard let article else { return false }

        readerOrigin = url
        // **Con `baseURL` de la página original**: si no, las imágenes y los
        // enlaces del artículo se quedarían sin nada desde donde resolverse.
        webView.loadHTMLString(Self.readerHTML(article, from: url), baseURL: url)
        return true
    }

    struct Article: Sendable {
        var title: String
        var byline: String
        var html: String
    }

    /// La página del lector: una columna de texto y nada más.
    ///
    /// Sigue el modo claro u oscuro como cualquier web, con `color-scheme`, y
    /// usa una serifa para el cuerpo: en un texto largo se nota.
    private static func readerHTML(_ article: Article, from url: URL) -> String {
        let source = article.byline.isEmpty
            ? (url.host() ?? "")
            : escape(article.byline) + " · " + (url.host() ?? "")
        let style = """
            :root { color-scheme: light dark;
                    --bg: #FBF9F5; --text: #1A1D21; --muted: #6A717B; --accent: #A96B06; }
            @media (prefers-color-scheme: dark) {
              :root { --bg: #14161A; --text: #E6E3DC; --muted: #9AA1AB; --accent: #E8A33D; }
            }
            body { margin: 0 auto; padding: 48px 24px 96px; max-width: 42em;
                   background: var(--bg); color: var(--text);
                   font-family: Georgia, 'Times New Roman', serif;
                   font-size: 19px; line-height: 1.65; }
            h1.brunos-title { font-size: 34px; line-height: 1.2; margin: 0 0 6px; }
            .brunos-byline { color: var(--muted); font-size: 13px; margin-bottom: 34px;
                   font-family: -apple-system, system-ui, sans-serif;
                   padding-bottom: 18px;
                   border-bottom: 1px solid color-mix(in srgb, var(--muted) 35%, transparent); }
            img { max-width: 100%; height: auto; border-radius: 6px; }
            a { color: var(--accent); }
            pre, code { font-family: ui-monospace, monospace; font-size: 15px; }
            pre { overflow-x: auto; padding: 12px; border-radius: 8px;
                  background: color-mix(in srgb, var(--muted) 15%, transparent); }
            blockquote { margin: 0; padding-left: 18px; color: var(--muted);
                   border-left: 3px solid var(--accent); }
            figcaption { color: var(--muted); font-size: 14px; }
            """
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            + "<style>\(style)</style></head><body>"
            + "<h1 class=\"brunos-title\">\(escape(article.title))</h1>"
            + "<div class=\"brunos-byline\">\(source)</div>"
            + article.html
            + "</body></html>"
    }

    /// El icono que declara la página, para la barra de favoritos.
    private func reportIcon() {
        guard let host = webView.url?.host() else { return }
        webView.evaluateJavaScript("window.__brunos.iconURL();", in: nil, in: world) { result in
            guard case .success(let value) = result else { return }
            MainActor.assumeIsolated {
                AppServices.shared.favicons.remember(host: host, iconURL: value as? String)
            }
        }
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
                    selection: dictionary["selection"] as? String,
                    login: dictionary["login"] as? String,
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
        let controller = webView.configuration.userContentController
        controller.addUserScript(script)
        // El canal por el que se presenta cada iframe. Sólo existe en el mundo
        // de BrunOS: la página no lo ve. Con un intermediario débil, porque el
        // controlador retiene lo que se le da y la pestaña no se liberaría.
        controller.add(FrameRegistrar(tab: self), contentWorld: world, name: "brunosFrame")
        // Aviso de la página cuando aparece o arranca un vídeo. Antes el
        // panel lo preguntaba cada 3 segundos, se viera o no.
        controller.add(MediaHintRelay(tab: self), contentWorld: world, name: "brunosMedia")

        // El que pliega los huecos de lo bloqueado, en todos los marcos
        // también: los anuncios suelen ir en iframes dentro de iframes.
        if let url = Bundle.main.url(forResource: "BlockerCollapse", withExtension: "js"),
           let collapse = try? String(contentsOf: url, encoding: .utf8) {
            controller.addUserScript(WKUserScript(
                source: collapse,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: world
            ))
            controller.add(CollapseRelay(tab: self), contentWorld: world, name: "brunosCollapse")
        }

        // Los avisos de cookies: cada marco dice dónde está y Swift le mete
        // las reglas de su sitio. En su propio mundo, sin los canales de
        // BrunOS: ver `CookieNoticeBlocker`.
        controller.addUserScript(WKUserScript(
            source: """
                if (/^https?:$/.test(location.protocol) && window.webkit && window.webkit.messageHandlers.brunosCookies) {
                    window.webkit.messageHandlers.brunosCookies.postMessage(location.hostname);
                }
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: CookieNoticeBlocker.world
        ))
        controller.add(CookieRelay(tab: self), contentWorld: CookieNoticeBlocker.world, name: "brunosCookies")
    }

    /// Un marco pide las reglas de cookies de su sitio. Se mira si están
    /// apagadas para la página de arriba, que es la que sale en la barra.
    fileprivate func answerCookies(host: String, in frame: WKFrameInfo) {
        let notices = AppServices.shared.cookieNotices
        guard notices.isEnabled(for: webView.url?.host() ?? host),
              let script = notices.injection(forHost: host)
        else { return }
        webView.evaluateJavaScript(script, in: frame, in: CookieNoticeBlocker.world) { _ in }
    }

    /// `BlockerCollapse.js` pregunta si el bloqueador está encendido en esta
    /// página y cuáles de esos dominios de iframe están bloqueados enteros. Se
    /// contesta en el mismo marco que preguntó.
    fileprivate func answerCollapse(hosts: [String], in frame: WKFrameInfo) {
        let blocker = AppServices.shared.blocker
        let enabled = blocker.collapsesBlocked && blocker.isEnabled(for: webView.url?.host())
        var blocked: [String: Bool] = [:]
        for host in hosts.prefix(200) {
            blocked[host] = enabled && blocker.isBlockedHost(host)
        }
        let reply: [String: Any] = ["enabled": enabled, "blocked": blocked]
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        webView.evaluateJavaScript(
            "window.__brunosCollapse && window.__brunosCollapse.answer(\(String(decoding: data, as: UTF8.self)));",
            in: frame,
            in: world
        ) { _ in }
    }

    /// La página tiene un vídeo nuevo, o ha cambiado lo que reproduce.
    var onMediaHint: (@MainActor () -> Void)?

    fileprivate func mediaHint() {
        if isMuted { applyMute(in: nil) }
        refreshPlaybackState()
        onMediaHint?()
    }

    // MARK: - Silenciar

    /// Silencia o devuelve el sonido de la pestaña.
    ///
    /// **WebKit no tiene un «silenciar página» público** (el de Safari es
    /// privado), así que lo hace el inyector: pone `muted` a los `<video>` y
    /// `<audio>` de la página y de sus iframes, y a los que vayan apareciendo
    /// (escucha `play` y `volumechange` en captura). Al quitarlo sólo devuelve
    /// el sonido a los que silenció él: un vídeo que la página ya tenía mudo
    /// se queda mudo. Lo que suene por Web Audio no se puede callar así.
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        applyMute(in: nil)
        for frame in frames { applyMute(in: frame.info) }
        onChange?()
    }

    private func applyMute(in frame: WKFrameInfo?) {
        webView.evaluateJavaScript(
            "window.__brunos && window.__brunos.setMuted(\(isMuted));", in: frame, in: world
        ) { _ in }
    }

    /// Pregunta a WebKit si la página está reproduciendo. Se llama cuando la
    /// página avisa (`play`, `pause`, `ended`…), no con un temporizador.
    private func refreshPlaybackState() {
        guard !isSuspended else {
            if isPlayingMedia {
                isPlayingMedia = false
                onChange?()
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let state = await self.webView.requestMediaPlaybackState()
            let playing = state == .playing
            guard playing != self.isPlayingMedia else { return }
            self.isPlayingMedia = playing
            self.onChange?()
        }
    }

    // MARK: - Iframes

    /// Los iframes que se han presentado, con la dirección que tenían. Los
    /// más recientes, al final. Uno que ya no existe no molesta: WebKit
    /// devuelve error al hablarle y ya está.
    private var frames: [(info: WKFrameInfo, url: String)] = []

    fileprivate func register(_ frame: WKFrameInfo, url: String) {
        frames.removeAll { $0.url == url }
        frames.append((frame, url))
        // Un iframe que llega con la pestaña ya silenciada (un reproductor
        // incrustado que se carga tarde) nace con sonido.
        if isMuted { applyMute(in: frame) }
        if frames.count > 40 { frames.removeFirst(frames.count - 40) }
    }

    /// El iframe al que apunta el `src` que ha visto la página. Si el iframe
    /// ha navegado por dentro, su dirección ya no es la del `src`: entonces
    /// vale el último del mismo sitio.
    private func frame(for target: [String: Any]) -> WKFrameInfo? {
        let src = target["src"] as? String ?? ""
        guard !src.isEmpty else { return nil }
        if let exact = frames.last(where: { $0.url == src }) { return exact.info }
        let host = URL(string: src)?.host()
        return frames.last { host != nil && URL(string: $0.url)?.host() == host }?.info
    }

    /// Manda un evento al inyector y, si cae en un iframe, se lo pasa al del
    /// iframe con las coordenadas que ha calculado el de fuera. Anidados,
    /// tantas veces como haga falta (con un tope).
    private func send(_ operation: String, _ arguments: [Any], in frame: WKFrameInfo? = nil, depth: Int = 0) {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments) else { return }
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let script = "window.__brunos.op('\(operation)', \(json));"
        webView.evaluateJavaScript(script, in: frame, in: world) { [weak self] result in
            guard depth < 6, let self,
                  case .success(let value) = result,
                  let forward = value as? [String: Any],
                  let target = forward["frame"] as? [String: Any],
                  let next = forward["args"] as? [Any],
                  let info = self.frame(for: target)
            else { return }
            self.send(operation, next, in: info, depth: depth + 1)
        }
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
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
    }

    private func refresh() {
        title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host() ?? "Nueva pestaña")
        urlText = webView.url?.absoluteString ?? ""
        isLoading = webView.isLoading
        // Cuando no se está cargando vale 1: si no, la barra se quedaría a
        // medias al terminar una carga que se cancela.
        loadProgress = webView.isLoading ? webView.estimatedProgress : 1
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        onChange?()
    }
}

// MARK: - Delegados

extension BrowserTab: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            AppServices.shared.history.record(url: url, title: webView.title)
            // Una página nueva puede volver a ofrecer las contraseñas aunque en
            // la anterior se dijera que no.
            if let host = url.host() { AppServices.shared.passwords.reset(for: host) }
        }
        if isSuspended == false, suspendedScroll != .zero {
            webView.scrollView.setContentOffset(suspendedScroll, animated: false)
            suspendedScroll = .zero
        }
        reportIcon()
        refresh()
        // Lo que declara la página (`og:video`) ya está al terminar de cargar.
        mediaHint()
    }

    /// La página nueva empieza sin silenciar: el inyector se carga de cero.
    /// Se vuelve a poner en cuanto hay documento, antes de que termine de
    /// cargar, que es cuando arranca el vídeo que se reproduce solo.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if isMuted { applyMute(in: nil) }
        // Otra página: lo que estuviera a pantalla completa ya no existe.
        if isPageFullscreen { fullscreenRequested(false) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        refresh()
    }

    /// Los enlaces con atributo `download`, y los `blob:` que generan las webs
    /// para bajar algo que han montado ellas, se descargan.
    ///
    /// **Faltaba, y era la mitad de las descargas.** Sin esto, WebKit trata un
    /// `<a download>` como una navegación normal y el fichero se abre en la
    /// pestaña, si es que sabe abrirlo, o no pasa nada.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    /// Lo que el navegador no sabe enseñar, se descarga. Y lo que el servidor
    /// manda como adjunto, también, aunque sepa enseñarlo: un PDF con
    /// `Content-Disposition: attachment` se ha pedido para guardarlo.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
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

    /// Dónde guardar una descarga en Descargas. Nunca se pisa un fichero ya
    /// descargado: se numera, como hace cualquier navegador.
    ///
    /// `reserved` son nombres ya prometidos a descargas en curso que todavía no
    /// han escrito nada en disco (un HLS no escribe el `.mp4` hasta el final).
    static func uniqueDownloadURL(named name: String, reserved: Set<String> = []) -> URL {
        var url = downloadsDirectory.appendingPathComponent(name)
        var counter = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: url.path) || reserved.contains(url.lastPathComponent) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            url = downloadsDirectory.appendingPathComponent(numbered)
            counter += 1
        }
        return url
    }

    /// Un vídeo por trozos (HLS): no es un fichero, así que no puede ir por
    /// `startDownload`. Lo baja `HLSDownloader` con las cookies de la pestaña.
    /// Guarda un medio de la página, directo o por trozos.
    func download(_ media: Media) {
        if media.isHLS {
            downloadStream(media.url, named: media.suggestedName)
        } else {
            download(media.url, named: media.suggestedName)
        }
    }

    func downloadStream(_ url: URL, named name: String) {
        let agent = webView.customUserAgent
        Task { @MainActor in
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            // Muchas listas HLS (RedGifs) son un único MP4 fragmentado servido
            // por rangos: ése se guarda tal cual, por el camino de siempre, que
            // lleva el `Referer` y no depende de AVFoundation.
            if let file = await HLSDownloader.singleFile(behind: url, cookies: cookies, userAgent: agent) {
                download(file, named: name)
            } else {
                AppServices.shared.hls.download(url, named: name, cookies: cookies, userAgent: agent)
            }
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let preferred = preferredNames.removeValue(forKey: ObjectIdentifier(download))
        let url = Self.uniqueDownloadURL(named: preferred ?? suggestedFilename)

        let id = ObjectIdentifier(download)
        destinations[id] = url
        watchProgress(of: download)
        AppServices.shared.downloads.begin(name: url.lastPathComponent) { [weak download] in
            download?.cancel()
        }
        onDownloadChange?(url.lastPathComponent, .started)
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        progressObservations.removeValue(forKey: id)
        lastReportedFraction.removeValue(forKey: id)
        guard let url = destinations.removeValue(forKey: id) else { return }
        AppServices.shared.downloads.finish(name: url.lastPathComponent, url: url)
        onDownloadChange?(url.lastPathComponent, .finished(url))
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: any Error,
        resumeData: Data?
    ) {
        let id = ObjectIdentifier(download)
        let name = destinations.removeValue(forKey: id)?.lastPathComponent ?? ""
        progressObservations.removeValue(forKey: id)
        lastReportedFraction.removeValue(forKey: id)
        AppServices.shared.downloads.fail(name: name, reason: error.localizedDescription)
        onDownloadChange?(error.localizedDescription, .failed)
    }

    /// Sigue una descarga para poder enseñar cuánto lleva.
    ///
    /// El aviso se refresca **sólo cada punto porcentual**: `fractionCompleted`
    /// cambia con cada trozo que llega, y repintar el panel a ese ritmo se nota
    /// en el cursor.
    ///
    /// El observador de KVO puede llegar en cualquier hilo, así que sólo cruza
    /// números al actor principal, nunca el `Progress`, que no es `Sendable`.
    private func watchProgress(of download: WKDownload) {
        let id = ObjectIdentifier(download)
        progressObservations[id] = download.progress.observe(
            \.fractionCompleted,
            options: [.new]
        ) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            let done = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor [weak self] in
                guard let self, let url = self.destinations[id] else { return }
                let last = self.lastReportedFraction[id] ?? -1
                guard fraction - last >= 0.01 || fraction >= 1 else { return }
                self.lastReportedFraction[id] = fraction
                AppServices.shared.downloads.progress(
                    name: url.lastPathComponent, fraction: fraction, done: done, total: total
                )
                self.onDownloadChange?(url.lastPathComponent, .progress(fraction, done, total))
            }
        }
    }

    /// Descarga una URL a propósito: «Descargar enlace», «Guardar imagen» y
    /// «Descargar vídeo».
    ///
    /// Va por `startDownload` del propio `WKWebView` y no por `URLSession`
    /// aposta: así la petición lleva **las cookies y la sesión de la pestaña**.
    /// Un vídeo detrás de un inicio de sesión, pedido por fuera, devuelve una
    /// página de error.
    func download(_ url: URL, named name: String? = nil) {
        var request = URLRequest(url: url)
        // **De dónde viene la petición.** Muchos sitios que sirven vídeo
        // (RedGifs, Imgur, medios con CDN propio) responden 403 a un mp4
        // pedido «a pelo», para que nadie lo enlace desde fuera. Pidiéndolo
        // como lo pide la propia página —mismo `Referer`, mismo origen— el
        // servidor ve lo mismo que vería con el reproductor y lo entrega.
        if let page = webView.url, page.scheme == "http" || page.scheme == "https" {
            request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
            if let origin = page.host().map({ "\(page.scheme ?? "https")://\($0)" }) {
                request.setValue(origin, forHTTPHeaderField: "Origin")
            }
        }
        if let agent = webView.customUserAgent {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }

        webView.startDownload(using: request) { [weak self] download in
            download.delegate = self
            if let name { self?.preferredNames[ObjectIdentifier(download)] = name }
        }
    }
}

extension BrowserTab: WKUIDelegate {

    /// Los enlaces con `target=_blank` y las ventanas emergentes van a una
    /// pestaña nueva, como en cualquier navegador.
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
            if let onOpenInNewTab {
                onOpenInNewTab(url)
            } else {
                webView.load(URLRequest(url: url))
            }
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

/// Recibe los avisos de vídeo de la página, con referencia débil por lo
/// mismo que `FrameRegistrar`.
@MainActor
private final class MediaHintRelay: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // También de los iframes: un reproductor incrustado (YouTube en otra
        // web) avisa desde el suyo, y es lo que enciende el altavoz.
        tab?.mediaHint()
    }
}

/// Recibe las preguntas de `BlockerCollapse.js`, con referencia débil por lo
/// mismo que `FrameRegistrar`.
@MainActor
private final class CollapseRelay: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let hosts = (body["hosts"] as? [Any])?.compactMap { $0 as? String } ?? []
        tab?.answerCollapse(hosts: hosts, in: message.frameInfo)
    }
}

/// Recibe las peticiones de `answerCookies`, con referencia débil por lo
/// mismo que `FrameRegistrar`.
@MainActor
private final class CookieRelay: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let host = message.body as? String, !host.isEmpty else { return }
        tab?.answerCookies(host: host, in: message.frameInfo)
    }
}

/// Recibe la pantalla completa de `FullscreenBridge.js`, sólo del marco
/// principal: los iframes se lo piden al de fuera, y éste a Swift.
@MainActor
private final class FullscreenRelay: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let on = message.body as? Bool else { return }
        tab?.fullscreenRequested(on)
    }
}

/// Recibe la presentación de cada iframe. Intermediario débil: el
/// `WKUserContentController` retiene a quien se le da, y si fuera la pestaña
/// no se liberaría nunca.
@MainActor
private final class FrameRegistrar: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !message.frameInfo.isMainFrame, let url = message.body as? String else { return }
        tab?.register(message.frameInfo, url: url)
    }
}

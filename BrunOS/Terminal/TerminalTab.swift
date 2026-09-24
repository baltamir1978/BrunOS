import SwiftTerm
import UIKit

/// Una pestaña: un `TerminalView` de SwiftTerm atado a una `SSHSession`.
///
/// Hace de traductor en los dos sentidos. Lo que llega del servidor se le da
/// crudo al terminal con `feed`; lo que el terminal quiere mandar sale por el
/// delegado y va a la sesión.
/// `TerminalViewDelegate` no está declarado `@MainActor`, pero SwiftTerm lo
/// llama siempre desde la interfaz. La conformidad se marca
/// `@MainActor @preconcurrency` para decirlo explícitamente en vez de repartir
/// saltos de actor por cada método.
@MainActor
final class TerminalTab: NSObject, @preconcurrency TerminalViewDelegate {

    let host: SSHHost
    let session: SSHSession
    let terminalView: TerminalView
    /// Capa donde se pinta el resaltado de la selección.
    private let selectionLayer = CALayer()
    /// Aviso de sesión caída. Sólo existe mientras hace falta.
    private(set) var reconnectOverlay: ReconnectOverlay?

    var onTitleChange: (@MainActor () -> Void)?
    /// La sesión terminó por las buenas. El panel cierra la pestaña.
    var onEnded: (@MainActor () -> Void)?

    /// Lo que el servidor haya puesto como título, si dijo algo.
    private var remoteTitle: String?
    private var fontSize: CGFloat = TerminalTheme.fontSize {
        didSet { terminalView.font = Tokens.mono(fontSize) }
    }

    /// Estado de la sesión, para rotularlo y para saber si aceptar teclas.
    private(set) var state: SSHSession.State = .idle

    var title: String {
        switch state {
        case .connecting: "\(host.displayName) · conectando"
        case .failed: "\(host.displayName) · caída"
        default: remoteTitle ?? host.displayName
        }
    }

    init(host: SSHHost) {
        self.host = host
        self.session = SSHSession(host: host)

        var options = TerminalOptions.default
        // 10.000 líneas de scrollback, como pedía el diseño. El valor de serie
        // de SwiftTerm son 500, que para una compilación larga es nada.
        options.scrollback = 10_000
        options.termName = "xterm-256color"

        self.terminalView = TerminalView(frame: .zero, font: Tokens.mono(TerminalTheme.fontSize), options: options)
        super.init()

        terminalView.layer.addSublayer(selectionLayer)
        terminalView.terminalDelegate = self
        applyTheme(TerminalTheme.style)
        // La pantalla externa no es interactiva y el ratón se inyecta a mano,
        // así que los gestos propios de SwiftTerm sobran.
        terminalView.allowMouseReporting = true
        // Option es del terminal, no del gestor de ventanas: Meta tiene que
        // llegar a emacs y a readline.
        terminalView.optionAsMetaKey = true

        session.onOutput = { [weak self] bytes in
            self?.terminalView.feed(byteArray: bytes)
        }
        session.onStateChange = { [weak self] newState in
            self?.apply(newState)
        }
    }

    // MARK: - Sesión

    func connect() {
        session.connect()
    }

    func disconnect() {
        session.disconnect()
    }

    private func apply(_ newState: SSHSession.State) {
        state = newState
        switch newState {
        case .connecting:
            write(banner: "Conectando con \(host.host)…")
        case .connected:
            write(banner: "Conectado.")
        case .failed(let reason):
            // El fallo se escribe **dentro del terminal**, junto a lo que se
            // estaba haciendo, que muchas veces es la pista de por qué se cayó.
            // Encima va el aviso con el botón.
            write(banner: "\r\n\(reason)")
            showReconnectOverlay(reason: reason)
        case .ended:
            onEnded?()
        case .idle:
            break
        }

        if newState != .idle, case .failed = newState {} else {
            hideReconnectOverlay()
        }
        onTitleChange?()
    }

    /// Escribe un aviso en el terminal sin que haya sesión detrás.
    func showNotice(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            write(banner: String(line))
        }
    }

    private func write(banner: String) {
        terminalView.feed(text: "\r\n\u{1B}[38;2;232;163;61m\(banner)\u{1B}[0m\r\n")
    }

    private func showReconnectOverlay(reason: String) {
        let overlay = reconnectOverlay ?? ReconnectOverlay()
        overlay.onReconnect = { [weak self] in
            self?.session.connect()
        }
        overlay.update(message: reason)
        overlay.frame = terminalView.bounds
        terminalView.addSubview(overlay)
        reconnectOverlay = overlay
    }

    private func hideReconnectOverlay() {
        reconnectOverlay?.removeFromSuperview()
        reconnectOverlay = nil
    }

    // MARK: - Entrada

    func sendKey(_ key: UIKey) {
        // Con la sesión caída, Intro reconecta en vez de mandar un retorno a
        // ninguna parte.
        if case .failed = state {
            if key.keyCode == .keyboardReturnOrEnter {
                session.connect()
            }
            return
        }

        if let bytes = Self.bytes(for: key) {
            session.send(bytes)
        }
    }

    /// Traduce una tecla de UIKit a lo que espera un terminal.
    ///
    /// **Ctrl y Option no se tocan**: son del terminal. Ctrl+letra se convierte
    /// en su carácter de control, y Option antepone Escape, que es lo que
    /// entienden readline, vim y emacs.
    private static func bytes(for key: UIKey) -> ArraySlice<UInt8>? {
        let modifiers = key.modifierFlags

        if modifiers.contains(.control) {
            guard let scalar = key.charactersIgnoringModifiers.lowercased().unicodeScalars.first
            else { return nil }
            switch scalar {
            case "a"..."z":
                return ArraySlice([UInt8(scalar.value - 96)])
            case "[": return ArraySlice([0x1B])
            case "\\": return ArraySlice([0x1C])
            case "]": return ArraySlice([0x1D])
            case " ": return ArraySlice([0x00])
            default: return nil
            }
        }

        let base: [UInt8]? = switch key.keyCode {
        case .keyboardReturnOrEnter: [0x0D]
        case .keyboardDeleteOrBackspace: [0x7F]
        case .keyboardTab: [0x09]
        case .keyboardEscape: [0x1B]
        case .keyboardUpArrow: [0x1B, 0x5B, 0x41]
        case .keyboardDownArrow: [0x1B, 0x5B, 0x42]
        case .keyboardRightArrow: [0x1B, 0x5B, 0x43]
        case .keyboardLeftArrow: [0x1B, 0x5B, 0x44]
        case .keyboardHome: [0x1B, 0x5B, 0x48]
        case .keyboardEnd: [0x1B, 0x5B, 0x46]
        case .keyboardPageUp: [0x1B, 0x5B, 0x35, 0x7E]
        case .keyboardPageDown: [0x1B, 0x5B, 0x36, 0x7E]
        case .keyboardDeleteForward: [0x1B, 0x5B, 0x33, 0x7E]
        default: nil
        }

        if let base {
            return ArraySlice(base)
        }

        let characters = key.characters
        guard !characters.isEmpty else { return nil }

        var bytes = Array(characters.utf8)
        if modifiers.contains(.alternate) {
            bytes.insert(0x1B, at: 0)
        }
        return ArraySlice(bytes)
    }

    // MARK: - Ratón

    /// Texto seleccionado con el ratón, si lo hay.
    private(set) var selection: (start: Position, end: Position)?
    private var isSelecting = false

    /// Tamaño de una celda.
    ///
    /// `cellDimension` es interno en SwiftTerm, pero `getOptimalFrameSize()`
    /// es columnas × ancho de celda, así que dividiendo sale exacto. Antes se
    /// dividía el ancho de la vista, que incluye el sobrante del borde, y el
    /// error crecía hacia la derecha.
    private var cellSize: CGSize {
        let terminal = terminalView.getTerminal()
        let optimal = terminalView.getOptimalFrameSize().size
        guard terminal.cols > 0, terminal.rows > 0, optimal.width > 0 else {
            return CGSize(width: 8, height: 16)
        }
        return CGSize(
            width: optimal.width / CGFloat(terminal.cols),
            height: optimal.height / CGFloat(terminal.rows)
        )
    }

    /// Fila y columna **de la pantalla visible** bajo un punto del panel. Es
    /// lo que esperan tmux y vim en el protocolo de ratón.
    private func visiblePosition(at point: CGPoint) -> Position {
        let terminal = terminalView.getTerminal()
        let cell = cellSize
        let col = min(max(Int(point.x / cell.width), 0), max(terminal.cols - 1, 0))
        let row = min(max(Int(point.y / cell.height), 0), max(terminal.rows - 1, 0))
        return Position(col: col, row: row)
    }

    /// Fila y columna **contadas desde el principio del historial**, que es
    /// como las cuenta SwiftTerm para copiar (`getText`) y como van las capas
    /// de la vista, que es un `UIScrollView` con todo el historial dentro.
    ///
    /// Se usaban las visibles para todo, y con historial acumulado el
    /// resaltado caía lejísimos del cursor y se copiaban otras líneas, las
    /// del principio (Bruno, 24-sep-2026).
    private func position(at point: CGPoint) -> Position {
        let visible = visiblePosition(at: point)
        return Position(col: visible.col, row: visible.row + terminalView.getTerminal().getTopVisibleRow())
    }

    /// Si la aplicación remota ha pedido el ratón.
    ///
    /// tmux y vim lo activan, y entonces **los clics son suyos**: se les mandan
    /// como secuencias de escape en vez de usarlos para seleccionar. Es lo que
    /// permite pinchar una ventana de tmux o colocar el cursor en vim.
    private var remoteWantsMouse: Bool {
        terminalView.getTerminal().mouseMode != .off
    }

    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint, modifiers: UIKeyModifierFlags) {
        if let overlay = reconnectOverlay {
            if case .down = kind, overlay.hitsButton(point) {
                overlay.onReconnect?()
            }
            return
        }

        // Shift deja pasar por encima del modo ratón, como en cualquier
        // terminal: sirve para seleccionar aunque tmux esté capturando.
        if remoteWantsMouse, !modifiers.contains(.shift) {
            sendMouseEvent(kind, at: visiblePosition(at: point))
            return
        }

        let position = position(at: point)

        switch kind {
        case .down(let button) where button == .left:
            // Cmd+clic sobre un enlace lo abre, como en cualquier terminal
            // moderno. Es lo que hace falta para la URL de reautenticación que
            // enseña el modo `check` de Tailscale.
            if modifiers.contains(.command), let link = link(at: visiblePosition(at: point)) {
                open(link)
                return
            }
            isSelecting = true
            selection = (position, position)
            highlightSelection()

        case .moved where isSelecting:
            selection?.end = position
            highlightSelection()

        case .up:
            isSelecting = false

        case .scroll(let delta):
            scroll(by: delta)

        default:
            break
        }
    }

    /// Manda el clic a la aplicación remota en formato xterm.
    private func sendMouseEvent(_ kind: PointerEvent.Kind, at position: Position) {
        let terminal = terminalView.getTerminal()
        switch kind {
        case .down(let button):
            terminal.sendEvent(buttonFlags: flags(for: button), x: position.col, y: position.row)
        case .up:
            // 3 es "botón soltado" en el protocolo de xterm.
            terminal.sendEvent(buttonFlags: 3, x: position.col, y: position.row)
        case .moved where terminal.mouseMode.sendMotionEvent():
            terminal.sendMotion(
                buttonFlags: 32, x: position.col, y: position.row,
                pixelX: 0, pixelY: 0
            )
        case .scroll(let delta):
            // 64 arriba, 65 abajo, que es como xterm codifica la rueda. Con el
            // mismo sentido que el scroll del historial (ver `scroll(by:)`).
            let flags = delta.dy < 0 ? 65 : 64
            terminal.sendEvent(buttonFlags: flags, x: position.col, y: position.row)
        default:
            break
        }
    }

    private func flags(for button: PointerEvent.Button) -> Int {
        switch button {
        case .left: 0
        case .middle: 1
        case .right: 2
        }
    }

    /// Enlace bajo una posición, si lo hay.
    private func link(at position: Position) -> String? {
        // `.screen` y no `.buffer`: la posición viene de un clic en lo que se
        // está viendo, no de una fila absoluta del historial.
        //
        // `.explicitAndImplicit` para que detecte también las URLs escritas a
        // pelo, sin secuencia de hiperenlace. Es el caso de la URL de
        // reautenticación que suelta el modo `check` de Tailscale.
        terminalView.getTerminal().link(
            at: .screen(position),
            mode: .explicitAndImplicit
        )
    }

    private func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        Self.open(url)
    }

    /// Las páginas web, al navegador de BrunOS, en una pestaña nueva: es el
    /// que está en el monitor. Safari sólo cuando no hay escritorio (sin
    /// monitor) o para lo que no es una web (`mailto:`, `tel:`…), que el
    /// navegador propio no sabría abrir.
    static func open(_ url: URL) {
        let isWeb = url.scheme == "http" || url.scheme == "https"
        if isWeb, let desktop = AppServices.shared.desktopViewController {
            desktop.openInBrowser(url)
        } else {
            UIApplication.shared.open(url)
        }
    }

    /// Dibuja el resaltado de la selección.
    ///
    /// Se pinta con capas propias y no con la selección de SwiftTerm porque su
    /// `selection` es interna y no hay forma pública de moverla desde fuera.
    private func highlightSelection() {
        selectionLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let selection else { return }

        let (start, end) = ordered(selection)
        let cell = cellSize

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in start.row...end.row {
            let fromCol = row == start.row ? start.col : 0
            let toCol = row == end.row ? end.col : terminalView.getTerminal().cols - 1
            guard toCol >= fromCol else { continue }

            let band = CALayer()
            band.frame = CGRect(
                x: CGFloat(fromCol) * cell.width,
                y: CGFloat(row) * cell.height,
                width: CGFloat(toCol - fromCol + 1) * cell.width,
                height: cell.height
            )
            band.backgroundColor = Tokens.Color.accent.withAlphaComponent(0.30).desktopCGColor
            selectionLayer.addSublayer(band)
        }
        CATransaction.commit()
    }

    /// De arriba abajo y de izquierda a derecha, aunque se arrastrara al revés.
    private func ordered(_ selection: (start: Position, end: Position)) -> (Position, Position) {
        let (a, b) = selection
        if a.row < b.row || (a.row == b.row && a.col <= b.col) {
            return (a, b)
        }
        return (b, a)
    }

    func clearSelection() {
        selection = nil
        selectionLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    /// El contenido se mueve **al revés que el evento**, como en el
    /// navegador, Ficheros y Ajustes (`-delta.dy`): así la dirección natural o
    /// inversa de Ajustes vale igual en todos. El terminal lo hacía al
    /// derecho y quedaba justo al contrario que el resto (Bruno, 24-sep-2026).
    func scroll(by delta: CGVector) {
        // Tres líneas por muesca, como cualquier terminal.
        let lines = Int((-delta.dy / 10).rounded())
        guard lines != 0 else { return }
        terminalView.scrollDown(lines: lines)
    }

    /// Copia lo seleccionado. Cmd+C.
    ///
    /// Si no hay nada seleccionado **no se copia nada**, en vez de copiar la
    /// pantalla entera: en un terminal, un Cmd+C que se lleve todo por error es
    /// peor que uno que no haga nada.
    func copySelection() {
        guard let selection else { return }
        let (start, end) = ordered(selection)
        let text = terminalView.getTerminal().getText(start: start, end: end)
        guard !text.isEmpty else { return }
        AppServices.shared.clipboard.copy(text)
    }

    // MARK: - Tamaño de la fuente

    func changeFontSize(by delta: CGFloat) {
        fontSize = min(max(fontSize + delta, 8), 32)
    }

    func resetFontSize() {
        fontSize = TerminalTheme.fontSize
    }

    // MARK: - Buscar

    /// Busca en lo que hay en pantalla y en el historial, y devuelve «n de m».
    /// SwiftTerm selecciona el resultado y lleva el scroll hasta él.
    func find(_ text: String, backwards: Bool, restart: Bool) -> (index: Int, total: Int) {
        if restart { terminalView.clearSearch() }
        if backwards {
            terminalView.findPrevious(text)
        } else {
            terminalView.findNext(text)
        }
        return terminalView.searchMatchSummary(text)
    }

    func clearFind() {
        terminalView.clearSearch()
    }

    // MARK: - Tema

    /// Colores ya resueltos, nunca dinámicos.
    ///
    /// **SwiftTerm convierte el `UIColor` a su formato en el momento** y no se
    /// entera después de un cambio de modo. Antes se le pasaba el texto
    /// dinámico del escritorio con el fondo fijo en negro: en modo claro salía
    /// texto casi negro sobre negro.
    func applyTheme(_ style: UIUserInterfaceStyle) {
        terminalView.installColors(TerminalTheme.palette(for: style))
        terminalView.nativeBackgroundColor = TerminalTheme.background(for: style)
        terminalView.nativeForegroundColor = TerminalTheme.foreground(for: style)
        terminalView.overrideUserInterfaceStyle = style
        reconnectOverlay?.backgroundColor = TerminalTheme.background(for: style).withAlphaComponent(0.82)
        terminalView.setNeedsDisplay()
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session.send(data)
    }

    /// El terminal avisa de cuántas filas y columnas caben ahora.
    ///
    /// Es de donde sale el `window-change` que hace que vim y tmux se
    /// recoloquen en vez de pintar sobre una cuadrícula que ya no existe.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session.resize(cols: newCols, rows: newRows)
        // En el origen del contenido, no en `bounds`: la vista es un
        // `UIScrollView` y el origen de `bounds` es por dónde va el scroll.
        // Las bandas van en filas del historial, contadas desde arriba del
        // todo; con la capa movida, caían desplazadas.
        selectionLayer.frame = CGRect(origin: .zero, size: source.bounds.size)
        reconnectOverlay?.frame = source.bounds
        // Una selección hecha con otro tamaño ya no señala lo mismo.
        clearSelection()
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        remoteTitle = title.isEmpty ? nil : title
        onTitleChange?()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // El modo `check` de Tailscale pide reautenticarse con una URL. Abrirla
        // es justo lo que hay que poder hacer sin salir del terminal.
        guard let url = URL(string: link) else { return }
        Self.open(url)
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        AppServices.shared.clipboard.copy(text)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

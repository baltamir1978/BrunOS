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

    var onTitleChange: (@MainActor () -> Void)?

    /// Lo que el servidor haya puesto como título, si dijo algo.
    private var remoteTitle: String?
    private var fontSize: CGFloat = 13 {
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

        self.terminalView = TerminalView(frame: .zero, font: Tokens.mono(13), options: options)
        super.init()

        terminalView.terminalDelegate = self
        terminalView.nativeBackgroundColor = Tokens.Color.terminalBackground
        terminalView.nativeForegroundColor = Tokens.Color.text
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
            // El fallo se escribe **dentro del terminal** en vez de en un
            // diálogo: así queda junto a lo que se estaba haciendo y no tapa
            // nada. Intro vuelve a intentarlo.
            write(banner: "\r\n\(reason)\r\nPulsa Intro para reconectar.")
        case .idle:
            break
        }
        onTitleChange?()
    }

    private func write(banner: String) {
        terminalView.feed(text: "\r\n\u{1B}[38;2;232;163;61m\(banner)\u{1B}[0m\r\n")
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

    func scroll(by delta: CGVector) {
        // Tres líneas por muesca, como cualquier terminal.
        let lines = Int((delta.dy / 10).rounded())
        guard lines != 0 else { return }
        terminalView.scrollDown(lines: lines)
    }

    func beginSelection(at point: CGPoint) {}
    func extendSelection(to point: CGPoint) {}
    func endSelection() {}

    func copySelection() {
        guard let selection = terminalView.getSelection(), !selection.isEmpty else { return }
        UIPasteboard.general.string = selection
    }

    // MARK: - Tamaño de la fuente

    func changeFontSize(by delta: CGFloat) {
        fontSize = min(max(fontSize + delta, 8), 32)
    }

    func resetFontSize() {
        fontSize = 13
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
        UIApplication.shared.open(url)
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        UIPasteboard.general.string = text
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

import UIKit

/// Los tres tipos de panel que tendrá BrunOS.
enum PaneKind: String, CaseIterable, Sendable {
    case terminal
    case browser
    case files

    /// De qué tipo es un panel ya creado. Lo usa el dock para dibujar el
    /// icono de los minimizados.
    @MainActor
    static func of(_ pane: any Pane) -> PaneKind {
        switch pane {
        case is TerminalPane: .terminal
        case is BrowserPane: .browser
        case is FilesPane: .files
        case let placeholder as PlaceholderPane: placeholder.kind
        default: .terminal
        }
    }

    /// El orden de los iconos del dock: el de siempre, web · ssh · ficheros.
    static let dockOrder: [PaneKind] = [.browser, .terminal, .files]

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .browser: "Navegador"
        case .files: "Ficheros"
        }
    }

    /// Icono del dock. Símbolos del sistema: se ven nítidos a cualquier escala
    /// y no hay que dibujar ni mantener nada.
    var symbol: String {
        switch self {
        case .terminal: "apple.terminal.fill"
        case .browser: "globe"
        case .files: "folder.fill"
        }
    }
}

/// Panel de relleno con el que se construye y se prueba el gestor de ventanas
/// antes de que existan el terminal, el navegador y los ficheros.
///
/// **Es andamio de la Fase 1**: lo sustituyen `TerminalPane` (Fase 2),
/// `BrowserPane` (Fase 3) y `FilesPane` (Fase 4). No hace nada útil, pero sí
/// todo lo que el mosaico necesita: se pinta, se entera del foco y acusa recibo
/// del puntero y del teclado, que es justo lo que hay que poder comprobar.
@MainActor
final class PlaceholderPane: UIView, Pane {

    let kind: PaneKind
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private var lastEvent = "sin eventos"
    /// Posición del ratón dentro del panel. Se rotula siempre, aunque no haya
    /// pasado nada más: es la única forma de ver de un vistazo, y desde el otro
    /// lado de la habitación, si el puntero llega hasta aquí.
    private var pointerText = "ratón: no ha entrado"

    var title: String { kind.title }
    var view: UIView { self }

    init(kind: PaneKind) {
        self.kind = kind
        super.init(frame: .zero)

        backgroundColor = kind == .terminal
            ? TerminalTheme.background(for: TerminalTheme.style)
            : Tokens.Color.panel
        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = Tokens.Metric.focusBorderWidth
        layer.borderColor = Tokens.Color.border.desktopCGColor
        clipsToBounds = true

        titleLabel.font = Tokens.mono(15, bold: true)
        titleLabel.textColor = Tokens.Color.textSecondary
        titleLabel.text = kind.title

        bodyLabel.font = Tokens.mono(12)
        bodyLabel.textColor = Tokens.Color.textSecondary
        bodyLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])

        refreshBody()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    func isDragArea(_ point: CGPoint) -> Bool {
        point.y < 30
    }

    func setFocused(_ focused: Bool) {
        layer.borderColor = focused
            ? Tokens.Color.accent.desktopCGColor
            : Tokens.Color.border.desktopCGColor
        titleLabel.textColor = focused ? Tokens.Color.accent : Tokens.Color.textSecondary
    }

    func handlePointer(_ event: PointerEvent) {
        pointerText = "ratón: \(Int(event.location.x)),\(Int(event.location.y))"

        switch event.kind {
        case .moved:
            // El movimiento no se apunta como "último evento", que se llenaría
            // de ruido, pero sí refresca la posición de arriba.
            refreshBody()
            return
        case .down(let button):
            lastEvent = "ratón abajo (\(button)) en \(Int(event.location.x)),\(Int(event.location.y))"
        case .up(let button):
            lastEvent = "ratón arriba (\(button))"
        case .scroll(let delta):
            lastEvent = "scroll \(Int(delta.dx)),\(Int(delta.dy))"
        }
        refreshBody()
    }

    func handleKey(_ event: KeyEvent) {
        guard event.phase == .down else { return }
        let characters = event.key.charactersIgnoringModifiers
        lastEvent = characters.isEmpty
            ? "tecla \(event.key.keyCode.rawValue)"
            : "tecla “\(characters)”"
        refreshBody()
    }

    func insertText(_ text: String) {
        lastEvent = "texto “\(text.prefix(40))”"
        refreshBody()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshBody()
    }

    private func refreshBody() {
        bodyLabel.text = """
            \(Int(bounds.width))×\(Int(bounds.height)) lógicos
            \(pointerText)
            \(lastEvent)
            """
    }
}

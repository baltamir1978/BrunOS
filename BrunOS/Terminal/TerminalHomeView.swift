import UIKit

/// Lo que enseña el terminal antes de conectarse: las máquinas y un botón para
/// cada una.
///
/// **Antes conectaba solo** a la primera máquina en cuanto se abría el panel.
/// Con una era cómodo; con varias, o cuando no se quería conectar todavía,
/// obligaba a cerrar lo que se había abierto sin pedirlo. Ahora es como la
/// página de pestaña nueva de un navegador: se elige, y Cmd+T vuelve a ella.
///
/// Como todo en la pantalla externa, se dibuja y se resuelve por geometría.
@MainActor
final class TerminalHomeView: UIView {

    /// Conectar a una máquina.
    var onConnect: ((SSHHost) -> Void)?

    private var hosts: [SSHHost] = []
    private var selectedIndex = 0
    private var hovered: Target?
    private var targets: [(Target, CGRect)] = []

    private enum Target: Equatable {
        case host(Int)
        case add
        case settings
    }

    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        reload()

        observer = NotificationCenter.default.addObserver(
            forName: HostStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        hosts = AppServices.shared.hosts.hosts
        selectedIndex = min(selectedIndex, max(hosts.count - 1, 0))
        setNeedsLayout()
        setNeedsDisplay()
    }

    // MARK: - Maquetación

    private static let cardHeight: CGFloat = 60

    override func layoutSubviews() {
        super.layoutSubviews()
        recompute()
        setNeedsDisplay()
    }

    private var column: CGRect {
        let width = min(bounds.width - 48, 560)
        let listHeight = CGFloat(max(hosts.count, 1)) * (Self.cardHeight + 10) + 150
        let top = max(28, (bounds.height - listHeight) / 2)
        return CGRect(x: (bounds.width - width) / 2, y: top, width: width, height: listHeight)
    }

    private func recompute() {
        targets = []
        let column = self.column
        var y = column.minY + 74
        for index in hosts.indices {
            targets.append((.host(index), CGRect(x: column.minX, y: y, width: column.width, height: Self.cardHeight)))
            y += Self.cardHeight + 10
        }
        if hosts.isEmpty { y += 40 }
        let buttonY = y + 8
        let addWidth: CGFloat = hosts.isEmpty ? 180 : 150
        targets.append((.add, CGRect(x: column.minX, y: buttonY, width: addWidth, height: 32)))
        targets.append((.settings, CGRect(x: column.minX + addWidth + 10, y: buttonY, width: 170, height: 32)))
    }

    // MARK: - Dibujo

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let column = self.column

        ("Conexiones" as NSString).draw(
            at: CGPoint(x: column.minX, y: column.minY),
            withAttributes: [
                .font: Tokens.sans(22, weight: .semibold),
                .foregroundColor: Tokens.Color.text,
            ]
        )
        let subtitle = hosts.isEmpty
            ? "Todavía no hay ninguna máquina. Añade la primera para conectarte por SSH."
            : "Elige una máquina. Flechas e Intro también valen; Cmd+T vuelve aquí."
        (subtitle as NSString).draw(
            in: CGRect(x: column.minX, y: column.minY + 32, width: column.width, height: 36),
            withAttributes: [
                .font: Tokens.sans(13),
                .foregroundColor: Tokens.Color.textSecondary,
            ]
        )

        for (target, frame) in targets {
            switch target {
            case .host(let index):
                drawHost(hosts[index], in: frame, selected: index == selectedIndex,
                         hovered: hovered == target, context: context)
            case .add:
                drawButton(hosts.isEmpty ? "Añadir máquina" : "Nueva máquina", symbol: "plus",
                           in: frame, accent: hosts.isEmpty, hovered: hovered == target, context: context)
            case .settings:
                drawButton("Ajustes del terminal", symbol: "gearshape", in: frame, accent: false,
                           hovered: hovered == target, context: context)
            }
        }
    }

    private func drawHost(_ host: SSHHost, in frame: CGRect, selected: Bool, hovered: Bool, context: CGContext) {
        let path = UIBezierPath(roundedRect: frame, cornerRadius: 10)
        context.setFillColor((hovered
            ? Tokens.Color.panelElevated
            : Tokens.Color.panel).cgColor(for: traitCollection.userInterfaceStyle))
        context.addPath(path.cgPath)
        context.fillPath()
        context.setStrokeColor((selected
            ? Tokens.Color.accent
            : Tokens.Color.border).cgColor(for: traitCollection.userInterfaceStyle))
        context.setLineWidth(selected ? 1.5 : 1)
        context.addPath(UIBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10).cgPath)
        context.strokePath()

        drawSymbol(host.authentication == .tailscale ? "network" : "desktopcomputer",
                   at: CGPoint(x: frame.minX + 26, y: frame.midY), size: 17, color: Tokens.Color.accent)

        (host.displayName as NSString).draw(
            at: CGPoint(x: frame.minX + 50, y: frame.minY + 11),
            withAttributes: [
                .font: Tokens.sans(15, weight: .medium),
                .foregroundColor: Tokens.Color.text,
            ]
        )
        ("\(host.username)@\(host.host):\(host.port) · \(host.authentication.label)" as NSString).draw(
            at: CGPoint(x: frame.minX + 50, y: frame.minY + 33),
            withAttributes: [
                .font: Tokens.mono(11),
                .foregroundColor: Tokens.Color.textSecondary,
            ]
        )

        let button = CGRect(x: frame.maxX - 104, y: frame.midY - 14, width: 90, height: 28)
        context.setFillColor(Tokens.Color.accent.withAlphaComponent(hovered || selected ? 1 : 0.9)
            .cgColor(for: traitCollection.userInterfaceStyle))
        context.addPath(UIBezierPath(roundedRect: button, cornerRadius: 7).cgPath)
        context.fillPath()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(12.5, weight: .semibold),
            .foregroundColor: Tokens.Color.background,
        ]
        let size = ("Conectar" as NSString).size(withAttributes: attributes)
        ("Conectar" as NSString).draw(
            at: CGPoint(x: button.midX - size.width / 2, y: button.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawButton(
        _ title: String,
        symbol: String,
        in frame: CGRect,
        accent: Bool,
        hovered: Bool,
        context: CGContext
    ) {
        let style = traitCollection.userInterfaceStyle
        let path = UIBezierPath(roundedRect: frame, cornerRadius: 8).cgPath
        if accent {
            context.setFillColor(Tokens.Color.accent.withAlphaComponent(hovered ? 0.85 : 1).cgColor(for: style))
            context.addPath(path)
            context.fillPath()
        } else {
            context.setFillColor((hovered ? Tokens.Color.panelElevated : Tokens.Color.panel).cgColor(for: style))
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(Tokens.Color.border.cgColor(for: style))
            context.setLineWidth(1)
            context.addPath(UIBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 8).cgPath)
            context.strokePath()
        }
        let color = accent ? Tokens.Color.background : Tokens.Color.text
        drawSymbol(symbol, at: CGPoint(x: frame.minX + 18, y: frame.midY), size: 11, color: color)
        (title as NSString).draw(
            at: CGPoint(x: frame.minX + 32, y: frame.midY - 8.5),
            withAttributes: [
                .font: Tokens.sans(12.5, weight: .medium),
                .foregroundColor: color,
            ]
        )
    }

    private func drawSymbol(_ name: String, at center: CGPoint, size: CGFloat, color: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let image = UIImage.crispSymbol(name, configuration: configuration, scale: layer.contentsScale)?
            .withTintColor(color.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        else { return }
        image.draw(at: CGPoint(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2))
    }

    // MARK: - Entrada

    func handlePointer(_ event: PointerEvent) {
        let target = targets.first { $0.1.contains(event.location) }?.0
        switch event.kind {
        case .moved:
            if hovered != target {
                hovered = target
                setNeedsDisplay()
            }
        case .down(let button) where button == .left:
            activate(target)
        default:
            break
        }
    }

    private func activate(_ target: Target?) {
        switch target {
        case .host(let index):
            selectedIndex = index
            onConnect?(hosts[index])
        case .add:
            AppServices.shared.desktopViewController?.presentHostEditor(for: nil)
        case .settings:
            AppServices.shared.desktopViewController?.presentSettings(.terminal)
        case nil:
            break
        }
    }

    func handleKey(_ event: KeyEvent) {
        guard event.phase == .down, !hosts.isEmpty else { return }
        switch event.key.keyCode {
        case .keyboardUpArrow:
            selectedIndex = max(0, selectedIndex - 1)
            setNeedsDisplay()
        case .keyboardDownArrow:
            selectedIndex = min(hosts.count - 1, selectedIndex + 1)
            setNeedsDisplay()
        case .keyboardReturnOrEnter:
            activate(.host(selectedIndex))
        default:
            break
        }
    }
}

import UIKit

/// Dock del escritorio: los tres espacios de trabajo, abajo y al centro.
///
/// Sustituye a las tres etiquetas de la barra superior. El motivo es de uso, no
/// de adorno: `1 web · 2 ssh · 3 files` en una esquina se lee como un rótulo de
/// estado, no como algo que se pueda pulsar, y además obligaba a subir el ratón
/// hasta arriba del todo, que con el tope del puntero indirecto es justo el
/// movimiento más incómodo.
///
/// **No recibe eventos del sistema.** Como el resto de la pantalla externa, el
/// escritorio le pregunta por geometría qué hay bajo el cursor.
@MainActor
final class Dock: UIView {

    /// Alto del dock en puntos lógicos, sin contar el margen de abajo.
    static let height: CGFloat = 58
    static let bottomMargin: CGFloat = 10

    private var items: [DockItem] = []
    private let background = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        background.backgroundColor = Tokens.Color.panelElevated.withAlphaComponent(0.72)
        background.layer.cornerRadius = 16
        background.layer.borderWidth = 1
        background.layer.borderColor = Tokens.Color.border.withAlphaComponent(0.8).cgColor
        background.layer.shadowColor = UIColor.black.cgColor
        background.layer.shadowOpacity = 0.35
        background.layer.shadowRadius = 12
        background.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(background)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Contenido

    func update(desktop: DesktopModel) {
        if items.count != desktop.workspaces.count {
            items.forEach { $0.removeFromSuperview() }
            items = desktop.workspaces.map { workspace in
                let item = DockItem(workspace: workspace)
                background.addSubview(item)
                return item
            }
        }

        for (index, item) in items.enumerated() {
            item.update(
                workspace: desktop.workspaces[index],
                isActive: index == desktop.activeIndex
            )
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !items.isEmpty else { return }

        let itemSize: CGFloat = 42
        let spacing: CGFloat = 10
        let padding: CGFloat = 10
        let contentWidth = CGFloat(items.count) * itemSize + CGFloat(items.count - 1) * spacing
        let width = contentWidth + padding * 2

        background.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: 0,
            width: width,
            height: Self.height
        )

        for (index, item) in items.enumerated() {
            item.frame = CGRect(
                x: padding + CGFloat(index) * (itemSize + spacing),
                y: (Self.height - itemSize) / 2,
                width: itemSize,
                height: itemSize
            )
        }
    }

    /// Qué espacio hay bajo un punto en coordenadas del dock.
    func workspaceNumber(at point: CGPoint) -> Int? {
        for (index, item) in items.enumerated() {
            let frame = item.convert(item.bounds, to: self)
            if frame.insetBy(dx: -4, dy: -4).contains(point) {
                return index + 1
            }
        }
        return nil
    }

    /// Si el punto cae en el dock, para que el escritorio se trague el evento.
    func contains(point: CGPoint) -> Bool {
        background.frame.contains(point)
    }
}

/// Un icono del dock.
@MainActor
private final class DockItem: UIView {

    private let iconLabel = UILabel()
    private let indicator = UIView()

    init(workspace: Workspace) {
        super.init(frame: .zero)

        layer.cornerRadius = 11
        iconLabel.textAlignment = .center
        iconLabel.font = Tokens.mono(17, bold: true)
        addSubview(iconLabel)

        // Punto debajo del espacio activo, como el del Dock de macOS.
        indicator.backgroundColor = Tokens.Color.accent
        indicator.layer.cornerRadius = 2
        addSubview(indicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    func update(workspace: Workspace, isActive: Bool) {
        // Una inicial, no un número: `1 2 3` en un dock no dice nada, y la
        // letra se reconoce de un vistazo.
        iconLabel.text = workspace.name.prefix(1).uppercased()
        iconLabel.textColor = isActive ? Tokens.Color.background : Tokens.Color.textSecondary
        backgroundColor = isActive
            ? Tokens.Color.accent
            : Tokens.Color.panel.withAlphaComponent(0.9)
        indicator.isHidden = !isActive
        // Un espacio con paneles se distingue de uno vacío.
        layer.borderWidth = workspace.isEmpty ? 0 : 1
        layer.borderColor = Tokens.Color.border.cgColor
        accessibilityLabel = "Espacio \(workspace.index), \(workspace.name)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        iconLabel.frame = bounds
        indicator.frame = CGRect(x: bounds.midX - 7, y: bounds.maxY + 3, width: 14, height: 3)
    }
}

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

    /// Qué hacer al pulsar el icono de ajustes.
    var onSettings: (() -> Void)?

    private var items: [DockItem] = []
    private var settingsItem: DockItem?
    private let separator = UIView()
    private let background = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        background.backgroundColor = Tokens.Color.panelElevated.withAlphaComponent(0.72)
        background.layer.cornerRadius = 16
        background.layer.borderWidth = 1
        background.setThemedBorder(Tokens.Color.border.withAlphaComponent(0.8))
        background.layer.shadowColor = UIColor.black.cgColor
        background.layer.shadowOpacity = 0.35
        background.layer.shadowRadius = 12
        background.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(background)

        separator.backgroundColor = Tokens.Color.border
        background.addSubview(separator)

        // Los ajustes también desde el monitor: con el trackpad a pantalla
        // completa, ir a buscarlos al iPhone es incómodo, y a veces ni siquiera
        // se está mirando el teléfono.
        let settings = DockItem()
        settings.updateAsSettings()
        background.addSubview(settings)
        settingsItem = settings
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    /// Vuelve a pintar el borde, que es un `CGColor` y no cambia solo de modo.
    func applyTheme() {
        background.setThemedBorder(Tokens.Color.border.withAlphaComponent(0.8))
    }

    // MARK: - Contenido

    func update(desktop: DesktopModel) {
        if items.count != desktop.workspaces.count {
            items.forEach { $0.removeFromSuperview() }
            items = desktop.workspaces.map { _ in
                let item = DockItem()
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
        settingsItem?.updateAsSettings()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !items.isEmpty else { return }

        let itemSize: CGFloat = 44
        let spacing: CGFloat = 10
        let padding: CGFloat = 10
        let separatorWidth: CGFloat = 1
        let separatorGap: CGFloat = 10

        let count = CGFloat(items.count)
        let contentWidth = count * itemSize + (count - 1) * spacing
            + separatorGap * 2 + separatorWidth + itemSize
        let width = contentWidth + padding * 2

        background.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: 0,
            width: width,
            height: Self.height
        )

        var x = padding
        for item in items {
            item.frame = CGRect(
                x: x, y: (Self.height - itemSize) / 2,
                width: itemSize, height: itemSize
            )
            x += itemSize + spacing
        }

        x += separatorGap - spacing
        separator.frame = CGRect(
            x: x, y: (Self.height - itemSize) / 2 + 6,
            width: separatorWidth, height: itemSize - 12
        )
        x += separatorWidth + separatorGap

        settingsItem?.frame = CGRect(
            x: x, y: (Self.height - itemSize) / 2,
            width: itemSize, height: itemSize
        )
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

    /// Si el punto cae en el icono de ajustes.
    func hitsSettings(_ point: CGPoint) -> Bool {
        guard let settingsItem else { return false }
        let frame = settingsItem.convert(settingsItem.bounds, to: self)
        return frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    /// Si el punto cae en el dock, para que el escritorio se trague el evento.
    func contains(point: CGPoint) -> Bool {
        background.frame.contains(point)
    }
}

/// Un icono del dock.
///
/// Lleva símbolo del sistema y no una letra: `W S F` en un dock no dice nada y
/// obliga a traducir mentalmente cada vez. Un globo, una consola y una carpeta
/// se reconocen sin pensar.
@MainActor
private final class DockItem: UIView {

    private let iconView = UIImageView()
    private let indicator = UIView()

    init() {
        super.init(frame: .zero)

        layer.cornerRadius = 11
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = Tokens.Color.textSecondary
        addSubview(iconView)

        // Punto debajo de las apps abiertas, como el Dock de macOS: ámbar la
        // que se está viendo, gris las demás.
        indicator.layer.cornerRadius = 2.5
        addSubview(indicator)

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    private var kind: PaneKind?
    private var isSettings = false

    func update(workspace: Workspace, isActive: Bool) {
        kind = PaneKind.allCases.first { $0.preferredWorkspace == workspace.index }
        isSettings = false
        // «Abierta» incluye lo minimizado: sus paneles siguen vivos en el dock.
        // Un icono a color siempre; lo que dice si hay algo abierto es el
        // punto. Antes los espacios vacíos salían en gris, y parecían
        // desactivados.
        let isOpen = !workspace.isEmpty || !workspace.minimized.isEmpty
        indicator.isHidden = !isOpen
        indicator.backgroundColor = isActive ? Tokens.Color.accent : Tokens.Color.textSecondary
        alpha = 1
        accessibilityLabel = "Espacio \(workspace.index), \(workspace.name)"
        refreshIcon()
    }

    func updateAsSettings() {
        isSettings = true
        kind = nil
        indicator.isHidden = true
        alpha = 1
        accessibilityLabel = "Ajustes"
        refreshIcon()
    }

    private func refreshIcon() {
        let side = max(bounds.width, 44)
        iconView.image = isSettings
            ? DockIcon.settingsImage(size: side)
            : kind.map { DockIcon.image(for: $0, size: side) }
        // El icono ya trae su propio fondo: aquí no hace falta ninguno.
        backgroundColor = .clear
        layer.borderWidth = 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        iconView.frame = bounds
        indicator.frame = CGRect(x: bounds.midX - 2.5, y: bounds.maxY + 3, width: 5, height: 5)
        refreshIcon()
    }
}

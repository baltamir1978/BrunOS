import UIKit

/// Dock del escritorio: un icono por app, abajo y al centro, como en macOS.
///
/// Cada icono es una **app**, no un espacio de trabajo: pulsarlo trae sus
/// ventanas al escritorio en que se está, junto a las de las otras apps.
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
    /// **Transparencia de verdad**, como el Dock de macOS: lo de detrás se ve
    /// desenfocado. Encima, un tinte suave del color de los paneles para que
    /// los iconos no se pierdan sobre un fondo claro (Bruno, 24-sep-2026).
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let tint = UIView()
    /// El nombre de la app bajo el cursor, encima de su icono, como en macOS.
    private let tooltip = UILabel()

    // MARK: - Agrandamiento

    /// Tamaño normal de un icono y cuánto crece el que está bajo el cursor.
    private static let itemSize: CGFloat = 44
    /// **Sutil**: Bruno no lo quería enorme (24-sep-2026); la primera versión
    /// llegaba a ×1,6.
    private static let maxScale: CGFloat = 1.25
    /// Hasta dónde llega el efecto a cada lado, en iconos.
    private static let reach: CGFloat = 2
    private static let spacing: CGFloat = 10
    private static let padding: CGFloat = 10
    private static let separatorGap: CGFloat = 10

    /// Dónde está el cursor, en x del dock, si está encima.
    private var hoverX: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Los iconos agrandados salen por encima de la barra.
        clipsToBounds = false

        background.layer.cornerRadius = 16
        background.layer.borderWidth = 1
        background.setThemedBorder(Tokens.Color.border.withAlphaComponent(0.6))
        background.layer.shadowColor = UIColor.black.cgColor
        background.layer.shadowOpacity = 0.3
        background.layer.shadowRadius = 14
        background.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(background)

        blur.layer.cornerRadius = 16
        blur.clipsToBounds = true
        background.addSubview(blur)
        tint.backgroundColor = Tokens.Color.panelElevated.withAlphaComponent(0.35)
        tint.layer.cornerRadius = 16
        background.addSubview(tint)

        separator.backgroundColor = Tokens.Color.border
        addSubview(separator)

        // Los ajustes también desde el monitor: con el trackpad a pantalla
        // completa, ir a buscarlos al iPhone es incómodo, y a veces ni siquiera
        // se está mirando el teléfono.
        let settings = DockItem()
        settings.updateAsSettings()
        addSubview(settings)
        settingsItem = settings

        tooltip.font = Tokens.sans(12.5, weight: .medium)
        tooltip.textColor = Tokens.Color.text
        tooltip.textAlignment = .center
        tooltip.backgroundColor = Tokens.Color.panelElevated.withAlphaComponent(0.92)
        tooltip.layer.cornerRadius = 7
        tooltip.layer.masksToBounds = true
        tooltip.alpha = 0
        addSubview(tooltip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    /// Vuelve a pintar el borde, que es un `CGColor` y no cambia solo de modo.
    func applyTheme() {
        background.setThemedBorder(Tokens.Color.border.withAlphaComponent(0.6))
    }

    // MARK: - Contenido

    func update(desktop: DesktopModel) {
        let kinds = PaneKind.dockOrder
        if items.count != kinds.count {
            items.forEach { $0.removeFromSuperview() }
            items = kinds.map { _ in
                let item = DockItem()
                insertSubview(item, belowSubview: tooltip)
                return item
            }
        }

        let frontmost = desktop.active.focusedPane.flatMap(PaneKind.of)
        for (kind, item) in zip(kinds, items) {
            item.update(
                kind: kind,
                isOpen: desktop.active.hasAny(of: kind),
                isActive: kind == frontmost
            )
        }
        settingsItem?.updateAsSettings()
        setNeedsLayout()
    }

    /// Todos los iconos en orden, el de ajustes el último.
    private var allItems: [DockItem] {
        items + (settingsItem.map { [$0] } ?? [])
    }

    /// El cursor se mueve por el dock (o sale de él, con `nil`). Los iconos
    /// crecen según lo cerca que les pase, como en macOS.
    func hover(at point: CGPoint?) {
        // Sólo dentro de la barra, y un poco por encima, donde quedan los
        // iconos agrandados.
        let inside = point.map { point in
            let bar = baseBarFrame
            return point.x >= bar.minX - 4 && point.x <= bar.maxX + 4
                && point.y >= -Self.itemSize * (Self.maxScale - 1) && point.y <= bounds.height
        } ?? false
        let next = inside ? point?.x : nil
        guard next != hoverX else { return }
        let entering = (hoverX == nil) != (next == nil)
        hoverX = next
        if entering {
            // Al entrar y al salir, con animación; mientras se mueve, al
            // momento, que si no va por detrás del cursor.
            UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.layoutIcons()
            }
        } else {
            layoutIcons()
        }
    }

    /// El rebote del icono al abrir una app que estaba cerrada, como en macOS.
    func bounce(_ kind: PaneKind) {
        guard let index = PaneKind.dockOrder.firstIndex(of: kind), items.indices.contains(index) else { return }
        let item = items[index]
        let up = CGAffineTransform(translationX: 0, y: -14)
        UIView.animateKeyframes(withDuration: 0.7, delay: 0, options: []) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) { item.transform = up }
            UIView.addKeyframe(withRelativeStartTime: 0.25, relativeDuration: 0.25) { item.transform = .identity }
            UIView.addKeyframe(withRelativeStartTime: 0.5, relativeDuration: 0.25) {
                item.transform = CGAffineTransform(translationX: 0, y: -7)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.75, relativeDuration: 0.25) { item.transform = .identity }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutIcons()
    }

    /// El ancho de la barra sin agrandar nada.
    private var baseWidth: CGFloat {
        let count = CGFloat(allItems.count)
        return count * Self.itemSize + (count - 1) * Self.spacing
            + 2 * (Self.separatorGap - Self.spacing) + 1 + 2 * Self.padding
    }

    private var baseBarFrame: CGRect {
        CGRect(x: (bounds.width - baseWidth) / 2, y: 0, width: baseWidth, height: Self.height)
    }

    /// El centro de cada icono sin agrandar: desde ahí se mide la distancia al
    /// cursor, para que el efecto no tiemble al moverse los iconos.
    private var baseCenters: [CGFloat] {
        var x = baseBarFrame.minX + Self.padding
        var centers: [CGFloat] = []
        for index in allItems.indices {
            if index == items.count { x += Self.separatorGap - Self.spacing + 1 + Self.separatorGap }
            centers.append(x + Self.itemSize / 2)
            x += Self.itemSize + Self.spacing
        }
        return centers
    }

    private func layoutIcons() {
        let icons = allItems
        guard !icons.isEmpty else { return }

        // Cuánto crece cada uno: el máximo justo debajo del cursor, y va
        // bajando con una curva suave hasta `reach` iconos a cada lado.
        let centers = baseCenters
        let scales: [CGFloat] = centers.map { center in
            guard let hoverX else { return 1 }
            let distance = abs(hoverX - center) / (Self.itemSize + Self.spacing)
            guard distance < Self.reach else { return 1 }
            let falloff = cos(distance / Self.reach * .pi / 2)
            return 1 + (Self.maxScale - 1) * falloff * falloff
        }
        let sizes = scales.map { Self.itemSize * $0 }

        // La barra se ensancha con ellos, desde el centro.
        let extra = sizes.reduce(0, +) - Self.itemSize * CGFloat(icons.count)
        let width = baseWidth + extra
        let bar = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: Self.height)
        background.frame = bar
        blur.frame = background.bounds
        tint.frame = background.bounds

        let bottom = Self.height - (Self.height - Self.itemSize) / 2
        var x = bar.minX + Self.padding
        for (index, icon) in icons.enumerated() {
            if index == items.count {
                x += Self.separatorGap - Self.spacing
                separator.frame = CGRect(x: x, y: (Self.height - Self.itemSize) / 2 + 6, width: 1, height: Self.itemSize - 12)
                x += 1 + Self.separatorGap
            }
            let size = sizes[index]
            // Crecen hacia arriba, desde su base, como en macOS.
            icon.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            icon.center = CGPoint(x: x + size / 2, y: bottom - size / 2)
            x += size + Self.spacing
        }

        // El nombre, encima del icono más grande.
        if hoverX != nil, let (index, _) = scales.enumerated().max(by: { $0.element < $1.element }),
           scales[index] > 1.12 {
            let icon = icons[index]
            tooltip.text = index < items.count ? PaneKind.dockOrder[index].title : "Ajustes"
            let size = tooltip.sizeThatFits(CGSize(width: 200, height: 30))
            tooltip.bounds = CGRect(x: 0, y: 0, width: size.width + 16, height: size.height + 8)
            tooltip.center = CGPoint(x: icon.center.x, y: icon.frame.minY - tooltip.bounds.height / 2 - 6)
            tooltip.alpha = 1
        } else {
            tooltip.alpha = 0
        }
    }

    /// Qué app hay bajo un punto en coordenadas del dock.
    func kind(at point: CGPoint) -> PaneKind? {
        for (kind, item) in zip(PaneKind.dockOrder, items) {
            if item.frame.insetBy(dx: -4, dy: -4).contains(point) {
                return kind
            }
        }
        return nil
    }

    /// Si el punto cae en el icono de ajustes.
    func hitsSettings(_ point: CGPoint) -> Bool {
        guard let settingsItem else { return false }
        return settingsItem.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    /// Si el punto cae en el dock, para que el escritorio se trague el evento:
    /// la barra, y los iconos agrandados que sobresalen por arriba.
    func contains(point: CGPoint) -> Bool {
        background.frame.contains(point) || allItems.contains { $0.frame.contains(point) }
    }

    /// Lo que ocupa la barra del dock sin agrandar, que no es todo el ancho
    /// del escritorio.
    var barWidth: CGFloat { baseWidth }
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

    func update(kind: PaneKind, isOpen: Bool, isActive: Bool) {
        self.kind = kind
        isSettings = false
        // «Abierta» incluye lo minimizado: sus paneles siguen vivos en el dock.
        // Un icono a color siempre; lo que dice si hay algo abierto es el
        // punto. Antes los espacios vacíos salían en gris, y parecían
        // desactivados.
        indicator.isHidden = !isOpen
        indicator.backgroundColor = isActive ? Tokens.Color.accent : Tokens.Color.textSecondary
        alpha = 1
        accessibilityLabel = kind.title
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

    /// El icono se dibuja **una vez, al tamaño máximo** del agrandamiento, y
    /// al crecer y encoger sólo se escala: redibujarlo en cada movimiento del
    /// cursor sería caro.
    private var renderedKey: String?

    private func refreshIcon() {
        // Sólo si ha cambiado lo que se pinta: esto se llama en cada
        // maquetación del escritorio.
        let key = "\(kind?.rawValue ?? "settings")|\(isSettings)|\(DesktopTheme.style.rawValue)"
        guard key != renderedKey else { return }
        renderedKey = key
        let side: CGFloat = 44 * 1.25
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
        // Entre el icono y el borde de la barra, sin pisarlo.
        indicator.frame = CGRect(x: bounds.midX - 2, y: bounds.maxY + 1.5, width: 4, height: 4)
        indicator.layer.cornerRadius = 2
        layer.cornerRadius = bounds.width / 4
    }
}

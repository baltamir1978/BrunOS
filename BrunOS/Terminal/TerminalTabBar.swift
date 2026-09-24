import UIKit

/// Barra de un panel de terminal: las sesiones, el «+» y la rueda de ajustes.
///
/// Va siempre, también con una sola sesión: es donde viven la rueda de los
/// ajustes del terminal y el botón de conexión nueva, y una barra que aparece
/// y desaparece hace saltar el contenido.
///
/// Es puro dibujo con zonas sensibles al clic, no usa `UIButton`: en la
/// pantalla externa **no hay eventos del sistema**, así que los toques llegan
/// desde el escritorio y se resuelven por geometría.
@MainActor
final class TerminalTabBar: UIView {

    static let height: CGFloat = 36

    enum Target: Equatable {
        case tab(Int)
        case close(Int)
        case newTab
        case settings
        case window(WindowControls.Button)
    }

    private var titles: [String] = []
    /// `nil` cuando se está viendo la lista de conexiones.
    private var activeIndex: Int?
    private var showsHome = false
    private var itemFrames: [CGRect] = []
    private var newTabFrame: CGRect = .zero
    private var settingsFrame: CGRect = .zero
    private var hovered: Target?
    private var hoveringControls = false
    private static let controlsX: CGFloat = 11
    /// Dónde empiezan las pestañas: detrás de los botones de ventana.
    private static var tabsX: CGFloat { controlsX + WindowControls.width + 12 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Tokens.Color.panelElevated
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    func update(titles: [String], active: Int?, showsHome: Bool) {
        self.titles = titles
        self.activeIndex = active
        self.showsHome = showsHome
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeFrames()
        setNeedsDisplay()
    }

    /// Las pestañas, más una de «Conexiones» mientras se está eligiendo.
    private var labels: [String] {
        showsHome ? titles + ["Conexiones"] : titles
    }

    private func recomputeFrames() {
        settingsFrame = CGRect(x: bounds.width - 32, y: 3, width: 26, height: bounds.height - 6)
        newTabFrame = CGRect(x: settingsFrame.minX - 30, y: 3, width: 26, height: bounds.height - 6)

        let available = max(0, newTabFrame.minX - 8 - Self.tabsX)
        let count = max(labels.count, 1)
        let width = min(available / CGFloat(count), 220)
        itemFrames = labels.indices.map { index in
            CGRect(x: Self.tabsX + CGFloat(index) * width, y: 0, width: width, height: bounds.height)
        }
    }

    func target(at point: CGPoint) -> Target? {
        if let button = WindowControls.button(at: point, x: Self.controlsX, midY: bounds.height / 2) {
            return .window(button)
        }
        if settingsFrame.contains(point) { return .settings }
        if newTabFrame.contains(point) { return .newTab }
        guard let index = itemFrames.firstIndex(where: { $0.contains(point) }) else { return nil }
        // La pestaña de «Conexiones» no se cierra ni se elige: ya está puesta.
        guard index < titles.count else { return nil }
        let close = CGRect(x: itemFrames[index].maxX - 24, y: 0, width: 22, height: bounds.height)
        return close.contains(point) ? .close(index) : .tab(index)
    }

    func hover(at point: CGPoint?) {
        let target = point.flatMap(target(at:))
        let inControls = point.map { WindowControls.groupContains($0, x: Self.controlsX, midY: bounds.height / 2) } ?? false
        guard target != hovered || inControls != hoveringControls else { return }
        hovered = target
        hoveringControls = inControls
        setNeedsDisplay()
    }

    // MARK: - Dibujo

    private func cg(_ color: UIColor) -> CGColor {
        color.cgColor(for: traitCollection.userInterfaceStyle)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        context.setFillColor(cg(Tokens.Color.border))
        context.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
        WindowControls.draw(in: context, x: Self.controlsX, midY: bounds.height / 2,
                            hovering: hoveringControls, scale: layer.contentsScale)

        let font = Tokens.mono(12.5)
        for (index, frame) in itemFrames.enumerated() {
            let isHome = index >= titles.count
            let isActive = isHome ? showsHome : (index == activeIndex && !showsHome)

            if isActive {
                context.setFillColor(cg(Tokens.Color.panel))
                context.fill(frame)
                // Filete ámbar abajo, igual que el espacio de trabajo activo.
                context.setFillColor(cg(Tokens.Color.accent))
                context.fill(CGRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 2))
            } else if hovered == .tab(index) || hovered == .close(index) {
                context.setFillColor(cg(Tokens.Color.text.withAlphaComponent(0.05)))
                context.fill(frame)
            }
            context.setFillColor(cg(Tokens.Color.border))
            context.fill(CGRect(x: frame.maxX - 1, y: 6, width: 1, height: frame.height - 12))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isActive ? Tokens.Color.text : Tokens.Color.textSecondary,
            ]
            let text = labels[index] as NSString
            let size = text.size(withAttributes: attributes)
            let closeRoom: CGFloat = isHome ? 0 : 22
            text.draw(
                in: CGRect(
                    x: frame.minX + 10,
                    y: frame.midY - size.height / 2,
                    width: max(0, frame.width - 20 - closeRoom),
                    height: size.height
                ),
                withAttributes: attributes
            )

            if !isHome {
                let hoveredClose = hovered == .close(index)
                drawSymbol("xmark", at: CGPoint(x: frame.maxX - 14, y: frame.midY), size: 8,
                            color: hoveredClose ? Tokens.Color.text : Tokens.Color.textSecondary.withAlphaComponent(0.7))
            }
        }

        for (target, frame, symbol) in [(Target.newTab, newTabFrame, "plus"),
                                        (Target.settings, settingsFrame, "gearshape")] {
            if hovered == target {
                context.setFillColor(cg(Tokens.Color.text.withAlphaComponent(0.08)))
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
                context.fillPath()
            }
            drawSymbol(symbol, at: CGPoint(x: frame.midX, y: frame.midY), size: 13,
                       color: hovered == target ? Tokens.Color.text : Tokens.Color.text.withAlphaComponent(0.72))
        }
    }

    private func drawSymbol(_ name: String, at center: CGPoint, size: CGFloat, color: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let image = UIImage.crispSymbol(name, configuration: configuration, scale: layer.contentsScale)?
            .withTintColor(color.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        else { return }
        image.draw(at: CGPoint(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2))
    }
}

import UIKit

/// Barra del panel de navegador, al estilo de Safari.
///
/// **Una sola fila**: navegación a la izquierda, dirección al centro en una
/// cápsula, y a la derecha el escudo del bloqueador, las pestañas y el botón de
/// pestaña nueva. Las dos filas separadas de la primera versión se comían 60 pt
/// lógicos de alto en un panel que muchas veces no llega a 500.
///
/// Se dibuja con `draw(_:)` y resuelve los clics por geometría, sin un solo
/// `UIButton`. **En la pantalla externa no hay eventos del sistema**: el
/// escritorio pregunta qué hay bajo el cursor y esta vista responde.
@MainActor
final class BrowserChrome: UIView {

    static let height: CGFloat = 38
    private static let buttonSize: CGFloat = 28

    /// Lo que hay bajo un punto.
    enum Target: Equatable {
        case tab(Int)
        case closeTab(Int)
        case newTab
        case back
        case forward
        case reload
        case address
        case blocker
        case settings
        case window(WindowControls.Button)
        case none
    }

    private var titles: [String] = []
    private var activeIndex = 0
    private var address = ""
    private var isEditing = false
    private var isSelected = false
    private var canGoBack = false
    private var canGoForward = false
    private var isLoading = false
    private var blockerOn = true

    private var tabFrames: [CGRect] = []
    private var closeFrames: [CGRect] = []
    private var newTabFrame: CGRect = .zero
    private var backFrame: CGRect = .zero
    private var forwardFrame: CGRect = .zero
    private var reloadFrame: CGRect = .zero
    private var addressFrame: CGRect = .zero
    private var blockerFrame: CGRect = .zero
    private var settingsFrame: CGRect = .zero
    /// El cursor está sobre los botones de ventana, que es cuando enseñan sus
    /// símbolos.
    private var hoveringControls = false
    private static let controlsX: CGFloat = 13

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

    func update(
        tabs: [String],
        active: Int,
        address: String,
        isEditing: Bool,
        isSelected: Bool,
        canGoBack: Bool,
        canGoForward: Bool,
        isLoading: Bool,
        blockerOn: Bool
    ) {
        self.titles = tabs
        self.activeIndex = active
        self.address = address
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.blockerOn = blockerOn
        recomputeFrames()
        setNeedsDisplay()
    }

    // MARK: - Geometría

    private func recomputeFrames() {
        guard bounds.width > 0 else { return }

        let size = Self.buttonSize
        let y = (Self.height - size) / 2

        backFrame = CGRect(x: Self.controlsX + WindowControls.width + 10, y: y, width: size, height: size)
        forwardFrame = CGRect(x: backFrame.maxX + 1, y: y, width: size, height: size)
        reloadFrame = CGRect(x: forwardFrame.maxX + 1, y: y, width: size, height: size)

        settingsFrame = CGRect(x: bounds.width - size - 4, y: y, width: size, height: size)
        newTabFrame = CGRect(x: settingsFrame.minX - size, y: y, width: size, height: size)
        blockerFrame = CGRect(x: newTabFrame.minX - size, y: y, width: size, height: size)

        // Las pestañas sólo aparecen con más de una: con una sola, su título ya
        // está en la barra superior del escritorio y aquí sólo robaría sitio.
        let showTabs = titles.count > 1
        if showTabs {
            let gap: CGFloat = 3
            let tabWidth = min(150, (bounds.width * 0.42) / CGFloat(titles.count))
            let tabsWidth = tabWidth * CGFloat(titles.count) + gap * CGFloat(titles.count - 1)
            let start = blockerFrame.minX - tabsWidth - 6
            tabFrames = titles.indices.map { index in
                CGRect(
                    x: start + CGFloat(index) * (tabWidth + gap), y: 4,
                    width: tabWidth, height: Self.height - 8
                )
            }
            closeFrames = tabFrames.map { frame in
                CGRect(x: frame.maxX - 18, y: frame.midY - 7, width: 14, height: 14)
            }
        } else {
            tabFrames = []
            closeFrames = []
        }

        let addressEnd = (tabFrames.first?.minX ?? blockerFrame.minX) - 8
        addressFrame = CGRect(
            x: reloadFrame.maxX + 6,
            y: y + 3,
            width: max(60, addressEnd - reloadFrame.maxX - 6),
            height: size - 6
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeFrames()
        setNeedsDisplay()
    }

    func hover(at point: CGPoint?) {
        let inside = point.map { WindowControls.groupContains($0, x: Self.controlsX, midY: Self.height / 2) } ?? false
        guard inside != hoveringControls else { return }
        hoveringControls = inside
        setNeedsDisplay()
    }

    func hit(at point: CGPoint) -> Target {
        if let button = WindowControls.button(at: point, x: Self.controlsX, midY: Self.height / 2) {
            return .window(button)
        }
        if let index = closeFrames.firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(point) }) {
            return .closeTab(index)
        }
        if let index = tabFrames.firstIndex(where: { $0.contains(point) }) {
            return .tab(index)
        }
        if newTabFrame.contains(point) { return .newTab }
        if settingsFrame.contains(point) { return .settings }
        if backFrame.contains(point) { return .back }
        if forwardFrame.contains(point) { return .forward }
        if reloadFrame.contains(point) { return .reload }
        if blockerFrame.contains(point) { return .blocker }
        // La dirección se mira la última y con holgura: es la zona más grande y
        // la que más se pulsa, así que conviene que perdone puntería.
        if addressFrame.insetBy(dx: -4, dy: -4).contains(point) { return .address }
        return .none
    }

    // MARK: - Dibujo

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        WindowControls.draw(in: context, x: Self.controlsX, midY: Self.height / 2,
                            hovering: hoveringControls, scale: layer.contentsScale)

        drawTabs(in: context)
        drawNavigationButtons()
        drawAddressField(in: context)
        drawSymbol(
            blockerOn ? "shield.lefthalf.filled" : "shield.slash",
            in: blockerFrame,
            color: blockerOn ? Tokens.Color.accentAlt : Tokens.Color.textSecondary
        )
        drawSymbol("plus", in: newTabFrame, color: Tokens.Color.textSecondary)
        drawSymbol("gearshape", in: settingsFrame, color: Tokens.Color.text.withAlphaComponent(0.72), size: 13.5)

        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.fill(CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1))
    }

    private func drawTabs(in context: CGContext) {
        let font = Tokens.sans(11)
        for (index, frame) in tabFrames.enumerated() {
            let isActive = index == activeIndex

            // **Con relieve, no planas.** Sin fondo ni borde no se sabía dónde
            // empezaba una pestaña y acababa la siguiente: parecían una lista
            // de palabras sueltas.
            let path = UIBezierPath(roundedRect: frame, cornerRadius: 7)
            context.setFillColor(
                (isActive ? Tokens.Color.panel : Tokens.Color.background.withAlphaComponent(0.45))
                    .desktopCGColor
            )
            context.addPath(path.cgPath)
            context.fillPath()

            context.setStrokeColor(
                (isActive ? Tokens.Color.accent.withAlphaComponent(0.55) : Tokens.Color.border)
                    .desktopCGColor
            )
            context.setLineWidth(1)
            context.addPath(path.cgPath)
            context.strokePath()

            // Separador entre pestañas contiguas inactivas, como en Safari.
            if index > 0, !isActive, index - 1 != activeIndex {
                context.setFillColor(Tokens.Color.border.desktopCGColor)
                context.fill(CGRect(
                    x: frame.minX - 1, y: frame.minY + 5,
                    width: 1, height: frame.height - 10
                ))
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isActive ? Tokens.Color.text : Tokens.Color.textSecondary,
            ]
            (titles[index] as NSString).draw(
                in: CGRect(
                    x: frame.minX + 8, y: frame.midY - 7,
                    width: max(0, frame.width - 28), height: 14
                ),
                withAttributes: attributes
            )

            drawSymbol("xmark", in: closeFrames[index], color: Tokens.Color.textSecondary, size: 9)
        }
    }

    private func drawNavigationButtons() {
        drawSymbol("chevron.left", in: backFrame,
                   color: canGoBack ? Tokens.Color.text : Tokens.Color.border)
        drawSymbol("chevron.right", in: forwardFrame,
                   color: canGoForward ? Tokens.Color.text : Tokens.Color.border)
        drawSymbol(isLoading ? "xmark" : "arrow.clockwise", in: reloadFrame,
                   color: Tokens.Color.text)
    }

    /// Cápsula de dirección, como la de Safari.
    private func drawAddressField(in context: CGContext) {
        let path = UIBezierPath(roundedRect: addressFrame, cornerRadius: addressFrame.height / 2)
        context.setFillColor(Tokens.Color.background.desktopCGColor)
        context.addPath(path.cgPath)
        context.fillPath()

        if isEditing {
            context.setStrokeColor(Tokens.Color.accent.desktopCGColor)
            context.setLineWidth(1.5)
            context.addPath(path.cgPath)
            context.strokePath()
        }

        let isPlaceholder = address.isEmpty && !isEditing
        let shown = isPlaceholder ? "Busca o escribe una dirección" : address
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(12),
            .foregroundColor: isPlaceholder ? Tokens.Color.textSecondary : Tokens.Color.text,
        ]
        let text = (isEditing && !isSelected ? shown + "|" : shown) as NSString
        let textSize = text.size(withAttributes: attributes)

        // Centrada cuando sólo se lee, a la izquierda mientras se escribe: si
        // no, el texto bailaría con cada letra que se teclea.
        let fits = textSize.width < addressFrame.width - 24
        let x = isEditing || !fits
            ? addressFrame.minX + 12
            : addressFrame.midX - textSize.width / 2
        // Con todo seleccionado se pinta el resalte detrás, como en cualquier
        // navegador: así se ve que la próxima tecla va a sustituirlo entero.
        if isSelected {
            let highlight = CGRect(
                x: x - 3, y: addressFrame.midY - textSize.height / 2 - 1,
                width: min(textSize.width + 6, addressFrame.width - 16),
                height: textSize.height + 2
            )
            context.setFillColor(Tokens.Color.accent.withAlphaComponent(0.35).desktopCGColor)
            context.addPath(UIBezierPath(roundedRect: highlight, cornerRadius: 3).cgPath)
            context.fillPath()
        }

        text.draw(
            in: CGRect(
                x: x, y: addressFrame.midY - textSize.height / 2,
                width: addressFrame.width - 16, height: textSize.height
            ),
            withAttributes: attributes
        )
    }

    /// Dibuja un símbolo del sistema centrado en un rectángulo.
    ///
    /// El color se resuelve en oscuro a mano: esto se pinta en la pantalla
    /// externa, que va siempre oscura, y un color dinámico saldría con el modo
    /// que tuviera el iPhone en ese momento.
    private func drawSymbol(_ name: String, in frame: CGRect, color: UIColor, size: CGFloat = 12) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let image = UIImage.crispSymbol(name, configuration: configuration, scale: layer.contentsScale)?
            .withTintColor(
                color.resolvedColor(with: UITraitCollection(userInterfaceStyle: DesktopTheme.style)),
                renderingMode: .alwaysOriginal
            )
        else { return }

        image.draw(at: CGPoint(
            x: frame.midX - image.size.width / 2,
            y: frame.midY - image.size.height / 2
        ))
    }
}

import UIKit

/// Barra del panel de navegador: pestañas arriba, navegación y dirección abajo.
///
/// Se dibuja con `draw(_:)` y resuelve los clics por geometría, sin un solo
/// `UIButton`. **En la pantalla externa no hay eventos del sistema**, así que un
/// botón de UIKit no serviría de nada: el escritorio pregunta qué hay bajo el
/// cursor y esta vista responde.
@MainActor
final class BrowserChrome: UIView {

    static let height: CGFloat = 60
    private static let tabStripHeight: CGFloat = 26
    private static let buttonSize: CGFloat = 26

    /// Lo que hay bajo un punto.
    enum Target {
        case tab(Int)
        case closeTab(Int)
        case newTab
        case back
        case forward
        case reload
        case address
        case blocker
        case none
    }

    private var titles: [String] = []
    private var activeIndex = 0
    private var address = ""
    private var isEditing = false
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
        canGoBack: Bool,
        canGoForward: Bool,
        isLoading: Bool,
        blockerOn: Bool
    ) {
        self.titles = tabs
        self.activeIndex = active
        self.address = address
        self.isEditing = isEditing
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

        // Tira de pestañas.
        let stripHeight = Self.tabStripHeight
        let newTabWidth: CGFloat = 26
        let available = bounds.width - newTabWidth - 8
        let tabWidth = titles.isEmpty ? 0 : min(available / CGFloat(titles.count), 190)

        tabFrames = titles.indices.map { index in
            CGRect(x: CGFloat(index) * tabWidth, y: 0, width: tabWidth, height: stripHeight)
        }
        closeFrames = tabFrames.map { frame in
            CGRect(x: frame.maxX - 20, y: frame.midY - 8, width: 16, height: 16)
        }
        newTabFrame = CGRect(
            x: CGFloat(titles.count) * tabWidth + 4,
            y: 3,
            width: newTabWidth - 8,
            height: stripHeight - 6
        )

        // Fila de navegación.
        let rowY = stripHeight + 4
        let size = Self.buttonSize
        backFrame = CGRect(x: 6, y: rowY, width: size, height: size)
        forwardFrame = CGRect(x: backFrame.maxX + 2, y: rowY, width: size, height: size)
        reloadFrame = CGRect(x: forwardFrame.maxX + 2, y: rowY, width: size, height: size)
        blockerFrame = CGRect(x: bounds.width - size - 6, y: rowY, width: size, height: size)
        addressFrame = CGRect(
            x: reloadFrame.maxX + 6,
            y: rowY + 2,
            width: max(0, blockerFrame.minX - reloadFrame.maxX - 12),
            height: size - 4
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeFrames()
        setNeedsDisplay()
    }

    func hit(at point: CGPoint) -> Target {
        if let index = closeFrames.firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(point) }) {
            return .closeTab(index)
        }
        if let index = tabFrames.firstIndex(where: { $0.contains(point) }) {
            return .tab(index)
        }
        if newTabFrame.insetBy(dx: -4, dy: -4).contains(point) { return .newTab }
        if backFrame.contains(point) { return .back }
        if forwardFrame.contains(point) { return .forward }
        if reloadFrame.contains(point) { return .reload }
        if blockerFrame.contains(point) { return .blocker }
        if addressFrame.contains(point) { return .address }
        return .none
    }

    // MARK: - Dibujo

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        drawTabs(in: context)
        drawNavigationButtons(in: context)
        drawAddressField(in: context)
        drawBlockerBadge(in: context)

        context.setFillColor(Tokens.Color.border.cgColor)
        context.fill(CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1))
    }

    private func drawTabs(in context: CGContext) {
        let font = Tokens.sans(11)
        for (index, frame) in tabFrames.enumerated() {
            let isActive = index == activeIndex
            context.setFillColor(
                (isActive ? Tokens.Color.panel : Tokens.Color.panelElevated).cgColor
            )
            context.fill(frame)

            if isActive {
                context.setFillColor(Tokens.Color.accent.cgColor)
                context.fill(CGRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 2))
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isActive ? Tokens.Color.text : Tokens.Color.textSecondary,
            ]
            let text = titles[index] as NSString
            let textRect = CGRect(
                x: frame.minX + 8,
                y: frame.midY - 7,
                width: max(0, frame.width - 30),
                height: 14
            )
            text.draw(in: textRect, withAttributes: attributes)

            drawGlyph("×", in: closeFrames[index], color: Tokens.Color.textSecondary, size: 14)
        }

        drawGlyph("+", in: newTabFrame, color: Tokens.Color.textSecondary, size: 15)
    }

    private func drawNavigationButtons(in context: CGContext) {
        drawGlyph("‹", in: backFrame,
                  color: canGoBack ? Tokens.Color.text : Tokens.Color.border, size: 20)
        drawGlyph("›", in: forwardFrame,
                  color: canGoForward ? Tokens.Color.text : Tokens.Color.border, size: 20)
        drawGlyph(isLoading ? "×" : "⟳", in: reloadFrame, color: Tokens.Color.text, size: 15)
    }

    private func drawAddressField(in context: CGContext) {
        let path = UIBezierPath(roundedRect: addressFrame, cornerRadius: 6)
        context.setFillColor(Tokens.Color.background.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()

        context.setStrokeColor(
            (isEditing ? Tokens.Color.accent : Tokens.Color.border).cgColor
        )
        context.setLineWidth(1)
        context.addPath(path.cgPath)
        context.strokePath()

        let shown = address.isEmpty && !isEditing ? "Escribe una dirección o busca" : address
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.mono(11),
            .foregroundColor: address.isEmpty && !isEditing
                ? Tokens.Color.textSecondary
                : Tokens.Color.text,
        ]
        let text = (isEditing ? shown + "▌" : shown) as NSString
        text.draw(
            in: addressFrame.insetBy(dx: 8, dy: 0).offsetBy(dx: 0, dy: addressFrame.height / 2 - 7),
            withAttributes: attributes
        )
    }

    /// Escudo del bloqueador. Sin número al lado, y es una decisión.
    ///
    /// `WKContentRuleList` **no dice cuántas peticiones bloquea**: el filtrado
    /// ocurre dentro de WebKit y no hay ningún callback. Se podría enseñar una
    /// estimación, pero sería un número inventado con pinta de dato. Mejor
    /// decir sólo si está activo aquí, que eso sí se sabe.
    private func drawBlockerBadge(in context: CGContext) {
        drawGlyph(
            blockerOn ? "◉" : "○",
            in: blockerFrame,
            color: blockerOn ? Tokens.Color.accentAlt : Tokens.Color.textSecondary,
            size: 15
        )
    }

    private func drawGlyph(_ glyph: String, in frame: CGRect, color: UIColor, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(size),
            .foregroundColor: color,
        ]
        let text = glyph as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(
                x: frame.midX - textSize.width / 2,
                y: frame.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }
}

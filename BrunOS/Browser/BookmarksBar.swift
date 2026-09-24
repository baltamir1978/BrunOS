import UIKit

/// La barra de favoritos, bajo la de direcciones.
///
/// Como todo lo de la pantalla externa, se dibuja entera y resuelve los clics
/// por geometría: aquí no llegan eventos del sistema. **Las zonas pulsables se
/// apuntan al calcular la maquetación**, en el mismo sitio donde se decide lo
/// que se ve, para que no puedan desalinearse.
///
/// Los que no caben no se recortan ni se encogen: se van a un botón `»` al
/// final, que los enseña en un menú. Una barra con quince favoritos de tres
/// letras no sirve para nada.
@MainActor
final class BookmarksBar: UIView {

    static let height: CGFloat = 28

    enum Target: Equatable {
        case bookmark(Int)
        case overflow
        case none
    }

    /// Si se enseña. Es un ajuste, como en cualquier navegador: con la barra
    /// puesta se pierden 28 puntos de página.
    static var isVisible: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: BrowserHistory.bookmarksDidChange, object: nil)
        }
    }

    private static let key = "browser.bookmarksBar"

    private(set) var pages: [BrowserHistory.Page] = []
    /// Cuántos entran en la barra; el resto, al menú del final.
    private(set) var visibleCount = 0

    private var itemFrames: [CGRect] = []
    private var overflowFrame: CGRect = .zero
    private var hoveredIndex: Int?

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

    func update(pages: [BrowserHistory.Page]) {
        // Se llama con cada cambio de la barra de direcciones, también con
        // cada paso de la barra de carga: sin cambios, no se repinta.
        guard pages != self.pages else { return }
        self.pages = pages
        recomputeFrames()
        setNeedsDisplay()
    }

    /// Los que no caben, para el menú del botón `»`.
    var overflowPages: [BrowserHistory.Page] {
        Array(pages.dropFirst(visibleCount))
    }

    // MARK: - Geometría

    private static let gap: CGFloat = 4
    private static let padding: CGFloat = 8
    private static let iconSide: CGFloat = 14
    private static let maxItemWidth: CGFloat = 170

    private func width(of page: BrowserHistory.Page) -> CGFloat {
        let text = (page.title as NSString).size(withAttributes: [.font: Tokens.sans(11.5)])
        return min(Self.maxItemWidth, Self.padding * 2 + Self.iconSide + 5 + text.width)
    }

    private func recomputeFrames() {
        guard bounds.width > 0 else { return }
        itemFrames = []
        overflowFrame = .zero
        visibleCount = 0

        // Se reserva sitio para el `»` desde el principio: decidir después que
        // hace falta obligaría a quitar un favorito ya colocado.
        let reserve: CGFloat = 26
        var x: CGFloat = 8
        let limit = bounds.width - 8

        for page in pages {
            let itemWidth = width(of: page)
            let isLast = visibleCount == pages.count - 1
            let needed = isLast ? itemWidth : itemWidth + reserve
            guard x + needed <= limit else { break }
            itemFrames.append(CGRect(x: x, y: 3, width: itemWidth, height: Self.height - 6))
            x += itemWidth + Self.gap
            visibleCount += 1
        }

        if visibleCount < pages.count {
            overflowFrame = CGRect(x: limit - 22, y: 3, width: 22, height: Self.height - 6)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeFrames()
        setNeedsDisplay()
    }

    func hit(at point: CGPoint) -> Target {
        if !overflowFrame.isEmpty, overflowFrame.insetBy(dx: -3, dy: -3).contains(point) { return .overflow }
        if let index = itemFrames.firstIndex(where: { $0.contains(point) }) { return .bookmark(index) }
        return .none
    }

    func hover(at point: CGPoint?) {
        let index = point.flatMap { location in itemFrames.firstIndex { $0.contains(location) } }
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        setNeedsDisplay()
    }

    // MARK: - Dibujo

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.fill(CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1))

        if pages.isEmpty {
            ("Añade favoritos con Cmd+D o desde el clic derecho" as NSString).draw(
                at: CGPoint(x: 10, y: Self.height / 2 - 7),
                withAttributes: [
                    .font: Tokens.sans(11),
                    .foregroundColor: Tokens.Color.textSecondary.withAlphaComponent(0.7),
                ]
            )
            return
        }

        for (index, frame) in itemFrames.enumerated() {
            let page = pages[index]
            if hoveredIndex == index {
                context.setFillColor(Tokens.Color.text.withAlphaComponent(0.09).desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 5).cgPath)
                context.fillPath()
            }

            let iconFrame = CGRect(
                x: frame.minX + Self.padding, y: frame.midY - Self.iconSide / 2,
                width: Self.iconSide, height: Self.iconSide
            )
            drawIcon(for: page, in: iconFrame, context: context)

            let textX = iconFrame.maxX + 5
            let available = frame.maxX - Self.padding - textX
            (page.title as NSString).draw(
                in: CGRect(x: textX, y: frame.midY - 7.5, width: max(0, available), height: 15),
                withAttributes: [
                    .font: Tokens.sans(11.5),
                    .foregroundColor: Tokens.Color.text,
                ]
            )
        }

        if !overflowFrame.isEmpty {
            ("»" as NSString).draw(
                at: CGPoint(x: overflowFrame.midX - 4, y: overflowFrame.midY - 9),
                withAttributes: [
                    .font: Tokens.sans(13, weight: .semibold),
                    .foregroundColor: Tokens.Color.textSecondary,
                ]
            )
        }
    }

    private func drawIcon(for page: BrowserHistory.Page, in frame: CGRect, context: CGContext) {
        FaviconStore.drawSiteIcon(for: page.url, in: frame, context: context)
    }
}

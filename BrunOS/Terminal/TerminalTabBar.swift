import UIKit

/// Barra de pestañas de un panel de terminal.
///
/// Sólo aparece con más de una sesión: en el caso normal de una sola, robaría
/// alto sin decir nada que no esté ya en la barra superior del escritorio.
///
/// Es puro rótulo con zonas sensibles al clic, no usa `UIButton`: en la pantalla
/// externa **no hay eventos del sistema**, así que los toques llegan desde el
/// escritorio y se resuelven por geometría en `hitTest(_:)`.
@MainActor
final class TerminalTabBar: UIView {

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private var titles: [String] = []
    private var activeIndex = 0
    private var itemFrames: [CGRect] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Tokens.Color.panel
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    func update(titles: [String], active: Int) {
        self.titles = titles
        self.activeIndex = active
        setNeedsDisplay()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeFrames()
        setNeedsDisplay()
    }

    private func recomputeFrames() {
        guard !titles.isEmpty, bounds.width > 0 else {
            itemFrames = []
            return
        }
        let width = min(bounds.width / CGFloat(titles.count), 200)
        itemFrames = titles.indices.map { index in
            CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
        }
    }

    /// Qué pestaña hay en un punto, para que el panel resuelva el clic.
    func indexOfTab(at point: CGPoint) -> Int? {
        itemFrames.firstIndex { $0.contains(point) }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let font = Tokens.mono(11)
        for (index, frame) in itemFrames.enumerated() {
            let isActive = index == activeIndex

            context.setFillColor(
                (isActive ? Tokens.Color.panelElevated : Tokens.Color.panel).cgColor
            )
            context.fill(frame)

            if isActive {
                // Filete ámbar abajo, igual que el espacio de trabajo activo.
                context.setFillColor(Tokens.Color.accent.cgColor)
                context.fill(CGRect(
                    x: frame.minX, y: frame.maxY - 2,
                    width: frame.width, height: 2
                ))
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isActive ? Tokens.Color.text : Tokens.Color.textSecondary,
            ]
            let text = titles[index] as NSString
            let available = frame.insetBy(dx: 8, dy: 0)
            let size = text.size(withAttributes: attributes)
            text.draw(
                in: CGRect(
                    x: available.minX,
                    y: available.midY - size.height / 2,
                    width: available.width,
                    height: size.height
                ),
                withAttributes: attributes
            )
        }
    }
}

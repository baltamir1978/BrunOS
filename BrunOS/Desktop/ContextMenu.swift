import UIKit

/// Menú contextual del escritorio: el del clic derecho.
///
/// Es genérico a propósito: lo usan los ficheros, y lo usará el navegador para
/// «abrir en pestaña nueva» y «copiar enlace». **No recibe eventos del
/// sistema**: el escritorio le entrega el cursor y aquí se resuelve por
/// geometría.
@MainActor
final class ContextMenu: UIView {

    struct Entry {
        var title: String
        var symbol: String
        var isDestructive = false
        var isEnabled = true
        var action: () -> Void
    }

    var onDismiss: (() -> Void)?

    private let entries: [Entry]
    private let card = CardView()
    private var rowFrames: [CGRect] = []
    private var hoveredIndex: Int?

    private static let rowHeight: CGFloat = 28
    private static let width: CGFloat = 210

    init(entries: [Entry], at point: CGPoint, in bounds: CGRect) {
        self.entries = entries
        super.init(frame: bounds)

        backgroundColor = .clear

        card.backgroundColor = Tokens.Color.panelElevated
        card.layer.cornerRadius = 10
        card.layer.borderWidth = 1
        card.layer.borderColor = Tokens.Color.border.desktopCGColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.4
        card.layer.shadowRadius = 16
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        card.drawContent = { [weak self] in self?.drawCard(in: $0) }
        addSubview(card)

        // El menú se abre donde está el cursor, pero **no se sale de la
        // pantalla**: si no cabe hacia abajo o hacia la derecha, se vuelca al
        // otro lado, como hace cualquier menú.
        let height = CGFloat(entries.count) * Self.rowHeight + 10
        let x = point.x + Self.width > bounds.maxX ? point.x - Self.width : point.x
        let y = point.y + height > bounds.maxY ? point.y - height : point.y
        card.frame = CGRect(x: x, y: y, width: Self.width, height: height)

        rowFrames = entries.indices.map { index in
            CGRect(
                x: 5, y: 5 + CGFloat(index) * Self.rowHeight,
                width: Self.width - 10, height: Self.rowHeight
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    /// Lo llama la tarjeta desde su `draw(_:)`: ver `CardView`.
    private func drawCard(in context: CGContext) {
        let origin = card.frame.origin

        for (index, entry) in entries.enumerated() {
            let frame = rowFrames[index].offsetBy(dx: origin.x, dy: origin.y)

            if index == hoveredIndex, entry.isEnabled {
                context.setFillColor(Tokens.Color.accent.withAlphaComponent(0.22).desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
                context.fillPath()
            }

            let color: UIColor = if !entry.isEnabled {
                Tokens.Color.border
            } else if entry.isDestructive {
                UIColor(hex: 0xE05C4B)
            } else {
                Tokens.Color.text
            }

            let configuration = UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            if let image = UIImage(systemName: entry.symbol, withConfiguration: configuration)?
                .withTintColor(
                    color.resolvedColor(with: UITraitCollection(userInterfaceStyle: DesktopTheme.style)),
                    renderingMode: .alwaysOriginal
                ) {
                image.draw(at: CGPoint(x: frame.minX + 10, y: frame.midY - image.size.height / 2))
            }

            (entry.title as NSString).draw(
                at: CGPoint(x: frame.minX + 34, y: frame.midY - 8),
                withAttributes: [
                    .font: Tokens.sans(13),
                    .foregroundColor: color,
                ]
            )
        }
    }

    /// Devuelve `true` si consumió el evento.
    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        let inCard = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)

        guard card.frame.contains(point) else {
            // Pinchar fuera cierra, como cualquier menú.
            if case .down = kind { onDismiss?() }
            return true
        }

        let index = rowFrames.firstIndex { $0.contains(inCard) }
        switch kind {
        case .moved:
            if hoveredIndex != index {
                hoveredIndex = index
                card.setNeedsDisplay()
            }
        case .up:
            // Se actúa al **soltar**, no al pulsar: si no, el mismo clic que
            // abre el menú elegiría lo que hubiera debajo.
            if let index, entries[index].isEnabled {
                let action = entries[index].action
                onDismiss?()
                action()
            }
        default:
            break
        }
        return true
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        if event.phase == .down, event.key.keyCode == .keyboardEscape {
            onDismiss?()
        }
        return true
    }
}

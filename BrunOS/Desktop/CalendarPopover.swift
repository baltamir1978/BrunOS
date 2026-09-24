import UIKit

/// El calendario del mes, al pulsar la hora de la barra superior, como el de
/// macOS: el mes con la semana empezando en lunes, hoy marcado, y flechas para
/// ir a otros meses. Lo pidió Bruno el 24-sep-2026.
///
/// Sólo enseña fechas: no lee el calendario del iPhone, que pediría un permiso
/// cuyo aviso saldría en la pantalla del teléfono, apagada.
@MainActor
final class CalendarPopover: UIView {

    var onDismiss: (() -> Void)?

    private let card = CardView()
    /// El primer día del mes que se enseña.
    private var month: Date
    private var previousFrame: CGRect = .zero
    private var nextFrame: CGRect = .zero
    private var todayFrame: CGRect = .zero
    private var hovered: String?

    private static let width: CGFloat = 272
    private static let cell: CGFloat = 34
    private static let gridTop: CGFloat = 76

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "es_ES")
        calendar.firstWeekday = 2
        return calendar
    }()

    init(anchor: CGPoint, in bounds: CGRect) {
        month = Date()
        super.init(frame: bounds)
        backgroundColor = .clear
        month = startOfMonth(Date())

        card.backgroundColor = Tokens.Color.panelElevated
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 1
        card.setThemedBorder(Tokens.Color.border)
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.35
        card.layer.shadowRadius = 18
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        // `CardView` entrega el contexto en coordenadas de la ventana; aquí
        // todo se cuenta desde la esquina de la tarjeta.
        card.drawContent = { [weak self] context in
            guard let self else { return }
            context.translateBy(x: self.card.frame.minX, y: self.card.frame.minY)
            self.draw(in: context)
        }
        addSubview(card)

        let height = Self.gridTop + 6 * Self.cell + 14
        let x = min(max(8, anchor.x - Self.width + 30), bounds.maxX - Self.width - 8)
        card.frame = CGRect(x: x, y: anchor.y + 6, width: Self.width, height: height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    private func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func move(months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
        card.setNeedsDisplay()
    }

    // MARK: - Dibujo

    private func draw(in context: CGContext) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "LLLL yyyy"
        let title = formatter.string(from: month).capitalizedFirst
        (title as NSString).draw(at: CGPoint(x: 16, y: 14), withAttributes: [
            .font: Tokens.sans(15, weight: .semibold), .foregroundColor: Tokens.Color.text,
        ])

        // Flechas y «Hoy», arriba a la derecha.
        nextFrame = CGRect(x: Self.width - 36, y: 10, width: 26, height: 26)
        previousFrame = CGRect(x: nextFrame.minX - 28, y: 10, width: 26, height: 26)
        let todayAttributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(12, weight: .semibold), .foregroundColor: Tokens.Color.accent,
        ]
        let todaySize = ("Hoy" as NSString).size(withAttributes: todayAttributes)
        todayFrame = CGRect(x: previousFrame.minX - todaySize.width - 12, y: 23 - todaySize.height / 2,
                            width: todaySize.width, height: todaySize.height)
        let showingToday = calendar.isDate(month, equalTo: Date(), toGranularity: .month)
        if !showingToday {
            ("Hoy" as NSString).draw(at: todayFrame.origin, withAttributes: todayAttributes)
        }
        for (id, frame, symbol) in [("prev", previousFrame, "chevron.left"), ("next", nextFrame, "chevron.right")] {
            if hovered == id {
                context.setFillColor(Tokens.Color.text.withAlphaComponent(0.08).desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
                context.fillPath()
            }
            drawSymbol(symbol, at: CGPoint(x: frame.midX, y: frame.midY))
        }

        // Los días de la semana, de lunes a domingo.
        let letters = ["L", "M", "X", "J", "V", "S", "D"]
        let gridX = (Self.width - 7 * Self.cell) / 2
        for (index, letter) in letters.enumerated() {
            let frame = CGRect(x: gridX + CGFloat(index) * Self.cell, y: 50, width: Self.cell, height: 18)
            drawCentered(letter, in: frame, font: Tokens.sans(11, weight: .semibold),
                         color: index >= 5 ? Tokens.Color.textSecondary.withAlphaComponent(0.7) : Tokens.Color.textSecondary)
        }

        // Los días: el hueco antes del 1 según en qué día de la semana cae.
        guard let days = calendar.range(of: .day, in: .month, for: month) else { return }
        let weekday = calendar.component(.weekday, from: month)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        let shown = calendar.dateComponents([.year, .month], from: month)

        for day in days {
            let position = offset + day - 1
            let frame = CGRect(
                x: gridX + CGFloat(position % 7) * Self.cell,
                y: Self.gridTop + CGFloat(position / 7) * Self.cell,
                width: Self.cell, height: Self.cell
            )
            let isToday = today.year == shown.year && today.month == shown.month && today.day == day
            if isToday {
                context.setFillColor(Tokens.Color.accent.desktopCGColor)
                context.fillEllipse(in: frame.insetBy(dx: 4, dy: 4))
            }
            let isWeekend = position % 7 >= 5
            drawCentered(
                "\(day)", in: frame,
                font: Tokens.sans(13, weight: isToday ? .semibold : .regular),
                color: isToday ? .white : (isWeekend ? Tokens.Color.textSecondary : Tokens.Color.text)
            )
        }
    }

    private func drawCentered(_ text: String, in frame: CGRect, font: UIFont, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawSymbol(_ name: String, at center: CGPoint) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        guard let image = UIImage.crispSymbol(name, configuration: configuration, scale: card.layer.contentsScale)?
            .withTintColor(Tokens.Color.text.resolvedColor(with: UITraitCollection(userInterfaceStyle: DesktopTheme.style)),
                           renderingMode: .alwaysOriginal)
        else { return }
        image.draw(at: CGPoint(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2))
    }

    // MARK: - Entrada

    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        let local = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)
        switch kind {
        case .moved:
            let now: String? = previousFrame.contains(local) ? "prev" : (nextFrame.contains(local) ? "next" : nil)
            if now != hovered {
                hovered = now
                card.setNeedsDisplay()
            }
        case .down:
            guard card.frame.contains(point) else {
                onDismiss?()
                return true
            }
            if previousFrame.insetBy(dx: -3, dy: -3).contains(local) {
                move(months: -1)
            } else if nextFrame.insetBy(dx: -3, dy: -3).contains(local) {
                move(months: 1)
            } else if todayFrame.insetBy(dx: -6, dy: -6).contains(local) {
                month = startOfMonth(Date())
                card.setNeedsDisplay()
            }
        case .scroll(let delta):
            // La rueda también pasa de mes, como en macOS.
            if abs(delta.dy) > 20 { move(months: delta.dy > 0 ? -1 : 1) }
        default:
            break
        }
        return true
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }
        switch event.key.keyCode {
        case .keyboardEscape: onDismiss?()
        case .keyboardLeftArrow: move(months: -1)
        case .keyboardRightArrow: move(months: 1)
        default: break
        }
        return true
    }
}

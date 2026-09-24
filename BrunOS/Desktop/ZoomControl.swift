import UIKit

/// «−  125 %  +», el control de zoom de los visores (la vista previa de
/// Ficheros y el visor de Fotos). Lo pidió Bruno el 24-sep-2026: el PDF, las
/// fotos y los vídeos sólo se podían ampliar con Cmd + / −, sin nada a la
/// vista que dijera cómo ni cuánto.
///
/// Dibujado y resuelto por geometría, como todo en el monitor: quien lo lleva
/// le pregunta `hit(at:)` con el punto en sus coordenadas. Pulsar el
/// porcentaje vuelve a ajustar a la ventana.
@MainActor
final class ZoomControl: UIView {

    enum Action {
        case zoomOut, reset, zoomIn
    }

    /// Lo que se enseña en el medio, 1 = ajustado a la ventana.
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { setNeedsDisplay() } }
    }

    private var hovered: Action?

    static let size = CGSize(width: 132, height: 28)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    private var segments: [(Action, CGRect)] {
        let third = bounds.width / 4
        return [
            (.zoomOut, CGRect(x: 0, y: 0, width: third, height: bounds.height)),
            (.reset, CGRect(x: third, y: 0, width: third * 2, height: bounds.height)),
            (.zoomIn, CGRect(x: third * 3, y: 0, width: third, height: bounds.height)),
        ]
    }

    func hit(at point: CGPoint) -> Action? {
        guard bounds.insetBy(dx: -2, dy: -3).contains(point) else { return nil }
        return segments.first { $0.1.insetBy(dx: 0, dy: -3).contains(point) }?.0
    }

    func hover(at point: CGPoint?) {
        let now = point.flatMap(hit(at:))
        guard now != hovered else { return }
        hovered = now
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let pill = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: bounds.height / 2)
        context.setFillColor(Tokens.Color.panelElevated.desktopCGColor)
        context.addPath(pill.cgPath)
        context.fillPath()
        context.setStrokeColor(Tokens.Color.border.desktopCGColor)
        context.setLineWidth(1)
        context.addPath(pill.cgPath)
        context.strokePath()

        for (action, frame) in segments {
            if hovered == action {
                context.setFillColor(Tokens.Color.text.withAlphaComponent(0.08).desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), cornerRadius: (frame.height - 4) / 2).cgPath)
                context.fillPath()
            }
            let text = switch action {
            case .zoomOut: "−"
            case .zoomIn: "+"
            case .reset: "\(Int((zoom * 100).rounded())) %"
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: action == .reset ? Tokens.sans(12, weight: .medium) : Tokens.sans(16, weight: .semibold),
                .foregroundColor: action == .reset && zoom == 1 ? Tokens.Color.textSecondary : Tokens.Color.text,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}

/// El zoom de una imagen o un vídeo: ampliar desde el centro y moverse con la
/// rueda por lo ampliado sin salirse. Lo usan los dos visores.
@MainActor
struct ZoomState {
    private(set) var zoom: CGFloat = 1
    private(set) var pan: CGPoint = .zero

    static let steps: [CGFloat] = [1, 1.25, 1.5, 2, 3, 4, 6]

    mutating func step(_ direction: Int) {
        let index = Self.steps.lastIndex { $0 <= zoom + 0.001 } ?? 0
        let next = min(max(index + direction, 0), Self.steps.count - 1)
        zoom = Self.steps[next]
        if zoom == 1 { pan = .zero }
    }

    mutating func reset() {
        zoom = 1
        pan = .zero
    }

    /// Mueve lo ampliado, sin dejar ver más allá del borde.
    mutating func scroll(by delta: CGVector, in size: CGSize) {
        guard zoom > 1 else { return }
        let limitX = size.width * (zoom - 1) / 2
        let limitY = size.height * (zoom - 1) / 2
        pan.x = min(max(pan.x + delta.dx, -limitX), limitX)
        pan.y = min(max(pan.y + delta.dy, -limitY), limitY)
    }

    var transform: CGAffineTransform {
        CGAffineTransform(translationX: pan.x, y: pan.y).scaledBy(x: zoom, y: zoom)
    }
}

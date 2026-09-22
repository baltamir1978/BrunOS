import UIKit

/// La barra de Cmd+F: buscar en la página, en el terminal o filtrar ficheros.
///
/// Es la misma en los tres paneles, y cada uno decide qué hace con el texto.
/// Como todo lo de la pantalla externa, **no es un `UITextField`**: allí no hay
/// primer respondedor ni eventos del sistema, así que el teclado llega por el
/// `KeyboardRouter` y el texto se lleva a mano.
///
/// Intro va al siguiente resultado, Mayús+Intro al anterior y Esc cierra.
@MainActor
final class FindBar: UIView {

    static let height: CGFloat = 34

    /// El texto cambió: se busca desde el principio.
    var onChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private(set) var query = ""
    /// «2 de 14», «Sin resultados», «5 ficheros»… Lo pone quien busca.
    var status: String? {
        didSet { setNeedsDisplay() }
    }
    var placeholder = "Buscar"

    private enum Target { case previous, next, close }
    private var hovered: Target?
    private var frames: [Target: CGRect] = [:]
    private var fieldFrame: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Tokens.Color.panelElevated
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    /// Vacía la barra para una búsqueda nueva.
    func reset() {
        query = ""
        status = nil
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size: CGFloat = 24
        let y = (bounds.height - size) / 2
        frames[.close] = CGRect(x: bounds.width - size - 8, y: y, width: size, height: size)
        frames[.next] = CGRect(x: bounds.width - 2 * size - 14, y: y, width: size, height: size)
        frames[.previous] = CGRect(x: bounds.width - 3 * size - 16, y: y, width: size, height: size)
        let fieldWidth = min(bounds.width - 3 * size - 40, 460)
        fieldFrame = CGRect(x: 10, y: y, width: max(80, fieldWidth), height: size)
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

        // El campo, con el filete ámbar del foco: mientras la barra está
        // abierta, lo que se teclea va aquí.
        let field = UIBezierPath(roundedRect: fieldFrame, cornerRadius: 7)
        context.setFillColor(cg(Tokens.Color.background))
        context.addPath(field.cgPath)
        context.fillPath()
        context.setStrokeColor(cg(Tokens.Color.accent))
        context.setLineWidth(1.5)
        context.addPath(UIBezierPath(roundedRect: fieldFrame.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 7).cgPath)
        context.strokePath()

        drawSymbol("magnifyingglass", at: CGPoint(x: fieldFrame.minX + 14, y: fieldFrame.midY),
                   color: Tokens.Color.textSecondary)

        var statusWidth: CGFloat = 0
        if let status {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Tokens.sans(11.5),
                .foregroundColor: Tokens.Color.textSecondary,
            ]
            let size = (status as NSString).size(withAttributes: attributes)
            statusWidth = size.width + 12
            (status as NSString).draw(
                at: CGPoint(x: fieldFrame.maxX - size.width - 10, y: fieldFrame.midY - size.height / 2),
                withAttributes: attributes
            )
        }

        let textX = fieldFrame.minX + 28
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(13),
            .foregroundColor: query.isEmpty ? Tokens.Color.textSecondary : Tokens.Color.text,
        ]
        let shown = query.isEmpty ? placeholder : query
        let textSize = (shown as NSString).size(withAttributes: textAttributes)
        let available = fieldFrame.maxX - statusWidth - textX - 8
        // Si no cabe, se ve el final, que es donde se está escribiendo.
        context.saveGState()
        context.clip(to: CGRect(x: textX, y: fieldFrame.minY, width: max(0, available), height: fieldFrame.height))
        let x = textSize.width > available ? textX + available - textSize.width : textX
        (shown as NSString).draw(at: CGPoint(x: x, y: fieldFrame.midY - textSize.height / 2), withAttributes: textAttributes)
        context.restoreGState()

        // Cursor de texto al final.
        let caretX = query.isEmpty ? textX : min(x + textSize.width + 1, textX + available)
        context.setFillColor(cg(Tokens.Color.accent))
        context.fill(CGRect(x: caretX, y: fieldFrame.midY - 8, width: 1.5, height: 16))

        for (target, symbol) in [(Target.previous, "chevron.up"), (.next, "chevron.down"), (.close, "xmark")] {
            guard let frame = frames[target] else { continue }
            if hovered == target {
                context.setFillColor(cg(Tokens.Color.text.withAlphaComponent(0.08)))
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
                context.fillPath()
            }
            drawSymbol(symbol, at: CGPoint(x: frame.midX, y: frame.midY),
                       color: hovered == target ? Tokens.Color.text : Tokens.Color.textSecondary)
        }
    }

    private func drawSymbol(_ name: String, at center: CGPoint, color: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
        guard let image = UIImage.crispSymbol(name, configuration: configuration, scale: layer.contentsScale)?
            .withTintColor(color.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        else { return }
        image.draw(at: CGPoint(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2))
    }

    // MARK: - Entrada

    /// En coordenadas de la barra.
    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) {
        let target = frames.first { $0.value.insetBy(dx: -3, dy: -3).contains(point) }?.key
        switch kind {
        case .moved:
            if hovered != target {
                hovered = target
                setNeedsDisplay()
            }
        case .down(let button) where button == .left:
            switch target {
            case .previous: onPrevious?()
            case .next: onNext?()
            case .close: onClose?()
            case nil: break
            }
        default:
            break
        }
    }

    func handleKey(_ event: KeyEvent) {
        guard event.phase == .down else { return }
        switch event.key.keyCode {
        case .keyboardEscape:
            onClose?()
        case .keyboardReturnOrEnter, .keypadEnter:
            event.key.modifierFlags.contains(.shift) ? onPrevious?() : onNext?()
        case .keyboardDeleteOrBackspace:
            guard !query.isEmpty else { return }
            // Opción+Retroceso borra la palabra, como en cualquier campo de
            // macOS.
            if event.key.modifierFlags.contains(.alternate) {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                query = trimmed.range(of: " ", options: .backwards).map { String(trimmed[..<$0.upperBound]) } ?? ""
            } else {
                query.removeLast()
            }
            changed()
        default:
            let characters = event.key.characters
            guard !characters.isEmpty, !event.key.modifierFlags.contains(.command),
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return }
            query += characters
            changed()
        }
    }

    func insertText(_ text: String) {
        query += text.replacingOccurrences(of: "\n", with: " ")
        changed()
    }

    private func changed() {
        setNeedsDisplay()
        onChange?(query)
    }
}

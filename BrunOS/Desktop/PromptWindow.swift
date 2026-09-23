import UIKit

/// Un diálogo de una sola pregunta: escribir un nombre o confirmar algo.
///
/// Se usa para renombrar, crear carpeta y confirmar un borrado. Como el resto
/// de la pantalla externa, se dibuja y se resuelve por geometría; el campo de
/// texto es propio, porque aquí no hay first responder que valga.
@MainActor
final class PromptWindow: UIView {

    /// `nil` al cancelar.
    var onFinish: ((String?) -> Void)?

    private let title: String
    private let message: String?
    private let confirmTitle: String
    private let isDestructive: Bool
    /// Si es `false`, es una confirmación y no se escribe nada.
    private let asksForText: Bool

    private var text: String
    private let card = CardView()
    private var fieldFrame: CGRect = .zero
    private var cancelFrame: CGRect = .zero
    private var confirmFrame: CGRect = .zero

    init(
        title: String,
        message: String? = nil,
        value: String? = nil,
        confirmTitle: String = "Aceptar",
        destructive: Bool = false,
        frame: CGRect
    ) {
        self.title = title
        self.message = message
        self.text = value ?? ""
        self.asksForText = value != nil
        self.confirmTitle = confirmTitle
        self.isDestructive = destructive
        super.init(frame: frame)

        backgroundColor = UIColor.black.withAlphaComponent(0.55)

        card.backgroundColor = Tokens.Color.panelElevated
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 1
        card.setThemedBorder(Tokens.Color.border)
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.5
        card.layer.shadowRadius = 26
        card.layer.shadowOffset = CGSize(width: 0, height: 10)
        card.drawContent = { [weak self] in self?.drawCard(in: $0) }
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let width: CGFloat = min(bounds.width * 0.4, 440)
        let height: CGFloat = asksForText ? 158 : (message == nil ? 120 : 146)
        card.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: max(30, bounds.height * 0.32),
            width: width, height: height
        )

        fieldFrame = CGRect(x: 18, y: 64, width: width - 36, height: 32)
        confirmFrame = CGRect(x: width - 112, y: height - 46, width: 94, height: 32)
        cancelFrame = CGRect(x: width - 214, y: height - 46, width: 94, height: 32)
        card.setNeedsDisplay()
    }

    /// Lo llama la tarjeta desde su `draw(_:)`: ver `CardView`.
    private func drawCard(in context: CGContext) {
        let origin = card.frame.origin

        (title as NSString).draw(
            at: CGPoint(x: origin.x + 18, y: origin.y + 18),
            withAttributes: [
                .font: Tokens.sans(15, weight: .semibold),
                .foregroundColor: Tokens.Color.text,
            ]
        )

        if let message {
            (message as NSString).draw(
                in: CGRect(
                    x: origin.x + 18, y: origin.y + 44,
                    width: card.frame.width - 36, height: 40
                ),
                withAttributes: [
                    .font: Tokens.sans(12),
                    .foregroundColor: Tokens.Color.textSecondary,
                ]
            )
        }

        if asksForText {
            let frame = fieldFrame.offsetBy(dx: origin.x, dy: origin.y)
            let path = UIBezierPath(roundedRect: frame, cornerRadius: 7)
            context.setFillColor(Tokens.Color.background.desktopCGColor)
            context.addPath(path.cgPath)
            context.fillPath()
            context.setStrokeColor(Tokens.Color.accent.desktopCGColor)
            context.setLineWidth(1.5)
            context.addPath(path.cgPath)
            context.strokePath()

            ((text + "|") as NSString).draw(
                in: CGRect(x: frame.minX + 10, y: frame.midY - 9, width: frame.width - 20, height: 18),
                withAttributes: [
                    .font: Tokens.mono(13),
                    .foregroundColor: Tokens.Color.text,
                ]
            )
        }

        drawButton(cancelFrame, title: "Cancelar", tint: Tokens.Color.textSecondary, context: context)
        drawButton(
            confirmFrame,
            title: confirmTitle,
            tint: isDestructive ? UIColor(hex: 0xE05C4B) : Tokens.Color.accent,
            context: context,
            filled: true
        )
    }

    private func drawButton(
        _ localFrame: CGRect,
        title: String,
        tint: UIColor,
        context: CGContext,
        filled: Bool = false
    ) {
        let frame = localFrame.offsetBy(dx: card.frame.minX, dy: card.frame.minY)
        let path = UIBezierPath(roundedRect: frame, cornerRadius: 8)

        if filled {
            context.setFillColor(tint.desktopCGColor)
            context.addPath(path.cgPath)
            context.fillPath()
        } else {
            context.setStrokeColor(tint.withAlphaComponent(0.6).desktopCGColor)
            context.setLineWidth(1)
            context.addPath(path.cgPath)
            context.strokePath()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(13, weight: .medium),
            .foregroundColor: filled ? Tokens.Color.background : tint,
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    // MARK: - Entrada

    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        guard case .down = kind else { return true }
        guard card.frame.contains(point) else {
            // Pinchar fuera cancela. Nunca confirma: lo que se hace sin querer
            // no debería borrar nada.
            onFinish?(nil)
            return true
        }

        let inCard = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)
        if confirmFrame.contains(inCard) {
            onFinish?(asksForText ? text : "")
        } else if cancelFrame.contains(inCard) {
            onFinish?(nil)
        }
        return true
    }

    /// Escribir en el campo: lo tecleado y lo pegado con Cmd+V.
    func insertText(_ typed: String) {
        guard asksForText else { return }
        text += typed.trimmingCharacters(in: .newlines)
        card.setNeedsDisplay()
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }

        switch event.key.keyCode {
        case .keyboardEscape:
            onFinish?(nil)
        case .keyboardReturnOrEnter:
            onFinish?(asksForText ? text : "")
        case .keyboardDeleteOrBackspace:
            if asksForText, !text.isEmpty { text.removeLast() }
        default:
            if let typed = event.typedText { insertText(typed) }
        }
        card.setNeedsDisplay()
        return true
    }
}

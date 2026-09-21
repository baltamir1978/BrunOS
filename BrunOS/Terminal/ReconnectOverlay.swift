import UIKit

/// Aviso de sesión caída, con botón para volver a conectar.
///
/// El prompt pedía las dos vías: un botón y la tecla Intro. Intro sola no basta
/// cuando lo que tienes en la mano es el ratón y el teclado está en la mesa, y
/// el botón solo no basta cuando estás tecleando.
///
/// **No recibe eventos del sistema.** Como todo lo de la pantalla externa, el
/// escritorio le pregunta por geometría si el cursor está encima.
@MainActor
final class ReconnectOverlay: UIView {

    var onReconnect: (() -> Void)?

    private let messageLabel = UILabel()
    private let button = UIView()
    private let buttonLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Translúcido: debajo sigue estando lo que hubiera en el terminal, y
        // muchas veces ahí está la pista de por qué se cayó.
        backgroundColor = Tokens.Color.terminalBackground.withAlphaComponent(0.82)

        messageLabel.font = Tokens.sans(14)
        messageLabel.textColor = Tokens.Color.text
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        addSubview(messageLabel)

        button.backgroundColor = Tokens.Color.accent
        button.layer.cornerRadius = Tokens.Metric.controlCornerRadius
        addSubview(button)

        buttonLabel.font = Tokens.sans(14, weight: .semibold)
        buttonLabel.textColor = Tokens.Color.background
        buttonLabel.textAlignment = .center
        buttonLabel.text = "Reconectar"
        button.addSubview(buttonLabel)

        isAccessibilityElement = true
        accessibilityLabel = "Sesión caída. Reconectar."
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    func update(message: String) {
        messageLabel.text = message + "\n\nTambién puedes pulsar Intro."
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = min(bounds.width - 48, 420)
        let messageHeight = messageLabel.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height

        messageLabel.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: bounds.midY - messageHeight / 2 - 30,
            width: width,
            height: messageHeight
        )

        button.frame = CGRect(
            x: (bounds.width - 140) / 2,
            y: messageLabel.frame.maxY + 18,
            width: 140,
            height: 34
        )
        buttonLabel.frame = button.bounds
    }

    /// Si el punto cae en el botón, en coordenadas de esta vista.
    func hitsButton(_ point: CGPoint) -> Bool {
        button.frame.insetBy(dx: -6, dy: -6).contains(point)
    }
}

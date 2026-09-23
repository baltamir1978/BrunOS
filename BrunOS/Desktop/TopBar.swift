import UIKit

/// Barra superior del escritorio: 34 pt lógicos de izquierda a derecha con
/// marca, título del panel con foco, resolución, anuncios
/// bloqueados, batería y hora.
///
/// **No recibe eventos del sistema**, porque nada en la pantalla externa los
/// recibe. Pero sí responde al ratón: el escritorio le pregunta por geometría
/// qué hay bajo el cursor.
@MainActor
final class TopBar: UIView {

    private let brandLabel = UILabel()
    private let titleLabel = UILabel()
    private let resolutionLabel = UILabel()
    private let blockedLabel = UILabel()
    private let batteryLabel = UILabel()
    private let clockLabel = UILabel()

    private var clockTimer: Timer?

    /// Lo que hay bajo un punto de la barra.
    ///
    /// **Todo lo que se ve tiene que poder pulsarse**: un rótulo que parece un
    /// botón y no responde es peor que no ponerlo. Se resuelve por geometría y
    /// no con `hitTest`, porque los toques no llegan por UIKit: los entrega el
    /// escritorio desde su propio cursor.
    enum Target {
        /// La marca abre el lanzador, como el menú de una esquina.
        case brand
        /// La resolución lleva a los ajustes de pantalla.
        case display
        case none
    }

    func hit(at point: CGPoint) -> Target {
        // Con holgura: acertar a pulso en una etiqueta de 12 pt es incómodo.
        if brandLabel.frame.insetBy(dx: -6, dy: -4).contains(point) { return .brand }
        if resolutionLabel.frame.insetBy(dx: -6, dy: -4).contains(point) { return .display }
        return .none
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Tokens.Color.panel

        let separator = UIView()
        separator.backgroundColor = Tokens.Color.border
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        brandLabel.attributedText = Self.brandText(size: 15)

        for label in [titleLabel, resolutionLabel, blockedLabel, batteryLabel, clockLabel] {
            label.font = Tokens.mono(12)
            label.textColor = Tokens.Color.textSecondary
        }
        titleLabel.textColor = Tokens.Color.text
        titleLabel.font = Tokens.sans(13, weight: .medium)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        blockedLabel.textColor = Tokens.Color.accentAlt

        let spacerLeft = UIView()
        let spacerRight = UIView()
        let stack = UIStackView(arrangedSubviews: [
            brandLabel, spacerLeft, titleLabel, spacerRight,
            resolutionLabel, blockedLabel, batteryLabel, clockLabel,
        ])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            spacerLeft.widthAnchor.constraint(equalTo: spacerRight.widthAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        UIDevice.current.isBatteryMonitoringEnabled = true
        startClock()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    /// `isolated deinit` (Swift 6.2) hace falta aquí: `Timer` no es `Sendable`,
    /// y desde un `deinit` corriente, que no está aislado a ningún actor, Swift 6
    /// no deja ni leer la propiedad para invalidarla.
    isolated deinit {
        clockTimer?.invalidate()
    }

    /// `brunOS_` con el guion bajo en ámbar.
    static func brandText(size: CGFloat) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "brunOS",
            attributes: [.font: Tokens.mono(size, bold: true), .foregroundColor: Tokens.Color.text]
        )
        text.append(NSAttributedString(
            string: "_",
            attributes: [.font: Tokens.mono(size, bold: true), .foregroundColor: Tokens.Color.accent]
        ))
        return text
    }

    // MARK: - Contenido

    func update(desktop: DesktopModel, profile: DisplayProfile?, blockedCount: Int?) {
        titleLabel.text = desktop.active.focusedPane?.title ?? "Sin paneles"
        resolutionLabel.text = profile?.summary ?? "sin pantalla"

        if let blockedCount {
            blockedLabel.text = "\(blockedCount) bloqueados"
            blockedLabel.isHidden = false
        } else {
            blockedLabel.isHidden = true
        }

        updateBattery()
        updateClock()
    }

    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        // Devuelve -1 cuando el sistema todavía no lo sabe, y rotular "-100 %"
        // quedaría ridículo.
        batteryLabel.text = level < 0 ? "—" : "\(Int(level * 100)) %"
    }

    private func startClock() {
        updateClock()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func updateClock() {
        clockLabel.text = Date().formatted(date: .omitted, time: .shortened)
    }
}

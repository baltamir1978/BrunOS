import UIKit

/// Barra superior del escritorio: 34 pt lógicos de izquierda a derecha con
/// marca, título del panel con foco, Tailscale, el tiempo, resolución,
/// batería y hora.
///
/// **No recibe eventos del sistema**, porque nada en la pantalla externa los
/// recibe. Pero sí responde al ratón: el escritorio le pregunta por geometría
/// qué hay bajo el cursor.
@MainActor
final class TopBar: UIView {

    private let brandLabel = UILabel()
    private let titleLabel = UILabel()
    private let resolutionLabel = UILabel()
    /// Tailscale: su logo de nueve puntos, con la «T» encendida si parece
    /// conectado y todo en gris si no. Ver `tailscaleLogo`.
    private let tailscaleLabel = UILabel()
    /// El tiempo: icono y temperatura, como en la barra de macOS.
    private let weatherLabel = UILabel()
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
        /// Estado de Tailscale y el menú para conectar o desconectar.
        case tailscale
        /// El desplegable del tiempo.
        case weather
        /// La hora abre un calendario del mes.
        case clock
        case none
    }

    func hit(at point: CGPoint) -> Target {
        // Con holgura: acertar a pulso en una etiqueta de 12 pt es incómodo.
        if brandLabel.frame.insetBy(dx: -6, dy: -4).contains(point) { return .brand }
        if resolutionLabel.frame.insetBy(dx: -6, dy: -4).contains(point) { return .display }
        if tailscaleLabel.frame.insetBy(dx: -6, dy: -4).contains(point) { return .tailscale }
        if weatherLabel.frame.insetBy(dx: -6, dy: -4).contains(point) { return .weather }
        if clockLabel.frame.insetBy(dx: -6, dy: -4).contains(point) { return .clock }
        return .none
    }

    /// Dónde está un elemento, para colgar de él su menú o su desplegable.
    func itemFrame(_ target: Target) -> CGRect {
        switch target {
        case .tailscale: tailscaleLabel.frame
        case .weather: weatherLabel.frame
        case .display: resolutionLabel.frame
        case .brand: brandLabel.frame
        case .clock: clockLabel.frame
        case .none: .zero
        }
    }

    /// Opaca por defecto; cuánto se transparenta, en Ajustes › General.
    private let backdrop = BarBackdrop(fill: Tokens.Color.panel)

    func applyTranslucency() {
        backdrop.apply(DesktopPreferences.topBarTranslucency)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        applyTranslucency()

        let separator = UIView()
        separator.backgroundColor = Tokens.Color.border
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        brandLabel.attributedText = Self.brandText(size: 15)

        for label in [titleLabel, resolutionLabel, batteryLabel, clockLabel] {
            label.font = Tokens.mono(12)
            label.textColor = Tokens.Color.textSecondary
        }
        titleLabel.textColor = Tokens.Color.text
        titleLabel.font = Tokens.sans(13, weight: .medium)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacerLeft = UIView()
        let spacerRight = UIView()
        let stack = UIStackView(arrangedSubviews: [
            brandLabel, spacerLeft, titleLabel, spacerRight,
            tailscaleLabel, weatherLabel, resolutionLabel, batteryLabel, clockLabel,
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
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        UIDevice.current.isBatteryMonitoringEnabled = true
        startClock()

        weatherLabel.font = Tokens.mono(12)
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged), name: TailscaleMonitor.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged), name: WeatherService.didChange, object: nil
        )
        updateStatus()
    }

    @objc private func statusChanged() {
        updateStatus()
    }

    /// Un símbolo del sistema seguido de un texto, en una sola etiqueta.
    private static func symbolText(_ symbol: String, color: UIColor, text: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = UIImage(systemName: symbol, withConfiguration: configuration)?
            .withTintColor(
                color.resolvedColor(with: UITraitCollection(userInterfaceStyle: DesktopTheme.style)),
                renderingMode: .alwaysOriginal
            ) {
            let attachment = NSTextAttachment(image: image)
            attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
            result.append(NSAttributedString(attachment: attachment))
        }
        if let text {
            result.append(NSAttributedString(string: " " + text, attributes: [
                .font: Tokens.mono(12), .foregroundColor: Tokens.Color.textSecondary,
            ]))
        }
        return result
    }

    /// El logo de Tailscale, como en su icono de la barra de menús de macOS:
    /// una rejilla de 3 × 3 puntos. Conectado, la «T» (la fila del medio y el
    /// de abajo en el centro) va en el color del texto —blanca en oscuro— y
    /// el resto apagado; desconectado, los nueve en gris.
    ///
    /// Se dibuja a mano: no hay símbolo del sistema con esa forma, y el logo
    /// de Tailscale no se puede traer al repositorio.
    private static func tailscaleLogo(connected: Bool) -> NSTextAttachment {
        let attachment = NSTextAttachment(image: tailscaleImage(connected: connected, style: DesktopTheme.style))
        attachment.bounds = CGRect(origin: CGPoint(x: 0, y: -2), size: attachment.image?.size ?? .zero)
        return attachment
    }

    /// `updateStatus` corre con cada cambio de título: la imagen se hace una
    /// vez por estado y modo.
    private static var tailscaleImages: [String: UIImage] = [:]

    private static func tailscaleImage(connected: Bool, style userStyle: UIUserInterfaceStyle) -> UIImage {
        let key = "\(connected)|\(userStyle.rawValue)"
        if let cached = tailscaleImages[key] { return cached }
        let style = UITraitCollection(userInterfaceStyle: userStyle)
        let bright = Tokens.Color.text.resolvedColor(with: style)
        let grey = Tokens.Color.textSecondary.resolvedColor(with: style)
        // Desconectado, los nueve iguales: grises, pero que se vean.
        let dim = connected ? bright.withAlphaComponent(0.3) : grey.withAlphaComponent(0.7)
        let lit: Set<Int> = connected ? [3, 4, 5, 7] : []

        let dot: CGFloat = 3.4
        let step: CGFloat = 4.8
        let side = dot + step * 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            for index in 0..<9 {
                let rect = CGRect(x: CGFloat(index % 3) * step, y: CGFloat(index / 3) * step, width: dot, height: dot)
                context.cgContext.setFillColor((lit.contains(index) ? bright : dim).cgColor)
                context.cgContext.fillEllipse(in: rect)
            }
        }
        tailscaleImages[key] = image
        return image
    }

    /// Lo último que se rotuló en Tailscale y el tiempo. `update` corre en
    /// cada maquetación del escritorio, y rehacer las etiquetas con imágenes
    /// obliga a volver a maquetar la barra aunque no haya cambiado nada.
    private var statusKey = ""

    private func updateStatus() {
        let tailscale = AppServices.shared.tailscale
        let waiting = tailscale.lastToggle == .waiting
        let weather = AppServices.shared.weather
        let weatherKey = weather.forecast.map {
            "\($0.code)|\($0.isDay)|\(WeatherService.degrees($0.temperature))|\(weather.places.count > 1 ? weather.place?.name ?? "" : "")"
        } ?? "none|\(weather.place == nil)"
        let key = "\(tailscale.isLikelyUp)|\(waiting)|\(DesktopTheme.style.rawValue)|\(weatherKey)"
        guard key != statusKey else { return }
        statusKey = key

        let logo = NSMutableAttributedString()
        logo.append(NSAttributedString(attachment: Self.tailscaleLogo(connected: tailscale.isLikelyUp)))
        if waiting {
            logo.append(NSAttributedString(string: " …", attributes: [
                .font: Tokens.mono(12), .foregroundColor: Tokens.Color.textSecondary,
            ]))
        }
        tailscaleLabel.attributedText = logo

        if let forecast = weather.forecast {
            // Con varias ciudades, también cuál: si no, 21° no dice de dónde.
            let degrees = WeatherService.degrees(forecast.temperature)
            let city = weather.places.count > 1 ? weather.place.map { " \($0.name)" } ?? "" : ""
            weatherLabel.attributedText = Self.symbolText(
                WeatherService.symbol(for: forecast.code, isDay: forecast.isDay),
                color: Tokens.Color.text,
                text: degrees + city
            )
        } else {
            weatherLabel.attributedText = Self.symbolText(
                "cloud.sun", color: Tokens.Color.textSecondary,
                text: weather.place == nil ? "El tiempo" : nil
            )
        }
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

    func update(desktop: DesktopModel, profile: DisplayProfile?) {
        // Sin ventanas no se rotula nada: «Sin paneles» no decía nada útil.
        setText(titleLabel, desktop.active.focusedPane?.title ?? "")
        setText(resolutionLabel, profile?.summary ?? "sin pantalla")

        updateBattery()
        updateClock()
        updateStatus()
    }

    /// Sólo si cambia: esto corre en cada maquetación del escritorio, y una
    /// etiqueta que cambia de texto vuelve a maquetar la barra.
    private func setText(_ label: UILabel, _ text: String) {
        if label.text != text { label.text = text }
    }

    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        // Devuelve -1 cuando el sistema todavía no lo sabe, y rotular "-100 %"
        // quedaría ridículo.
        setText(batteryLabel, level < 0 ? "—" : "\(Int(level * 100)) %")
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
        setText(clockLabel, Date().formatted(date: .omitted, time: .shortened))
    }
}

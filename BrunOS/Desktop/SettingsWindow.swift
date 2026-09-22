import UIKit

/// Ajustes en la pantalla externa.
///
/// **Existe porque el iPhone se apaga.** Con monitor conectado, el teléfono
/// pasa a ser sólo superficie táctil: si tuviera controles, el clic izquierdo
/// —que AssistiveTouch convierte en un toque sobre el propio teléfono— acabaría
/// pulsándolos en vez de llegar al escritorio. Así que los ajustes tienen que
/// estar donde se está mirando.
///
/// Como todo lo de la pantalla externa, **no recibe eventos del sistema**: el
/// escritorio le pasa el cursor y las teclas, y aquí se resuelve por geometría.
@MainActor
final class SettingsWindow: UIView {

    var onDismiss: (() -> Void)?
    /// Abrir el editor de máquinas. Lo resuelve el escritorio, que es quien
    /// sabe poner ventanas encima.
    var onEditHost: ((SSHHost?) -> Void)?

    /// Una fila: su rótulo, lo que vale ahora y qué hacer al pulsarla.
    private struct Row {
        var title: String
        var value: String
        var isHeader = false
        /// Una segunda acción a la derecha del valor, si la fila la tiene.
        var secondary: String?
        var secondaryAction: (() -> Void)?
        var action: (() -> Void)?
    }

    private let services = AppServices.shared
    private let card = CardView()
    private let titleLabel = UILabel()
    private let closeLabel = UILabel()
    private var rows: [Row] = []
    private var rowFrames: [CGRect] = []
    private var secondaryFrames: [Int: CGRect] = [:]
    private var hoveredIndex: Int?
    private var closeFrame: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.5)

        card.backgroundColor = Tokens.Color.panelElevated
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 1
        card.layer.borderColor = Tokens.Color.border.desktopCGColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.5
        card.layer.shadowRadius = 26
        card.layer.shadowOffset = CGSize(width: 0, height: 10)
        card.drawContent = { [weak self] in self?.drawCard(in: $0) }
        addSubview(card)

        titleLabel.attributedText = TopBar.brandText(size: 17)
        card.addSubview(titleLabel)

        closeLabel.text = "✕"
        closeLabel.font = Tokens.sans(16)
        closeLabel.textColor = Tokens.Color.textSecondary
        closeLabel.textAlignment = .center
        card.addSubview(closeLabel)

        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Contenido

    /// Se reconstruye entero en cada cambio.
    ///
    /// Son veinte filas de texto: rehacerlas cuesta menos que llevar la cuenta
    /// de cuál hay que refrescar, y así lo que se ve nunca se queda viejo.
    private func rebuild() {
        var rows: [Row] = []

        rows.append(Row(title: "Pantalla", value: "", isHeader: true))
        if let profile = services.externalDisplay.currentProfile {
            rows.append(Row(title: "Resolución", value: profile.summary))
            rows.append(Row(title: "Escala", value: profile.scale.label) { [weak self] in
                self?.cycleScale()
            })
            rows.append(Row(title: "Overscan", value: profile.overscan.label) { [weak self] in
                self?.cycleOverscan()
            })
        }
        rows.append(Row(title: "Apariencia", value: DesktopTheme.appearance.label) { [weak self] in
            self?.cycleAppearance()
        })
        rows.append(Row(title: "Fondo", value: services.wallpaper.current.label) { [weak self] in
            self?.cycleWallpaper()
        })

        rows.append(Row(title: "Ratón", value: "", isHeader: true))
        let pointer = services.pointer.settings
        rows.append(Row(title: "Fuente activa", value: services.mouse.activeSourceName))
        rows.append(Row(
            title: "Sensibilidad",
            value: String(format: "%.1f×", pointer.sensitivity)
        ) { [weak self] in
            self?.cycleSensitivity()
        })
        rows.append(Row(
            title: "Aceleración",
            value: pointer.acceleration ? "sí" : "no"
        ) { [weak self] in
            self?.toggleAcceleration()
        })
        rows.append(Row(
            title: "Scroll natural",
            value: pointer.naturalScrolling ? "sí" : "no"
        ) { [weak self] in
            self?.toggleNaturalScrolling()
        })

        rows.append(Row(title: "Navegador", value: "", isHeader: true))
        rows.append(Row(
            title: "Bloquear anuncios",
            value: services.blocker.isEnabled
                ? (services.blocker.isReady ? "sí" : "sin listas")
                : "no"
        ) { [weak self] in
            self?.toggleBlocker()
        })

        rows.append(Row(title: "Buscador", value: SearchEngine.current.label) { [weak self] in
            self?.cycleSearchEngine()
        })

        rows.append(Row(title: "SSH", value: "", isHeader: true))
        if services.hosts.hosts.isEmpty {
            rows.append(Row(title: "Sin máquinas todavía", value: ""))
        } else {
            for host in services.hosts.hosts {
                // Pulsar conecta, que es lo que se hace noventa y nueve veces
                // de cada cien; para editar está el lápiz de al lado.
                rows.append(Row(
                    title: host.displayName,
                    value: "conectar",
                    secondary: "editar",
                    secondaryAction: { [weak self] in self?.onEditHost?(host) }
                ) { [weak self] in
                    self?.connect(to: host)
                })
            }
        }
        rows.append(Row(title: "Añadir máquina", value: "+") { [weak self] in
            self?.onEditHost?(nil)
        })
        rows.append(Row(
            title: "Tailscale",
            value: services.tailscale.isLikelyUp ? "parece activo" : "no detectado"
        ))

        self.rows = rows
        setNeedsLayout()
        card.setNeedsDisplay()
    }

    // MARK: - Acciones

    private func cycleScale() {
        guard let current = services.externalDisplay.currentProfile?.scale,
              let index = DisplayProfile.Scale.allCases.firstIndex(of: current)
        else { return }
        let all = DisplayProfile.Scale.allCases
        services.externalDisplay.setScale(all[(index + 1) % all.count])
        rebuild()
    }

    private func cycleOverscan() {
        guard let current = services.externalDisplay.currentProfile?.overscan,
              let index = DisplayProfile.Overscan.allCases.firstIndex(of: current)
        else { return }
        let all = DisplayProfile.Overscan.allCases
        services.externalDisplay.setOverscan(all[(index + 1) % all.count])
        rebuild()
    }

    private func cycleWallpaper() {
        let all = services.wallpaper.available
        guard let index = all.firstIndex(of: services.wallpaper.current) else { return }
        services.wallpaper.current = all[(index + 1) % all.count]
        rebuild()
    }

    private func cycleAppearance() {
        let all = DesktopAppearance.allCases
        let index = all.firstIndex(of: DesktopTheme.appearance) ?? 0
        DesktopTheme.appearance = all[(index + 1) % all.count]
        // El borde de la tarjeta es un `CGColor`: no cambia solo.
        card.layer.borderColor = Tokens.Color.border.desktopCGColor
        rebuild()
    }

    private func cycleSearchEngine() {
        let all = SearchEngine.allCases
        let index = all.firstIndex(of: SearchEngine.current) ?? 0
        SearchEngine.current = all[(index + 1) % all.count]
        rebuild()
    }

    /// Recorre los valores útiles en vez de ofrecer un deslizador.
    ///
    /// Un deslizador con el cursor propio es incómodo de arrastrar; pulsar para
    /// pasar al siguiente valor va mucho mejor con un ratón.
    private func cycleSensitivity() {
        let steps: [Double] = [0.6, 0.8, 1.0, 1.3, 1.6, 2.0, 2.5]
        var settings = services.pointer.settings
        let next = steps.first { $0 > settings.sensitivity + 0.01 } ?? steps[0]
        settings.sensitivity = next
        apply(settings)
    }

    private func toggleAcceleration() {
        var settings = services.pointer.settings
        settings.acceleration.toggle()
        apply(settings)
    }

    private func toggleNaturalScrolling() {
        var settings = services.pointer.settings
        settings.naturalScrolling.toggle()
        apply(settings)
    }

    private func apply(_ settings: PointerSettings) {
        services.pointer.settings = settings
        settings.save()
        rebuild()
    }

    private func toggleBlocker() {
        services.blocker.isEnabled.toggle()
        rebuild()
    }

    private func connect(to host: SSHHost) {
        onDismiss?()
        AppServices.shared.desktopViewController?.connectTerminal(to: host)
    }

    // MARK: - Maquetación

    private static let rowHeight: CGFloat = 30
    private static let headerHeight: CGFloat = 32

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = min(bounds.width * 0.46, 520)
        var height: CGFloat = 54
        for row in rows {
            height += row.isHeader ? Self.headerHeight : Self.rowHeight
        }
        height += 14

        card.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: max(30, (bounds.height - height) / 2),
            width: width,
            height: min(height, bounds.height - 60)
        )

        titleLabel.frame = CGRect(x: 18, y: 16, width: width - 60, height: 22)
        closeFrame = CGRect(x: width - 40, y: 14, width: 26, height: 26)
        closeLabel.frame = closeFrame

        var y: CGFloat = 50
        rowFrames = rows.map { row in
            let height = row.isHeader ? Self.headerHeight : Self.rowHeight
            let frame = CGRect(x: 10, y: y, width: width - 20, height: height)
            y += height
            return frame
        }
        card.setNeedsDisplay()
    }

    /// Lo llama la tarjeta desde su `draw(_:)`: ver `CardView`.
    private func drawCard(in context: CGContext) {
        let origin = card.frame.origin

        for (index, row) in rows.enumerated() {
            var frame = rowFrames[index]
            frame.origin.x += origin.x
            frame.origin.y += origin.y

            if row.isHeader {
                guard !row.title.isEmpty else { continue }
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: Tokens.sans(11, weight: .semibold),
                    .foregroundColor: Tokens.Color.textSecondary,
                ]
                (row.title.uppercased() as NSString).draw(
                    in: CGRect(x: frame.minX + 8, y: frame.maxY - 18, width: frame.width, height: 14),
                    withAttributes: attributes
                )
                continue
            }

            // Sólo se resalta lo que se puede pulsar: si todo se iluminara,
            // el resalte dejaría de significar nada.
            if index == hoveredIndex, row.action != nil {
                context.setFillColor(Tokens.Color.accent.withAlphaComponent(0.16).desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 7).cgPath)
                context.fillPath()
            }

            (row.title as NSString).draw(
                in: CGRect(x: frame.minX + 10, y: frame.midY - 9, width: frame.width * 0.6, height: 18),
                withAttributes: [
                    .font: Tokens.sans(14),
                    .foregroundColor: Tokens.Color.text,
                ]
            )

            var right = frame.maxX - 12

            if let secondary = row.secondary {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: Tokens.sans(12),
                    .foregroundColor: Tokens.Color.textSecondary,
                ]
                let text = secondary as NSString
                let size = text.size(withAttributes: attributes)
                let position = CGPoint(x: right - size.width, y: frame.midY - size.height / 2)
                text.draw(at: position, withAttributes: attributes)
                secondaryFrames[index] = CGRect(
                    x: position.x - card.frame.minX - 6,
                    y: frame.minY - card.frame.minY,
                    width: size.width + 12,
                    height: frame.height
                )
                right = position.x - 14
            }

            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: Tokens.mono(12),
                .foregroundColor: row.action == nil
                    ? Tokens.Color.textSecondary
                    : Tokens.Color.accent,
            ]
            let value = row.value as NSString
            let size = value.size(withAttributes: valueAttributes)
            value.draw(
                at: CGPoint(x: right - size.width, y: frame.midY - size.height / 2),
                withAttributes: valueAttributes
            )
        }
    }

    // MARK: - Entrada

    /// Devuelve `true` si consumió el evento.
    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        guard card.frame.contains(point) else {
            if case .down = kind { onDismiss?() }
            return true
        }

        let inCard = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)

        if closeFrame.insetBy(dx: -6, dy: -6).contains(inCard) {
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
        case .down:
            // Lo secundario se mira primero: cae dentro de la fila y, si no,
            // lo taparía siempre la acción principal.
            if let index, let frame = secondaryFrames[index], frame.contains(inCard) {
                rows[index].secondaryAction?()
            } else if let index, let action = rows[index].action {
                action()
            }
        default:
            break
        }
        return true
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }
        if event.key.keyCode == .keyboardEscape {
            onDismiss?()
        }
        return true
    }

    /// Refresca lo que se ve cuando algo cambia por fuera.
    func refresh() {
        rebuild()
    }
}

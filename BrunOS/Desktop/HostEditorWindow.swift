import UIKit

/// Alta y edición de máquinas SSH, en la pantalla externa.
///
/// Estaba en el iPhone porque pide teclear, pero el teléfono se apaga cuando
/// hay monitor, así que teclear allí ya no es cómodo: hay que mirar a otro
/// sitio. Aquí se escribe con el mismo teclado con el que se trabaja.
///
/// **Los campos de texto son propios**, no `UITextField`. En la pantalla
/// externa no hay eventos del sistema ni first responder que valga: el teclado
/// llega por el `KeyboardRouter` de la escena del iPhone y aquí se reparte a
/// mano entre los campos. Es el mismo mecanismo que la barra de direcciones del
/// navegador.
@MainActor
final class HostEditorWindow: UIView {

    var onDismiss: (() -> Void)?

    private enum Field: Int, CaseIterable {
        case name, host, username, port, authentication, password, initialCommand

        var label: String {
            switch self {
            case .name: "Nombre"
            case .host: "Host"
            case .username: "Usuario"
            case .port: "Puerto"
            case .authentication: "Autenticación"
            case .password: "Contraseña"
            case .initialCommand: "Comando inicial"
            }
        }

        var placeholder: String {
            switch self {
            case .name: "homelab"
            case .host: "homelab o 192.168.1.50"
            case .username: "bruno"
            case .port: "22"
            case .authentication: ""
            case .password: "guardada en el Keychain"
            case .initialCommand: "tmux new -As main"
            }
        }

        /// Los que se escriben. `authentication` se alterna a pulsaciones.
        var isEditable: Bool { self != .authentication }
    }

    private enum Button: Int {
        case cancel, delete, save
    }

    private var host: SSHHost
    private let isNew: Bool
    private var password = ""
    private var passwordTouched = false
    private var focusedField: Field = .name
    private var error: String?

    private let card = CardView()
    private let titleLabel = UILabel()
    private var fieldFrames: [Field: CGRect] = [:]
    private var buttonFrames: [Button: CGRect] = [:]
    private var hovered: Field?

    init(host: SSHHost?, frame: CGRect) {
        self.host = host ?? SSHHost()
        self.isNew = host == nil
        super.init(frame: frame)

        backgroundColor = UIColor.black.withAlphaComponent(0.55)

        card.backgroundColor = Tokens.Color.panelElevated
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 1
        card.setThemedBorder(Tokens.Color.border)
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.55
        card.layer.shadowRadius = 28
        card.layer.shadowOffset = CGSize(width: 0, height: 10)
        card.drawContent = { [weak self] in self?.drawCard(in: $0) }
        addSubview(card)

        titleLabel.font = Tokens.sans(17, weight: .semibold)
        titleLabel.textColor = Tokens.Color.text
        titleLabel.text = isNew ? "Nueva máquina" : "Editar máquina"
        card.addSubview(titleLabel)

        if !isNew {
            password = ""
            passwordTouched = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Maquetación

    private static let rowHeight: CGFloat = 40

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = min(bounds.width * 0.5, 540)
        let visible = Field.allCases.filter(isVisible)
        let height = 58 + CGFloat(visible.count) * Self.rowHeight + 66

        card.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: max(24, (bounds.height - height) / 2),
            width: width,
            height: height
        )
        titleLabel.frame = CGRect(x: 20, y: 18, width: width - 40, height: 24)

        var y: CGFloat = 54
        fieldFrames = [:]
        for field in visible {
            fieldFrames[field] = CGRect(x: 16, y: y, width: width - 32, height: Self.rowHeight - 6)
            y += Self.rowHeight
        }

        // Borrar a la izquierda, lejos de Guardar: son irreversibles y no
        // conviene tenerlos pegados.
        let buttonY = height - 52
        buttonFrames = [
            .delete: isNew
                ? .zero
                : CGRect(x: 16, y: buttonY, width: 90, height: 32),
            .cancel: CGRect(x: width - 200, y: buttonY, width: 86, height: 32),
            .save: CGRect(x: width - 106, y: buttonY, width: 90, height: 32),
        ]
        card.setNeedsDisplay()
    }

    private func isVisible(_ field: Field) -> Bool {
        // La contraseña sólo tiene sentido con ese método de autenticación.
        field != .password || host.authentication == .password
    }

    // MARK: - Dibujo

    /// Lo llama la tarjeta desde su `draw(_:)`: ver `CardView`.
    private func drawCard(in context: CGContext) {
        let origin = card.frame.origin

        for (field, localFrame) in fieldFrames {
            let frame = localFrame.offsetBy(dx: origin.x, dy: origin.y)
            drawField(field, in: frame, context: context)
        }

        drawButton(.cancel, title: "Cancelar", tint: Tokens.Color.textSecondary, context: context)
        if !isNew {
            drawButton(.delete, title: "Borrar", tint: UIColor(hex: 0xE05C4B), context: context)
        }
        drawButton(.save, title: "Guardar", tint: Tokens.Color.accent, context: context, filled: true)

        if let error {
            (error as NSString).draw(
                at: CGPoint(x: origin.x + 16, y: origin.y + card.frame.height - 76),
                withAttributes: [
                    .font: Tokens.sans(12),
                    .foregroundColor: UIColor(hex: 0xE05C4B),
                ]
            )
        }

        let hint = "Tab para pasar de campo · Intro para guardar · Esc para salir"
        (hint as NSString).draw(
            at: CGPoint(x: origin.x + 16, y: origin.y + card.frame.height - 20),
            withAttributes: [
                .font: Tokens.sans(10),
                .foregroundColor: Tokens.Color.textSecondary,
            ]
        )
    }

    private func drawField(_ field: Field, in frame: CGRect, context: CGContext) {
        let isFocused = field == focusedField

        (field.label as NSString).draw(
            at: CGPoint(x: frame.minX + 2, y: frame.midY - 7),
            withAttributes: [
                .font: Tokens.sans(13),
                .foregroundColor: isFocused ? Tokens.Color.accent : Tokens.Color.textSecondary,
            ]
        )

        let box = CGRect(
            x: frame.minX + frame.width * 0.32, y: frame.minY,
            width: frame.width * 0.68, height: frame.height
        )
        let path = UIBezierPath(roundedRect: box, cornerRadius: 7)
        context.setFillColor(Tokens.Color.background.desktopCGColor)
        context.addPath(path.cgPath)
        context.fillPath()

        context.setStrokeColor(
            (isFocused ? Tokens.Color.accent : Tokens.Color.border).desktopCGColor
        )
        context.setLineWidth(isFocused ? 1.5 : 1)
        context.addPath(path.cgPath)
        context.strokePath()

        let shown = displayValue(for: field)
        let isPlaceholder = shown.isEmpty
        let text = (isPlaceholder ? field.placeholder : shown)
            + (isFocused && field.isEditable ? "|" : "")

        (text as NSString).draw(
            in: CGRect(x: box.minX + 10, y: box.midY - 9, width: box.width - 20, height: 18),
            withAttributes: [
                .font: Tokens.mono(13),
                .foregroundColor: isPlaceholder
                    ? Tokens.Color.textSecondary
                    : Tokens.Color.text,
            ]
        )
    }

    private func displayValue(for field: Field) -> String {
        switch field {
        case .name: host.name
        case .host: host.host
        case .username: host.username
        case .port: String(host.port)
        case .authentication: host.authentication.label
        // La contraseña nunca se enseña en claro en una pantalla que puede
        // tener a alguien delante.
        case .password: passwordTouched
            ? String(repeating: "•", count: password.count)
            : (SSHKeychain.hasPassword(for: host) ? "••••••••" : "")
        case .initialCommand: host.initialCommand
        }
    }

    private func drawButton(
        _ button: Button,
        title: String,
        tint: UIColor,
        context: CGContext,
        filled: Bool = false
    ) {
        guard let localFrame = buttonFrames[button], localFrame != .zero else { return }
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
        guard card.frame.contains(point) else {
            if case .down = kind { onDismiss?() }
            return true
        }
        guard case .down = kind else { return true }

        let inCard = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)

        for (button, frame) in buttonFrames where frame != .zero && frame.contains(inCard) {
            switch button {
            case .cancel: onDismiss?()
            case .delete: delete()
            case .save: save()
            }
            return true
        }

        for (field, frame) in fieldFrames where frame.contains(inCard) {
            if field == .authentication {
                cycleAuthentication()
            } else {
                focusedField = field
            }
            card.setNeedsDisplay()
            return true
        }
        return true
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }

        switch event.key.keyCode {
        case .keyboardEscape:
            onDismiss?()
        case .keyboardReturnOrEnter:
            save()
        case .keyboardTab:
            moveFocus(by: event.key.modifierFlags.contains(.shift) ? -1 : 1)
        case .keyboardDownArrow:
            moveFocus(by: 1)
        case .keyboardUpArrow:
            moveFocus(by: -1)
        case .keyboardDeleteOrBackspace:
            deleteBackward()
        case .keyboardSpacebar where focusedField == .authentication:
            cycleAuthentication()
        default:
            insert(event.key.characters)
        }
        card.setNeedsDisplay()
        return true
    }

    private func moveFocus(by delta: Int) {
        let visible = Field.allCases.filter(isVisible)
        guard let index = visible.firstIndex(of: focusedField) else { return }
        focusedField = visible[(index + delta + visible.count) % visible.count]
    }

    private func cycleAuthentication() {
        let all = SSHHost.Authentication.allCases
        guard let index = all.firstIndex(of: host.authentication) else { return }
        host.authentication = all[(index + 1) % all.count]
        setNeedsLayout()
    }

    private func insert(_ characters: String) {
        guard !characters.isEmpty, focusedField.isEditable else { return }
        switch focusedField {
        case .name: host.name += characters
        case .host: host.host += characters.trimmingCharacters(in: .whitespaces)
        case .username: host.username += characters.trimmingCharacters(in: .whitespaces)
        case .port:
            // Sólo cifras: un puerto con letras no es un puerto.
            let digits = characters.filter(\.isNumber)
            guard !digits.isEmpty else { return }
            host.port = Int(String(host.port) + digits).map { min($0, 65_535) } ?? host.port
        case .password:
            passwordTouched = true
            password += characters
        case .initialCommand: host.initialCommand += characters
        case .authentication: break
        }
    }

    private func deleteBackward() {
        switch focusedField {
        case .name: if !host.name.isEmpty { host.name.removeLast() }
        case .host: if !host.host.isEmpty { host.host.removeLast() }
        case .username: if !host.username.isEmpty { host.username.removeLast() }
        case .port:
            let text = String(host.port)
            host.port = text.count > 1 ? Int(text.dropLast()) ?? 0 : 0
        case .password:
            passwordTouched = true
            if !password.isEmpty { password.removeLast() }
        case .initialCommand:
            if !host.initialCommand.isEmpty { host.initialCommand.removeLast() }
        case .authentication: break
        }
    }

    // MARK: - Guardar

    private func save() {
        guard !host.host.isEmpty else {
            error = "Falta el host."
            focusedField = .host
            card.setNeedsDisplay()
            return
        }
        guard !host.username.isEmpty else {
            error = "Falta el usuario."
            focusedField = .username
            card.setNeedsDisplay()
            return
        }
        if host.port == 0 { host.port = 22 }

        AppServices.shared.hosts.upsert(host)
        // El Keychain sólo se toca si se escribió algo: dejar el campo como
        // estaba significa "no la cambies", no "bórrala".
        if host.authentication == .password, passwordTouched, !password.isEmpty {
            SSHKeychain.setPassword(password, for: host)
        }
        onDismiss?()
    }

    private func delete() {
        AppServices.shared.hosts.remove(host)
        onDismiss?()
    }
}

import UIKit

/// Un formulario en la pantalla externa: alta y edición de máquinas SSH y de
/// servidores SMB. Qué campos hay y qué se hace al guardar lo pone el
/// `EditorForm`; esta ventana sólo dibuja y reparte el teclado.
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
final class FormWindow: UIView {

    var onDismiss: (() -> Void)?

    private enum Button: Int {
        case cancel, delete, save
    }

    private let form: any EditorForm
    private var focusedField: String
    private var error: String?

    private let card = CardView()
    private let titleLabel = UILabel()
    private var fieldFrames: [String: CGRect] = [:]
    private var buttonFrames: [Button: CGRect] = [:]

    init(form: any EditorForm, frame: CGRect) {
        self.form = form
        self.focusedField = form.fields.first { $0.kind != .choice }?.id ?? ""
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
        titleLabel.text = form.title
        card.addSubview(titleLabel)
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
        let fields = form.fields
        let noteHeight = noteSize(width: width).height
        let height = 58 + CGFloat(fields.count) * Self.rowHeight + (noteHeight > 0 ? noteHeight + 12 : 0) + 66

        card.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: max(24, (bounds.height - height) / 2),
            width: width,
            height: height
        )
        titleLabel.frame = CGRect(x: 20, y: 18, width: width - 40, height: 24)

        var y: CGFloat = 54
        fieldFrames = [:]
        for field in fields {
            fieldFrames[field.id] = CGRect(x: 16, y: y, width: width - 32, height: Self.rowHeight - 6)
            y += Self.rowHeight
        }

        // Borrar a la izquierda, lejos de Guardar: son irreversibles y no
        // conviene tenerlos pegados.
        let buttonY = height - 52
        buttonFrames = [
            .delete: form.isNew
                ? .zero
                : CGRect(x: 16, y: buttonY, width: 90, height: 32),
            .cancel: CGRect(x: width - 200, y: buttonY, width: 86, height: 32),
            .save: CGRect(x: width - 106, y: buttonY, width: 90, height: 32),
        ]
        card.setNeedsDisplay()
    }

    private var noteAttributes: [NSAttributedString.Key: Any] {
        [.font: Tokens.sans(11.5), .foregroundColor: Tokens.Color.textSecondary]
    }

    private func noteSize(width: CGFloat) -> CGSize {
        guard let note = form.note else { return .zero }
        let bounds = (note as NSString).boundingRect(
            with: CGSize(width: width - 36, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: noteAttributes,
            context: nil
        )
        return CGSize(width: bounds.width, height: ceil(bounds.height))
    }

    // MARK: - Dibujo

    /// Lo llama la tarjeta desde su `draw(_:)`: ver `CardView`.
    private func drawCard(in context: CGContext) {
        let origin = card.frame.origin

        for field in form.fields {
            guard let localFrame = fieldFrames[field.id] else { continue }
            drawField(field, in: localFrame.offsetBy(dx: origin.x, dy: origin.y), context: context)
        }

        if let note = form.note {
            let top = 54 + CGFloat(form.fields.count) * Self.rowHeight + 4
            (note as NSString).draw(
                with: CGRect(x: origin.x + 18, y: origin.y + top, width: card.frame.width - 36,
                             height: noteSize(width: card.frame.width).height),
                options: [.usesLineFragmentOrigin],
                attributes: noteAttributes,
                context: nil
            )
        }

        drawButton(.cancel, title: "Cancelar", tint: Tokens.Color.textSecondary, context: context)
        if !form.isNew {
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

    private func drawField(_ field: EditorField, in frame: CGRect, context: CGContext) {
        let isFocused = field.id == focusedField

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

        let shown = form.value(of: field.id)
        let isPlaceholder = shown.isEmpty
        let text = (isPlaceholder ? field.placeholder : shown)
            + (isFocused && field.kind != .choice ? "|" : "")

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

        for field in form.fields {
            guard let frame = fieldFrames[field.id], frame.contains(inCard) else { continue }
            if field.kind == .choice {
                form.cycle(field.id)
                setNeedsLayout()
            } else {
                focusedField = field.id
            }
            card.setNeedsDisplay()
            return true
        }
        return true
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }
        let focusedKind = form.fields.first { $0.id == focusedField }?.kind

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
            if focusedKind != .choice { form.deleteBackward(in: focusedField) }
        case .keyboardSpacebar where focusedKind == .choice:
            form.cycle(focusedField)
            setNeedsLayout()
        default:
            let characters = event.key.characters
            guard !characters.isEmpty, focusedKind != .choice else { break }
            form.insert(characters, into: focusedField)
        }
        card.setNeedsDisplay()
        return true
    }

    private func moveFocus(by delta: Int) {
        let ids = form.fields.map(\.id)
        guard let index = ids.firstIndex(of: focusedField) else {
            focusedField = ids.first ?? ""
            return
        }
        focusedField = ids[(index + delta + ids.count) % ids.count]
    }

    // MARK: - Guardar

    private func save() {
        if let problem = form.save() {
            error = problem.message
            focusedField = problem.field
            card.setNeedsDisplay()
            return
        }
        onDismiss?()
    }

    private func delete() {
        form.delete()
        onDismiss?()
    }
}

// MARK: - Formularios

struct EditorField {
    enum Kind {
        case text
        /// Nunca se enseña en claro: en una pantalla que puede tener a alguien
        /// delante, una contraseña va con puntos.
        case secret
        /// Se alterna entre valores al pulsarlo, con la espaciadora o el ratón.
        case choice
    }

    var id: String
    var label: String
    var placeholder: String
    var kind: Kind = .text
}

/// Lo que un formulario tiene que saber hacer para que `FormWindow` lo pinte.
@MainActor
protocol EditorForm: AnyObject {
    var title: String { get }
    var isNew: Bool { get }
    /// Los campos que se ven ahora: pueden cambiar según lo elegido.
    var fields: [EditorField] { get }
    /// Una explicación bajo los campos, si hace falta.
    var note: String? { get }
    func value(of field: String) -> String
    func insert(_ text: String, into field: String)
    func deleteBackward(in field: String)
    func cycle(_ field: String)
    /// Guarda, o dice qué falta y en qué campo.
    func save() -> (message: String, field: String)?
    func delete()
}

extension EditorForm {
    var note: String? { nil }
    func cycle(_ field: String) {}
}

/// Alta y edición de una máquina SSH.
@MainActor
final class SSHHostForm: EditorForm {

    private var host: SSHHost
    let isNew: Bool
    private var password = ""
    private var passwordTouched = false

    init(host: SSHHost?) {
        self.host = host ?? SSHHost()
        self.isNew = host == nil
    }

    var title: String { isNew ? "Nueva máquina" : "Editar máquina" }

    var fields: [EditorField] {
        var fields = [
            EditorField(id: "name", label: "Nombre", placeholder: "homelab"),
            EditorField(id: "host", label: "Host", placeholder: "homelab o 192.168.1.50"),
            EditorField(id: "username", label: "Usuario", placeholder: "bruno"),
            EditorField(id: "port", label: "Puerto", placeholder: "22"),
            EditorField(id: "authentication", label: "Autenticación", placeholder: "", kind: .choice),
        ]
        // La contraseña sólo tiene sentido con ese método de autenticación.
        if host.authentication == .password {
            fields.append(EditorField(id: "password", label: "Contraseña",
                                      placeholder: "guardada en el Keychain", kind: .secret))
        }
        fields.append(EditorField(id: "initialCommand", label: "Comando inicial", placeholder: "tmux new -As main"))
        return fields
    }

    func value(of field: String) -> String {
        switch field {
        case "name": host.name
        case "host": host.host
        case "username": host.username
        case "port": String(host.port)
        case "authentication": host.authentication.label
        case "password": passwordTouched
            ? String(repeating: "•", count: password.count)
            : (SSHKeychain.hasPassword(for: host) ? "••••••••" : "")
        case "initialCommand": host.initialCommand
        default: ""
        }
    }

    func insert(_ text: String, into field: String) {
        switch field {
        case "name": host.name += text
        case "host": host.host += text.trimmingCharacters(in: .whitespaces)
        case "username": host.username += text.trimmingCharacters(in: .whitespaces)
        case "port":
            // Sólo cifras: un puerto con letras no es un puerto.
            let digits = text.filter(\.isNumber)
            guard !digits.isEmpty else { return }
            host.port = Int(String(host.port) + digits).map { min($0, 65_535) } ?? host.port
        case "password":
            passwordTouched = true
            password += text
        case "initialCommand": host.initialCommand += text
        default: break
        }
    }

    func deleteBackward(in field: String) {
        switch field {
        case "name": if !host.name.isEmpty { host.name.removeLast() }
        case "host": if !host.host.isEmpty { host.host.removeLast() }
        case "username": if !host.username.isEmpty { host.username.removeLast() }
        case "port":
            let text = String(host.port)
            host.port = text.count > 1 ? Int(text.dropLast()) ?? 0 : 0
        case "password":
            passwordTouched = true
            if !password.isEmpty { password.removeLast() }
        case "initialCommand": if !host.initialCommand.isEmpty { host.initialCommand.removeLast() }
        default: break
        }
    }

    func cycle(_ field: String) {
        guard field == "authentication" else { return }
        let all = SSHHost.Authentication.allCases
        guard let index = all.firstIndex(of: host.authentication) else { return }
        host.authentication = all[(index + 1) % all.count]
    }

    func save() -> (message: String, field: String)? {
        guard !host.host.isEmpty else { return ("Falta el host.", "host") }
        guard !host.username.isEmpty else { return ("Falta el usuario.", "username") }
        if host.port == 0 { host.port = 22 }

        AppServices.shared.hosts.upsert(host)
        // El Keychain sólo se toca si se escribió algo: dejar el campo como
        // estaba significa "no la cambies", no "bórrala".
        if host.authentication == .password, passwordTouched, !password.isEmpty {
            SSHKeychain.setPassword(password, for: host)
        }
        return nil
    }

    func delete() {
        AppServices.shared.hosts.remove(host)
    }
}

/// Alta y edición de un servidor SMB.
@MainActor
final class SMBServerForm: EditorForm {

    private var server: SMBServer
    let isNew: Bool
    private var password = ""
    private var passwordTouched = false

    init(server: SMBServer?) {
        self.server = server ?? SMBServer()
        self.isNew = server == nil
    }

    var title: String { isNew ? "Nuevo servidor de red" : "Editar servidor de red" }

    var fields: [EditorField] {
        [
            EditorField(id: "name", label: "Nombre", placeholder: "NAS"),
            EditorField(id: "host", label: "Servidor", placeholder: "nas.local o 192.168.1.20"),
            EditorField(id: "share", label: "Carpeta compartida", placeholder: "vacía: todas"),
            EditorField(id: "username", label: "Usuario", placeholder: "vacío: invitado"),
            EditorField(id: "password", label: "Contraseña", placeholder: "guardada en el Keychain", kind: .secret),
        ]
    }

    var note: String? {
        "Sin carpeta compartida, se ven todas las del servidor como carpetas. Vale un Mac con "
            + "Compartir archivos, un NAS o Windows, en casa o por el tailnet."
    }

    func value(of field: String) -> String {
        switch field {
        case "name": server.name
        case "host": server.host
        case "share": server.share
        case "username": server.username
        case "password": passwordTouched
            ? String(repeating: "•", count: password.count)
            : (SMBKeychain.password(for: server) != nil ? "••••••••" : "")
        default: ""
        }
    }

    func insert(_ text: String, into field: String) {
        switch field {
        case "name": server.name += text
        case "host": server.host += text.trimmingCharacters(in: .whitespaces)
        case "share": server.share += text.replacingOccurrences(of: "/", with: "")
        case "username": server.username += text.trimmingCharacters(in: .whitespaces)
        case "password":
            passwordTouched = true
            password += text
        default: break
        }
    }

    func deleteBackward(in field: String) {
        switch field {
        case "name": if !server.name.isEmpty { server.name.removeLast() }
        case "host": if !server.host.isEmpty { server.host.removeLast() }
        case "share": if !server.share.isEmpty { server.share.removeLast() }
        case "username": if !server.username.isEmpty { server.username.removeLast() }
        case "password":
            passwordTouched = true
            if !password.isEmpty { password.removeLast() }
        default: break
        }
    }

    func save() -> (message: String, field: String)? {
        // Lo pegado como `smb://nas/Fotos` se reparte solo entre servidor y
        // compartida.
        var address = server.host
        if address.lowercased().hasPrefix("smb://") { address.removeFirst(6) }
        let parts = address.split(separator: "/", omittingEmptySubsequences: true)
        guard let host = parts.first, !host.isEmpty else { return ("Falta el servidor.", "host") }
        server.host = String(host)
        if server.share.isEmpty, parts.count > 1 { server.share = String(parts[1]) }

        AppServices.shared.smbServers.upsert(server)
        if passwordTouched {
            SMBKeychain.setPassword(password, for: server)
        }
        return nil
    }

    func delete() {
        AppServices.shared.smbServers.remove(server)
    }
}

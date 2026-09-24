import UIKit

/// Notas y portapapeles: la cuarta app del dock.
///
/// A la izquierda, la lista (notas o lo que ha pasado por el portapapeles);
/// a la derecha, la nota abierta. Como todo en la pantalla externa, **no
/// recibe eventos del sistema**: el escritorio le pasa el cursor y las teclas.
///
/// **El editor es un `UITextView` que no edita.** Se usa para maquetar y
/// pintar el texto (ajuste de líneas, scroll, cursiva de nada: texto plano),
/// pero el cursor, la selección y el teclado los lleva el panel: el
/// `UITextView` nunca va a ser primer respondedor en una escena que no es
/// interactiva. Las posiciones se sacan de su `UITextInput` (`caretRect`,
/// `closestPosition`, `selectionRects`), que funciona sin serlo.
@MainActor
final class NotesPane: UIView, Pane {

    private static let headerHeight: CGFloat = 36
    private static let sidebarWidth: CGFloat = 230
    private static let rowHeight: CGFloat = 48
    private static let controlsX: CGFloat = 13
    private static var controlsMidY: CGFloat { headerHeight / 2 }

    enum Mode { case notes, clipboard }

    private let services = AppServices.shared
    private var mode = Mode.notes

    /// La nota abierta.
    private var noteID: UUID?
    /// El recorte del portapapeles que se está viendo.
    private var clipID: UUID?

    private let textView = UITextView()
    private let caret = UIView()
    private var selectionViews: [UIView] = []

    /// Lo seleccionado en el texto, en UTF-16 como `NSString`. Con longitud
    /// cero es el cursor.
    private var selection = NSRange(location: 0, length: 0)
    /// De dónde sale la selección al alargarla con Mayús o arrastrando.
    private var anchor = 0
    private var hasFocus = false
    /// Se está arrastrando para seleccionar.
    private var isSelectingWithMouse = false
    private var lastClick: (time: Date, location: CGPoint)?

    private var listScroll: CGFloat = 0
    private var rowFrames: [CGRect] = []
    private var hoveredRow: Int?
    private var hoveringControls = false
    private var modeFrames: [Mode: CGRect] = [:]
    private var newFrame: CGRect = .zero
    /// El aviso de «hay algo nuevo en el portapapeles», arriba de la lista.
    private var externalFrame: CGRect = .zero
    private var clipButtons: [(frame: CGRect, action: () -> Void, title: String)] = []

    var title: String {
        switch mode {
        case .notes: noteID.flatMap { services.notes.note($0)?.title } ?? "Notas"
        case .clipboard: "Portapapeles"
        }
    }

    var view: UIView { self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Tokens.Color.panel
        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = Tokens.Metric.focusBorderWidth
        layer.borderColor = Tokens.Color.border.desktopCGColor
        clipsToBounds = true
        contentMode = .redraw

        textView.isEditable = false
        textView.isSelectable = true
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = Tokens.Color.background
        textView.textColor = Tokens.Color.text
        textView.font = NoteStyle.baseFont
        // Los enlaces, en el ámbar de la marca y subrayados.
        textView.linkTextAttributes = [
            .foregroundColor: Tokens.Color.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.textContainerInset = UIEdgeInsets(top: 18, left: 20, bottom: 40, right: 20)
        textView.showsVerticalScrollIndicator = false
        addSubview(textView)

        caret.backgroundColor = Tokens.Color.accent
        caret.isHidden = true
        textView.addSubview(caret)

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged), name: NotesStore.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged), name: ClipboardHistory.didChange, object: nil
        )

        noteID = services.notes.sorted.first?.id
        loadCurrent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Datos

    private var notes: [Note] { services.notes.sorted }
    private var clips: [ClipboardHistory.Clip] { services.clipboard.clips }

    private var editingNote: Bool { mode == .notes && noteID != nil }

    /// Pone en el editor lo que toca: la nota abierta o el recorte elegido.
    private func loadCurrent() {
        switch mode {
        case .notes:
            textView.attributedText = Self.displayed(noteID.map { services.notes.content($0) }
                ?? NSAttributedString(string: ""))
        case .clipboard:
            let text = clipID.flatMap { id in clips.first { $0.id == id }?.text } ?? ""
            textView.attributedText = Self.displayed(NSAttributedString(string: text, attributes: NoteStyle.baseAttributes))
        }
        let length = (string as NSString).length
        selection = NSRange(location: length, length: 0)
        anchor = length
        textView.setContentOffset(.zero, animated: false)
        refreshCaret()
        setNeedsDisplay()
    }

    /// Otra ventana de Notas ha cambiado algo, o ha pasado algo por el
    /// portapapeles. La nota abierta **no se recarga** si es ésta la que
    /// escribe: perdería el cursor a cada tecla.
    @objc private func storeChanged() {
        if mode == .notes, let noteID {
            if let note = services.notes.note(noteID) {
                if note.text != textView.text {
                    textView.attributedText = Self.displayed(services.notes.content(noteID))
                    clampSelection()
                    refreshCaret()
                }
            } else {
                self.noteID = notes.first?.id
                loadCurrent()
            }
        }
        setNeedsDisplay()
    }

    private func openNote(_ id: UUID) {
        mode = .notes
        noteID = id
        loadCurrent()
        services.desktop.notifyTitleChange()
    }

    func newNote(text: String = "") {
        let note = services.notes.create(text: text)
        openNote(note.id)
    }

    private func switchMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        listScroll = 0
        if mode == .clipboard { clipID = clips.first?.id }
        loadCurrent()
        services.desktop.notifyTitleChange()
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = CGRect(
            x: Self.sidebarWidth, y: Self.headerHeight,
            width: max(0, bounds.width - Self.sidebarWidth),
            height: max(0, bounds.height - Self.headerHeight - (mode == .clipboard ? 46 : 0))
        )
        recomputeFrames()
        refreshCaret()
        setNeedsDisplay()
    }

    private func recomputeFrames() {
        let segmentWidth = (Self.sidebarWidth - 20) / 2
        modeFrames = [
            .notes: CGRect(x: 10, y: Self.headerHeight + 8, width: segmentWidth, height: 26),
            .clipboard: CGRect(x: 10 + segmentWidth, y: Self.headerHeight + 8, width: segmentWidth, height: 26),
        ]
        newFrame = CGRect(x: Self.sidebarWidth - 34, y: (Self.headerHeight - 26) / 2, width: 26, height: 26)

        var top = Self.headerHeight + 44
        externalFrame = .zero
        if mode == .clipboard, services.clipboard.hasUnseenExternal {
            externalFrame = CGRect(x: 8, y: top, width: Self.sidebarWidth - 16, height: 40)
            top += 46
        }
        let count = mode == .notes ? notes.count : clips.count
        rowFrames = (0..<count).map { index in
            CGRect(
                x: 6, y: top + CGFloat(index) * Self.rowHeight - listScroll,
                width: Self.sidebarWidth - 12, height: Self.rowHeight - 2
            )
        }
    }

    // MARK: - Dibujo

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        recomputeFrames()

        // Barra lateral.
        context.setFillColor(Tokens.Color.panelElevated.desktopCGColor)
        context.fill(CGRect(x: 0, y: 0, width: Self.sidebarWidth, height: bounds.height))
        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.fill(CGRect(x: Self.sidebarWidth - 1, y: 0, width: 1, height: bounds.height))
        context.fill(CGRect(x: Self.sidebarWidth, y: Self.headerHeight - 1,
                            width: bounds.width - Self.sidebarWidth, height: 1))

        WindowControls.draw(in: context, x: Self.controlsX, midY: Self.controlsMidY,
                            hovering: hoveringControls, scale: layer.contentsScale)
        drawSymbol("square.and.pencil", in: newFrame, color: Tokens.Color.text.withAlphaComponent(0.8), size: 13)

        // Título de lo abierto, en la cabecera del editor.
        (title as NSString).draw(
            in: CGRect(x: Self.sidebarWidth + 16, y: (Self.headerHeight - 20) / 2,
                       width: bounds.width - Self.sidebarWidth - 32, height: 20),
            withAttributes: [
                .font: Tokens.sans(14, weight: .semibold),
                .foregroundColor: Tokens.Color.text,
                .paragraphStyle: Self.truncating,
            ]
        )

        drawSegments(in: context)

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: Self.headerHeight + 42,
                                width: Self.sidebarWidth, height: bounds.height - Self.headerHeight - 42))
        if externalFrame != .zero { drawExternalNotice(in: context) }
        switch mode {
        case .notes: drawNoteRows(in: context)
        case .clipboard: drawClipRows(in: context)
        }
        context.restoreGState()

        if mode == .clipboard { drawClipBar(in: context) }
    }

    private static let truncating: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }()

    private func drawSegments(in context: CGContext) {
        for (segment, frame) in modeFrames {
            let isActive = segment == mode
            if isActive {
                context.setFillColor(Tokens.Color.accent.withAlphaComponent(0.2).desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
                context.fillPath()
            }
            let label = segment == .notes ? "Notas" : "Portapapeles"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Tokens.sans(12, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? Tokens.Color.accent : Tokens.Color.textSecondary,
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(
                at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func drawRowBackground(_ index: Int, selected: Bool, in context: CGContext) {
        let frame = rowFrames[index]
        guard selected || index == hoveredRow else { return }
        let color = selected ? Tokens.Color.accent.withAlphaComponent(0.2) : Tokens.Color.text.withAlphaComponent(0.06)
        context.setFillColor(color.desktopCGColor)
        context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 7).cgPath)
        context.fillPath()
    }

    private func drawNoteRows(in context: CGContext) {
        let list = notes
        if list.isEmpty {
            drawEmpty("Sin notas · pulsa ✎ para escribir una")
            return
        }
        for (index, note) in list.enumerated() where index < rowFrames.count {
            let frame = rowFrames[index]
            guard frame.maxY > Self.headerHeight + 42, frame.minY < bounds.height else { continue }
            drawRowBackground(index, selected: note.id == noteID, in: context)
            var x = frame.minX + 10
            if note.isPinned {
                drawSymbol("pin.fill", in: CGRect(x: x, y: frame.minY + 7, width: 12, height: 14),
                           color: Tokens.Color.accent, size: 9)
                x += 14
            }
            (note.title as NSString).draw(
                in: CGRect(x: x, y: frame.minY + 6, width: frame.maxX - x - 8, height: 18),
                withAttributes: [
                    .font: Tokens.sans(13, weight: .medium),
                    .foregroundColor: Tokens.Color.text,
                    .paragraphStyle: Self.truncating,
                ]
            )
            let detail = note.modified.formatted(date: .abbreviated, time: .shortened)
                + (note.preview.isEmpty ? "" : "  " + note.preview)
            (detail as NSString).draw(
                in: CGRect(x: frame.minX + 10, y: frame.minY + 25, width: frame.width - 18, height: 16),
                withAttributes: [
                    .font: Tokens.sans(11),
                    .foregroundColor: Tokens.Color.textSecondary,
                    .paragraphStyle: Self.truncating,
                ]
            )
        }
    }

    private func drawClipRows(in context: CGContext) {
        let list = clips
        if list.isEmpty {
            drawEmpty("Lo que copies en BrunOS aparecerá aquí")
            return
        }
        for (index, clip) in list.enumerated() where index < rowFrames.count {
            let frame = rowFrames[index]
            guard frame.maxY > Self.headerHeight + 42, frame.minY < bounds.height else { continue }
            drawRowBackground(index, selected: clip.id == clipID, in: context)
            let firstLine = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? ""
            (firstLine as NSString).draw(
                in: CGRect(x: frame.minX + 10, y: frame.minY + 6, width: frame.width - 18, height: 18),
                withAttributes: [
                    .font: Tokens.mono(12),
                    .foregroundColor: Tokens.Color.text,
                    .paragraphStyle: Self.truncating,
                ]
            )
            let lines = clip.text.components(separatedBy: .newlines).count
            let detail = clip.date.formatted(date: .omitted, time: .shortened)
                + " · \((clip.text as NSString).length) caracteres" + (lines > 1 ? " · \(lines) líneas" : "")
            (detail as NSString).draw(
                at: CGPoint(x: frame.minX + 10, y: frame.minY + 26),
                withAttributes: [.font: Tokens.sans(11), .foregroundColor: Tokens.Color.textSecondary]
            )
        }
    }

    private func drawExternalNotice(in context: CGContext) {
        context.setFillColor(Tokens.Color.accentAlt.withAlphaComponent(0.15).desktopCGColor)
        context.addPath(UIBezierPath(roundedRect: externalFrame, cornerRadius: 8).cgPath)
        context.fillPath()
        ("Hay algo nuevo en el portapapeles\npulsa para guardarlo" as NSString).draw(
            in: externalFrame.insetBy(dx: 10, dy: 4),
            withAttributes: [.font: Tokens.sans(11.5, weight: .medium), .foregroundColor: Tokens.Color.text]
        )
    }

    private func drawEmpty(_ text: String) {
        (text as NSString).draw(
            in: CGRect(x: 14, y: Self.headerHeight + 56 + (externalFrame == .zero ? 0 : 46),
                       width: Self.sidebarWidth - 28, height: 60),
            withAttributes: [.font: Tokens.sans(12), .foregroundColor: Tokens.Color.textSecondary]
        )
    }

    /// Los botones de debajo de un recorte: copiarlo otra vez, hacerlo nota o
    /// quitarlo.
    private func drawClipBar(in context: CGContext) {
        let bar = CGRect(x: Self.sidebarWidth, y: bounds.height - 46, width: bounds.width - Self.sidebarWidth, height: 46)
        context.setFillColor(Tokens.Color.panelElevated.desktopCGColor)
        context.fill(bar)
        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: 1))

        clipButtons = []
        guard let clip = clips.first(where: { $0.id == clipID }) else { return }
        let history = services.clipboard
        let actions: [(String, () -> Void)] = [
            ("Copiar", { history.restore(clip) }),
            ("Guardar como nota", { [weak self] in self?.newNote(text: clip.text) }),
            ("Quitar", { history.remove(clip) }),
        ]
        var x = bar.minX + 14
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(12, weight: .medium), .foregroundColor: Tokens.Color.text,
        ]
        for (title, action) in actions {
            let size = (title as NSString).size(withAttributes: attributes)
            let frame = CGRect(x: x, y: bar.midY - 14, width: size.width + 24, height: 28)
            context.setStrokeColor(Tokens.Color.border.desktopCGColor)
            context.setLineWidth(1)
            context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 7).cgPath)
            context.strokePath()
            (title as NSString).draw(
                at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
                withAttributes: attributes
            )
            clipButtons.append((frame: frame, action: action, title: title))
            x = frame.maxX + 8
        }
    }

    private func drawSymbol(_ name: String, in frame: CGRect, color: UIColor, size: CGFloat = 12) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let image = UIImage.crispSymbol(name, configuration: configuration, scale: layer.contentsScale)?
            .withTintColor(
                color.resolvedColor(with: UITraitCollection(userInterfaceStyle: DesktopTheme.style)),
                renderingMode: .alwaysOriginal
            )
        else { return }
        image.draw(at: CGPoint(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2))
    }

    // MARK: - Cursor y selección

    /// El texto del editor (`UITextView.text` es opcional implícito).
    private var string: String { textView.text ?? "" }

    private var length: Int { (string as NSString).length }

    private func position(_ offset: Int) -> UITextPosition? {
        textView.position(from: textView.beginningOfDocument, offset: max(0, min(offset, length)))
    }

    private func offset(_ position: UITextPosition) -> Int {
        textView.offset(from: textView.beginningOfDocument, to: position)
    }

    private func clampSelection() {
        let location = min(selection.location, length)
        selection = NSRange(location: location, length: min(selection.length, length - location))
        anchor = min(anchor, length)
    }

    /// Mueve el cursor. Con `extend`, la selección va del ancla hasta ahí.
    private func setCursor(_ offset: Int, extend: Bool) {
        typingStyle = nil
        let offset = max(0, min(offset, length))
        if extend {
            selection = NSRange(location: min(anchor, offset), length: abs(offset - anchor))
        } else {
            anchor = offset
            selection = NSRange(location: offset, length: 0)
        }
        refreshCaret()
        // Que se vea dónde está el cursor.
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        refreshCaret()
    }

    /// El extremo que se mueve: el contrario al ancla.
    private var head: Int {
        selection.location == anchor ? selection.location + selection.length : selection.location
    }

    /// Coloca el cursor y pinta la selección. El cursor parpadea con una
    /// animación de la capa, sin temporizador.
    private func refreshCaret() {
        selectionViews.forEach { $0.removeFromSuperview() }
        selectionViews = []

        let showsCaret = hasFocus && editingNote && selection.length == 0
        caret.isHidden = !showsCaret
        if showsCaret, let position = position(selection.location) {
            var rect = textView.caretRect(for: position)
            rect.size.width = 2
            caret.frame = rect
            caret.layer.removeAnimation(forKey: "blink")
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1
            blink.toValue = 0
            blink.duration = 0.55
            blink.beginTime = CACurrentMediaTime() + 0.5
            blink.autoreverses = true
            blink.repeatCount = .infinity
            caret.layer.add(blink, forKey: "blink")
        }

        guard selection.length > 0,
              let start = position(selection.location),
              let end = position(selection.location + selection.length),
              let range = textView.textRange(from: start, to: end)
        else { return }
        for item in textView.selectionRects(for: range) where item.rect.width > 0 {
            let highlight = UIView(frame: item.rect)
            highlight.backgroundColor = Tokens.Color.accent.withAlphaComponent(0.3)
            highlight.isUserInteractionEnabled = false
            textView.insertSubview(highlight, at: 0)
            selectionViews.append(highlight)
        }
    }

    // MARK: - Editar

    // MARK: - Texto enriquecido

    /// El contenido guardado, listo para enseñar: el color lo pone el modo
    /// claro u oscuro, porque en el fichero no se guarda.
    private static func displayed(_ content: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: content)
        let whole = NSRange(location: 0, length: copy.length)
        copy.addAttribute(.foregroundColor, value: Tokens.Color.text, range: whole)
        copy.enumerateAttribute(.font, in: whole) { value, range, _ in
            if value == nil { copy.addAttribute(.font, value: NoteStyle.baseFont, range: range) }
        }
        return copy
    }

    /// El formato que se aplicará a lo que se escriba, si se ha cambiado con
    /// Cmd+B, Cmd+I o Cmd+U sin nada seleccionado. Se olvida al mover el
    /// cursor, como en cualquier editor.
    private var typingStyle: [NSAttributedString.Key: Any]?

    /// Con qué formato sale lo que se escribe: el de lo que hay justo antes
    /// del cursor (sin su enlace), o el pedido con los atajos.
    private var typingAttributes: [NSAttributedString.Key: Any] {
        if let typingStyle { return typingStyle }
        let storage = textView.textStorage
        guard storage.length > 0 else {
            var base = NoteStyle.baseAttributes
            base[.foregroundColor] = Tokens.Color.text
            return base
        }
        let index = max(0, min(selection.location - 1, storage.length - 1))
        var attributes = storage.attributes(at: index, effectiveRange: nil)
        attributes[.link] = nil
        attributes[.foregroundColor] = Tokens.Color.text
        return attributes
    }

    /// Cambia lo seleccionado por `text` y lo guarda.
    private func replaceSelection(with text: String) {
        guard editingNote else { return }
        let attributes = typingAttributes
        let start = selection.location
        textView.textStorage.replaceCharacters(in: selection, with: NSAttributedString(string: text, attributes: attributes))
        let inserted = NSRange(location: start, length: (text as NSString).length)
        linkify(around: inserted)
        let cursor = NSMaxRange(inserted)
        let style = typingStyle
        saveContent()
        setCursor(cursor, extend: false)
        // Escribiendo, el formato pedido se mantiene aunque el cursor avance.
        typingStyle = style
        services.desktop.notifyTitleChange()
    }

    private func saveContent() {
        guard let noteID else { return }
        services.notes.update(noteID, content: textView.attributedText)
    }

    /// **Las direcciones se vuelven enlaces solas**, en el párrafo que se está
    /// escribiendo. Los enlaces puestos a mano (Cmd+K, con otro texto) se
    /// respetan; los automáticos se rehacen, por si se ha editado la
    /// dirección.
    private func linkify(around range: NSRange) {
        let storage = textView.textStorage
        let nsString = storage.string as NSString
        guard nsString.length > 0 else { return }
        let paragraph = nsString.paragraphRange(for: NSRange(location: min(range.location, nsString.length - 1), length: range.length))
        storage.enumerateAttribute(.link, in: paragraph) { value, linkRange, _ in
            guard let value else { return }
            let target = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
            let text = nsString.substring(with: linkRange)
            // Automático es el que enseña su propia dirección.
            if target == text || target == "http://" + text || target == "https://" + text {
                storage.removeAttribute(.link, range: linkRange)
            }
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for match in detector.matches(in: storage.string, range: paragraph) {
            guard let url = match.url, storage.attribute(.link, at: match.range.location, effectiveRange: nil) == nil
            else { continue }
            storage.addAttribute(.link, value: url, range: match.range)
        }
    }

    /// Cmd+B y Cmd+I: sobre lo seleccionado, o para lo que se escriba.
    private func toggle(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard editingNote else { return }
        func toggled(_ font: UIFont, on: Bool) -> UIFont {
            var traits = font.fontDescriptor.symbolicTraits
            if on { traits.insert(trait) } else { traits.remove(trait) }
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        if selection.length == 0 {
            var attributes = typingAttributes
            let font = attributes[.font] as? UIFont ?? NoteStyle.baseFont
            attributes[.font] = toggled(font, on: !font.fontDescriptor.symbolicTraits.contains(trait))
            typingStyle = attributes
            return
        }
        let storage = textView.textStorage
        var allHave = true
        storage.enumerateAttribute(.font, in: selection) { value, _, _ in
            let font = value as? UIFont ?? NoteStyle.baseFont
            if !font.fontDescriptor.symbolicTraits.contains(trait) { allHave = false }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: selection) { value, range, _ in
            storage.addAttribute(.font, value: toggled(value as? UIFont ?? NoteStyle.baseFont, on: !allHave), range: range)
        }
        storage.endEditing()
        saveContent()
        refreshCaret()
    }

    /// Cmd+U.
    private func toggleUnderline() {
        guard editingNote else { return }
        if selection.length == 0 {
            var attributes = typingAttributes
            attributes[.underlineStyle] = attributes[.underlineStyle] == nil ? NSUnderlineStyle.single.rawValue : nil
            typingStyle = attributes
            return
        }
        let storage = textView.textStorage
        var allHave = true
        storage.enumerateAttribute(.underlineStyle, in: selection) { value, _, _ in
            if value == nil { allHave = false }
        }
        if allHave {
            storage.removeAttribute(.underlineStyle, range: selection)
        } else {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: selection)
        }
        saveContent()
    }

    /// Cmd+K: un enlace en lo seleccionado, o la dirección escrita como enlace.
    private func addLink() {
        guard editingNote else { return }
        let range = selection
        services.desktopViewController?.presentPrompt(title: "Dirección del enlace", value: "https://") {
            [weak self] address in
            guard let self, var address = address?.trimmingCharacters(in: .whitespaces), !address.isEmpty else { return }
            if !address.contains("://") { address = "https://" + address }
            guard let url = URL(string: address) else { return }
            self.selection = range
            if range.length == 0 {
                let start = range.location
                self.replaceSelection(with: address)
                self.textView.textStorage.addAttribute(.link, value: url, range: NSRange(location: start, length: (address as NSString).length))
            } else {
                self.textView.textStorage.addAttribute(.link, value: url, range: range)
            }
            self.saveContent()
        }
    }

    /// El enlace bajo un punto del panel, si lo hay: un clic lo abre en el
    /// navegador.
    private func link(at location: CGPoint) -> URL? {
        guard editingNote, textView.frame.contains(location) else { return nil }
        let point = convert(location, to: textView)
        guard let range = textView.characterRange(at: point) else { return nil }
        let index = offset(range.start)
        guard index < textView.textStorage.length else { return nil }
        let value = textView.textStorage.attribute(.link, at: index, effectiveRange: nil)
        return value as? URL ?? (value as? String).flatMap(URL.init(string:))
    }

    private func deleteBackward() {
        if selection.length > 0 { replaceSelection(with: ""); return }
        guard selection.location > 0 else { return }
        let range = (string as NSString).rangeOfComposedCharacterSequence(at: selection.location - 1)
        selection = range
        replaceSelection(with: "")
    }

    private func deleteForward() {
        if selection.length > 0 { replaceSelection(with: ""); return }
        guard selection.location < length else { return }
        selection = (string as NSString).rangeOfComposedCharacterSequence(at: selection.location)
        replaceSelection(with: "")
    }

    private func selectedText() -> String? {
        guard selection.length > 0 else { return nil }
        return (string as NSString).substring(with: selection)
    }

    /// Cmd+C: lo seleccionado; sin selección, la nota o el recorte entero.
    func copySelection() {
        let text = selectedText() ?? string
        guard !text.isEmpty else { return }
        services.clipboard.copy(text)
    }

    /// Cmd+V.
    func paste() {
        guard let text = services.clipboard.readForPaste() else { return }
        if mode == .clipboard { setNeedsDisplay(); return }
        if noteID == nil { newNote() }
        replaceSelection(with: text)
    }

    private func cut() {
        guard let text = selectedText() else { return }
        services.clipboard.copy(text)
        replaceSelection(with: "")
    }

    /// Un paso a la izquierda o a la derecha, sin partir un emoji.
    private func step(_ offset: Int, forward: Bool) -> Int {
        let string = string as NSString
        if forward {
            guard offset < string.length else { return offset }
            return NSMaxRange(string.rangeOfComposedCharacterSequence(at: offset))
        }
        guard offset > 0 else { return 0 }
        return string.rangeOfComposedCharacterSequence(at: offset - 1).location
    }

    /// Una línea arriba o abajo, por la maquetación (una línea larga que se
    /// parte cuenta como varias).
    private func verticalMove(from offset: Int, down: Bool) -> Int {
        guard let start = position(offset),
              let moved = textView.position(from: start, in: down ? .down : .up, offset: 1)
        else { return down ? length : 0 }
        return self.offset(moved)
    }

    /// Principio o final de la línea que se ve.
    private func lineBoundary(from offset: Int, forward: Bool) -> Int {
        guard let start = position(offset),
              let boundary = textView.tokenizer.position(
                  from: start, toBoundary: .line,
                  inDirection: forward ? UITextDirection.storage(.forward) : UITextDirection.storage(.backward)
              )
        else { return forward ? length : 0 }
        return self.offset(boundary)
    }

    // MARK: - Pane

    func setFocused(_ focused: Bool) {
        hasFocus = focused
        layer.borderColor = (focused ? Tokens.Color.accent : Tokens.Color.border).desktopCGColor
        refreshCaret()
    }

    func handleKey(_ event: KeyEvent) {
        guard event.phase == .down else { return }
        let key = event.key
        let flags = key.modifierFlags
        let extend = flags.contains(.shift)

        if flags.contains(.command) {
            switch key.keyCode {
            case .keyboardA:
                anchor = 0
                setCursor(length, extend: true)
            case .keyboardX: cut()
            case .keyboardB: toggle(.traitBold)
            case .keyboardI: toggle(.traitItalic)
            case .keyboardU: toggleUnderline()
            case .keyboardK: addLink()
            case .keyboardLeftArrow: setCursor(lineBoundary(from: head, forward: false), extend: extend)
            case .keyboardRightArrow: setCursor(lineBoundary(from: head, forward: true), extend: extend)
            case .keyboardUpArrow: setCursor(0, extend: extend)
            case .keyboardDownArrow: setCursor(length, extend: extend)
            case .keyboardDeleteOrBackspace:
                // Borra hasta el principio de la línea, como en macOS.
                let start = lineBoundary(from: selection.location, forward: false)
                selection = NSRange(location: start, length: selection.location + selection.length - start)
                replaceSelection(with: "")
            default: break
            }
            return
        }

        // En el portapapeles no se escribe: las flechas recorren la lista.
        if mode == .clipboard || noteID == nil {
            switch key.keyCode {
            case .keyboardUpArrow: moveInList(by: -1)
            case .keyboardDownArrow: moveInList(by: 1)
            case .keyboardReturnOrEnter where mode == .notes: newNote()
            default:
                // Escribir sin nota abierta empieza una.
                if mode == .notes, let text = event.typedText {
                    newNote()
                    replaceSelection(with: text)
                }
            }
            return
        }

        switch key.keyCode {
        case .keyboardLeftArrow:
            if selection.length > 0, !extend { setCursor(selection.location, extend: false) }
            else { setCursor(step(head, forward: false), extend: extend) }
        case .keyboardRightArrow:
            if selection.length > 0, !extend { setCursor(NSMaxRange(selection), extend: false) }
            else { setCursor(step(head, forward: true), extend: extend) }
        case .keyboardUpArrow:
            setCursor(verticalMove(from: head, down: false), extend: extend)
        case .keyboardDownArrow:
            setCursor(verticalMove(from: head, down: true), extend: extend)
        case .keyboardHome:
            setCursor(lineBoundary(from: head, forward: false), extend: extend)
        case .keyboardEnd:
            setCursor(lineBoundary(from: head, forward: true), extend: extend)
        case .keyboardDeleteOrBackspace:
            deleteBackward()
        case .keyboardDeleteForward:
            deleteForward()
        case .keyboardReturnOrEnter:
            replaceSelection(with: "\n")
        case .keyboardTab:
            replaceSelection(with: "\t")
        case .keyboardEscape:
            if selection.length > 0 { setCursor(head, extend: false) }
        default:
            if let text = event.typedText { replaceSelection(with: text) }
        }
    }

    func insertText(_ text: String) {
        guard mode == .notes else { return }
        if noteID == nil { newNote() }
        replaceSelection(with: text)
    }

    private func moveInList(by delta: Int) {
        switch mode {
        case .notes:
            let list = notes
            guard !list.isEmpty else { return }
            let current = list.firstIndex { $0.id == noteID } ?? 0
            openNote(list[max(0, min(current + delta, list.count - 1))].id)
        case .clipboard:
            let list = clips
            guard !list.isEmpty else { return }
            let current = list.firstIndex { $0.id == clipID } ?? 0
            clipID = list[max(0, min(current + delta, list.count - 1))].id
            loadCurrent()
        }
    }

    func isDragArea(_ point: CGPoint) -> Bool {
        guard point.y < Self.headerHeight else { return false }
        if newFrame.insetBy(dx: -4, dy: -4).contains(point) { return false }
        return WindowControls.button(at: point, x: Self.controlsX, midY: Self.controlsMidY) == nil
    }

    func handlePointer(_ event: PointerEvent) {
        let location = event.location
        switch event.kind {
        case .moved:
            if isSelectingWithMouse, let offset = textOffset(at: location) {
                setCursor(offset, extend: true)
                return
            }
            let inControls = WindowControls.groupContains(location, x: Self.controlsX, midY: Self.controlsMidY)
            let row = rowFrames.firstIndex { $0.contains(location) }
            if inControls != hoveringControls || row != hoveredRow {
                hoveringControls = inControls
                hoveredRow = row
                setNeedsDisplay()
            }
            // El aviso de lo nuevo del portapapeles se mira al pasar por
            // encima: leer `changeCount` no cuesta ni avisa.
            if mode == .clipboard, (externalFrame != .zero) != services.clipboard.hasUnseenExternal {
                setNeedsLayout()
            }

        case .down(let button):
            guard button == .left else { return }
            if let control = WindowControls.button(at: location, x: Self.controlsX, midY: Self.controlsMidY) {
                WindowControls.perform(control, on: self)
                return
            }
            if newFrame.insetBy(dx: -4, dy: -4).contains(location) {
                newNote()
                return
            }
            if let segment = modeFrames.first(where: { $0.value.contains(location) })?.key {
                switchMode(segment)
                setNeedsLayout()
                return
            }
            if externalFrame.contains(location) {
                _ = services.clipboard.readForPaste()
                clipID = clips.first?.id
                loadCurrent()
                setNeedsLayout()
                return
            }
            if let clipButton = clipButtons.first(where: { $0.frame.contains(location) }) {
                clipButton.action()
                if mode == .clipboard {
                    if !clips.contains(where: { $0.id == clipID }) { clipID = clips.first?.id }
                    loadCurrent()
                }
                return
            }
            if let row = rowFrames.firstIndex(where: { $0.contains(location) }) {
                selectRow(row)
                return
            }
            // Un clic en un enlace lo abre, como en Notas de macOS. Con
            // Mayús, no: así se puede seleccionar sin abrirlo.
            if !event.modifiers.contains(.shift), let url = link(at: location) {
                services.desktopViewController?.openInBrowser(url)
                return
            }
            if editingNote, let offset = textOffset(at: location) {
                let now = Date()
                let isDouble = lastClick.map {
                    now.timeIntervalSince($0.time) < 0.5 && hypot($0.location.x - location.x, $0.location.y - location.y) < 6
                } ?? false
                lastClick = (now, location)
                if isDouble, let word = wordRange(at: offset) {
                    anchor = word.location
                    setCursor(NSMaxRange(word), extend: true)
                    return
                }
                setCursor(offset, extend: event.modifiers.contains(.shift))
                isSelectingWithMouse = true
            }

        case .up:
            isSelectingWithMouse = false

        case .scroll(let delta):
            if location.x < Self.sidebarWidth {
                let total = CGFloat(rowFrames.count) * Self.rowHeight
                let visible = bounds.height - Self.headerHeight - 44
                listScroll = max(0, min(listScroll - delta.dy, max(0, total - visible)))
                setNeedsLayout()
                setNeedsDisplay()
            } else {
                let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
                let y = max(0, min(textView.contentOffset.y - delta.dy, maxOffset))
                textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            }
        }
    }

    /// El punto del editor bajo el cursor, como posición en el texto.
    private func textOffset(at location: CGPoint) -> Int? {
        guard textView.frame.contains(location) else { return nil }
        let point = convert(location, to: textView)
        guard let position = textView.closestPosition(to: point) else { return nil }
        return offset(position)
    }

    /// La palabra en un punto, para el doble clic.
    private func wordRange(at offset: Int) -> NSRange? {
        guard let position = position(offset),
              let range = textView.tokenizer.rangeEnclosingPosition(
                  position, with: .word, inDirection: UITextDirection.storage(.backward)
              ) ?? textView.tokenizer.rangeEnclosingPosition(
                  position, with: .word, inDirection: UITextDirection.storage(.forward)
              )
        else { return nil }
        let start = self.offset(range.start)
        return NSRange(location: start, length: self.offset(range.end) - start)
    }

    private func selectRow(_ row: Int) {
        switch mode {
        case .notes:
            let list = notes
            guard list.indices.contains(row) else { return }
            openNote(list[row].id)
        case .clipboard:
            let list = clips
            guard list.indices.contains(row) else { return }
            clipID = list[row].id
            loadCurrent()
        }
    }

    // MARK: - Menú

    func contextMenuEntries(at location: CGPoint) -> [ContextMenu.Entry] {
        var entries: [ContextMenu.Entry] = []
        if mode == .notes, let row = rowFrames.firstIndex(where: { $0.contains(location) }),
           notes.indices.contains(row) {
            let note = notes[row]
            let store = services.notes
            entries.append(ContextMenu.Entry(title: note.isPinned ? "Soltar" : "Fijar arriba",
                                             symbol: note.isPinned ? "pin.slash" : "pin") {
                store.togglePin(note.id)
            })
            entries.append(ContextMenu.Entry(title: "Copiar el texto", symbol: "doc.on.doc") { [weak self] in
                self?.services.clipboard.copy(note.text)
            })
            entries.append(ContextMenu.Entry(title: "Borrar la nota", symbol: "trash", isDestructive: true) {
                [weak self] in self?.confirmDelete(note)
            })
            return entries
        }
        if mode == .clipboard {
            entries.append(ContextMenu.Entry(title: "Vaciar el portapapeles de BrunOS", symbol: "trash",
                                             isDestructive: true, isEnabled: !clips.isEmpty) { [weak self] in
                self?.services.clipboard.clear()
                self?.clipID = nil
                self?.loadCurrent()
            })
            return entries
        }
        if editingNote, textView.frame.contains(location) {
            entries.append(ContextMenu.Entry(title: "Copiar", symbol: "doc.on.doc", isEnabled: selection.length > 0) {
                [weak self] in self?.copySelection()
            })
            entries.append(ContextMenu.Entry(title: "Cortar", symbol: "scissors", isEnabled: selection.length > 0) {
                [weak self] in self?.cut()
            })
            entries.append(ContextMenu.Entry(title: "Pegar", symbol: "doc.on.clipboard") { [weak self] in
                self?.paste()
            })
            entries.append(ContextMenu.Entry(title: "Negrita · Cmd B", symbol: "bold") { [weak self] in
                self?.toggle(.traitBold)
            })
            entries.append(ContextMenu.Entry(title: "Cursiva · Cmd I", symbol: "italic") { [weak self] in
                self?.toggle(.traitItalic)
            })
            entries.append(ContextMenu.Entry(title: "Subrayado · Cmd U", symbol: "underline") { [weak self] in
                self?.toggleUnderline()
            })
            entries.append(ContextMenu.Entry(title: "Añadir enlace… · Cmd K", symbol: "link") { [weak self] in
                self?.addLink()
            })
        }
        entries.append(ContextMenu.Entry(title: "Nota nueva", symbol: "square.and.pencil") { [weak self] in
            self?.newNote()
        })
        return entries
    }

    private func confirmDelete(_ note: Note) {
        services.desktopViewController?.presentConfirm(
            title: "¿Borrar «\(note.title)»?",
            message: "No se puede deshacer.",
            destructive: "Borrar"
        ) { [weak self] confirmed in
            guard confirmed else { return }
            self?.services.notes.delete(note.id)
        }
    }
}

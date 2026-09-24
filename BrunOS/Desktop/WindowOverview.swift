import UIKit

/// Todas las ventanas de un vistazo: Exposé (Cmd+E) y el cambio de ventana
/// con Cmd+º, que es el Cmd+Tab de BrunOS.
///
/// **Cmd+Tab no se puede usar**: iOS se lo reserva (ver `Shortcuts`). La tecla
/// de debajo de Esc es la que macOS usa para cambiar entre ventanas de una
/// misma app (Cmd+`), y aquí cambia entre todas.
///
/// Las dos son la misma vista con distinta colocación: Exposé reparte las
/// ventanas en una rejilla que llena la pantalla; el conmutador, en una tira
/// centrada que se va recorriendo mientras se mantiene Cmd. Cada ventana sale
/// con una **instantánea** de lo que tenía (`snapshotView`), no con las vistas
/// de verdad: moverlas y devolverlas a su sitio chocaría con la maquetación
/// del escritorio. Las minimizadas no están en pantalla y no hay de qué sacar
/// la foto: salen con el icono de su app.
///
/// Como todo lo de la pantalla externa, no recibe eventos del sistema: el
/// escritorio le pasa el cursor y las teclas.
@MainActor
final class WindowOverview: UIView {

    enum Style {
        case expose
        case switcher
    }

    struct Entry {
        var id: PaneID
        var title: String
        var kind: PaneKind?
        /// El marco de la ventana en el escritorio, para la proporción.
        var frame: CGRect
        var snapshot: UIView?
        var isMinimized: Bool
    }

    let style: Style
    private(set) var entries: [Entry]
    private(set) var selectedIndex: Int

    /// Se eligió una ventana.
    var onPick: ((PaneID) -> Void)?
    var onDismiss: (() -> Void)?

    private var cards: [WindowOverviewCard] = []
    /// La tarjeta de fondo del conmutador.
    private let strip = UIView()
    private let hintLabel = UILabel()

    init(style: Style, entries: [Entry], selected: Int) {
        self.style = style
        self.entries = entries
        self.selectedIndex = entries.isEmpty ? 0 : min(max(selected, 0), entries.count - 1)
        super.init(frame: .zero)

        backgroundColor = UIColor.black.withAlphaComponent(style == .expose ? 0.55 : 0.3)

        if style == .switcher {
            strip.backgroundColor = Tokens.Color.panelElevated.withAlphaComponent(0.94)
            strip.layer.cornerRadius = 18
            strip.layer.borderWidth = 1
            strip.setThemedBorder(Tokens.Color.border)
            strip.layer.shadowColor = UIColor.black.cgColor
            strip.layer.shadowOpacity = 0.45
            strip.layer.shadowRadius = 24
            strip.layer.shadowOffset = CGSize(width: 0, height: 8)
            addSubview(strip)
        }

        hintLabel.font = Tokens.sans(12)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        hintLabel.textAlignment = .center
        hintLabel.text = style == .expose
            ? "Pulsa una ventana para ir a ella · flechas e Intro · Esc para salir"
            : "Suelta Cmd para ir · Mayús para volver atrás · Esc para quedarte"
        addSubview(hintLabel)

        cards = entries.map { entry in
            let card = WindowOverviewCard(entry: entry, compact: style == .switcher)
            addSubview(card)
            return card
        }
        refreshSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    var selectedID: PaneID? {
        entries.indices.contains(selectedIndex) ? entries[selectedIndex].id : nil
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()
        switch style {
        case .expose: layoutGrid()
        case .switcher: layoutStrip()
        }
    }

    /// Rejilla de Exposé: se prueban todas las columnas posibles y se queda la
    /// que deja las ventanas más grandes, contando con que la mayoría son más
    /// anchas que altas.
    private func layoutGrid() {
        let area = bounds.inset(by: UIEdgeInsets(top: 64, left: 56, bottom: 96, right: 56))
        hintLabel.frame = CGRect(x: 0, y: bounds.height - 64, width: bounds.width, height: 20)
        guard !cards.isEmpty, area.width > 0, area.height > 0 else { return }

        let labelHeight = WindowOverviewCard.labelHeight
        let spacing: CGFloat = 28
        let count = cards.count
        var best = (columns: 1, scale: CGFloat(0))
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let cellWidth = (area.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (area.height - spacing * CGFloat(rows - 1)) / CGFloat(rows) - labelHeight
            let scale = min(cellWidth / 16, cellHeight / 10)
            if scale > best.scale { best = (columns, scale) }
        }

        let columns = best.columns
        let rows = (count + columns - 1) / columns
        let cellWidth = (area.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (area.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        for (index, card) in cards.enumerated() {
            let row = index / columns
            // La última fila, centrada si no está llena.
            let inRow = row == rows - 1 ? count - row * columns : columns
            let rowWidth = CGFloat(inRow) * cellWidth + CGFloat(inRow - 1) * spacing
            let startX = area.minX + (area.width - rowWidth) / 2
            let cell = CGRect(
                x: startX + CGFloat(index % columns) * (cellWidth + spacing),
                y: area.minY + CGFloat(row) * (cellHeight + spacing),
                width: cellWidth,
                height: cellHeight
            )
            card.frame = card.fittedFrame(in: cell)
        }
    }

    /// Tira del conmutador, en el centro. Si no caben, las tarjetas encogen.
    private func layoutStrip() {
        let spacing: CGFloat = 14
        let padding: CGFloat = 18
        let maxWidth = bounds.width - 120
        let count = CGFloat(max(cards.count, 1))
        let cardWidth = min(220, (maxWidth - 2 * padding - spacing * (count - 1)) / count)
        let cardHeight = cardWidth * 10 / 16 + WindowOverviewCard.labelHeight
        let stripWidth = 2 * padding + count * cardWidth + (count - 1) * spacing
        strip.frame = CGRect(
            x: (bounds.width - stripWidth) / 2,
            y: (bounds.height - cardHeight - 2 * padding) / 2,
            width: stripWidth,
            height: cardHeight + 2 * padding
        )
        for (index, card) in cards.enumerated() {
            card.frame = CGRect(
                x: strip.frame.minX + padding + CGFloat(index) * (cardWidth + spacing),
                y: strip.frame.minY + padding,
                width: cardWidth,
                height: cardHeight
            )
        }
        hintLabel.frame = CGRect(x: 0, y: strip.frame.maxY + 14, width: bounds.width, height: 20)
    }

    // MARK: - Selección

    /// Siguiente o anterior, dando la vuelta.
    func advance(by delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = ((selectedIndex + delta) % entries.count + entries.count) % entries.count
        refreshSelection()
    }

    private func refreshSelection() {
        for (index, card) in cards.enumerated() {
            card.isSelected = index == selectedIndex
        }
    }

    private func pickSelected() {
        guard let id = selectedID else {
            onDismiss?()
            return
        }
        onPick?(id)
    }

    /// Flechas en la rejilla: arriba y abajo saltan de fila.
    private func moveInGrid(_ key: UIKeyboardHIDUsage) {
        guard style == .expose, let first = cards.first, cards.count > 1 else {
            advance(by: key == .keyboardLeftArrow || key == .keyboardUpArrow ? -1 : 1)
            return
        }
        // Cuántas hay en la primera fila: las que comparten su altura.
        let columns = max(1, cards.filter { abs($0.frame.minY - first.frame.minY) < 1 }.count)
        let delta = switch key {
        case .keyboardLeftArrow: -1
        case .keyboardRightArrow: 1
        case .keyboardUpArrow: -columns
        default: columns
        }
        let next = selectedIndex + delta
        guard entries.indices.contains(next) else { return }
        selectedIndex = next
        refreshSelection()
    }

    // MARK: - Entrada

    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        let index = cards.firstIndex { $0.frame.contains(point) }
        switch kind {
        case .moved:
            if let index, index != selectedIndex {
                selectedIndex = index
                refreshSelection()
            }
        case .down(let button):
            guard button == .left else { return true }
            if let index {
                selectedIndex = index
                pickSelected()
            } else if style == .expose || !strip.frame.contains(point) {
                // Pinchar en el fondo cierra sin cambiar nada, como Exposé.
                onDismiss?()
            }
        default:
            break
        }
        return true
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }
        let code = event.key.keyCode
        switch code {
        case .keyboardEscape:
            onDismiss?()
        case .keyboardReturnOrEnter, .keyboardSpacebar:
            pickSelected()
        case .keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow:
            moveInGrid(code)
        case .keyboardTab:
            advance(by: event.key.modifierFlags.contains(.shift) ? -1 : 1)
        case .keyboardLeftGUI, .keyboardRightGUI, .keyboardLeftShift, .keyboardRightShift:
            break
        default:
            // En el conmutador, cualquier otra tecla confirma: es lo que se
            // espera al soltar Cmd y ponerse a escribir.
            if style == .switcher { pickSelected() }
        }
        return true
    }
}

/// Una ventana en Exposé o en el conmutador: su instantánea y su título.
@MainActor
final class WindowOverviewCard: UIView {

    static let labelHeight: CGFloat = 26

    private let entry: Entry
    private let compact: Bool
    private let thumbnail = OverviewThumbnail()
    private let titleLabel = UILabel()
    private let badge = UIImageView()

    typealias Entry = WindowOverview.Entry

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            applySelection()
        }
    }

    init(entry: Entry, compact: Bool) {
        self.entry = entry
        self.compact = compact
        super.init(frame: .zero)

        thumbnail.backgroundColor = Tokens.Color.panel
        thumbnail.layer.cornerRadius = 10
        thumbnail.clipsToBounds = true
        thumbnail.layer.borderWidth = 1
        thumbnail.layer.borderColor = Tokens.Color.border.desktopCGColor
        addSubview(thumbnail)

        if let snapshot = entry.snapshot {
            // Se ve encogida: con el filtro de siempre, suave, no a trozos.
            snapshot.layer.minificationFilter = .trilinear
            thumbnail.addSubview(snapshot)
        } else {
            // Minimizada, o sin foto: el icono de la app en grande.
            let icon = UIImageView(image: icon(size: 96))
            icon.contentMode = .scaleAspectFit
            icon.tag = 1
            thumbnail.addSubview(icon)
        }

        badge.image = icon(size: 64)
        badge.contentMode = .scaleAspectFit
        addSubview(badge)

        titleLabel.font = Tokens.sans(compact ? 11.5 : 13, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.text = entry.isMinimized ? "\(entry.title) · en el dock" : entry.title
        addSubview(titleLabel)

        // Sombra para que se lea sobre cualquier fondo.
        titleLabel.layer.shadowColor = UIColor.black.cgColor
        titleLabel.layer.shadowOpacity = 0.8
        titleLabel.layer.shadowRadius = 3
        titleLabel.layer.shadowOffset = .zero

        applySelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    private func icon(size: CGFloat) -> UIImage {
        entry.kind.map { DockIcon.image(for: $0, size: size) } ?? DockIcon.settingsImage(size: size)
    }

    /// El hueco de la rejilla, ajustado a la proporción de la ventana, con el
    /// título debajo.
    func fittedFrame(in cell: CGRect) -> CGRect {
        let available = CGSize(width: cell.width, height: max(1, cell.height - Self.labelHeight))
        let aspect = entry.frame.width > 0 && entry.frame.height > 0
            ? entry.frame.width / entry.frame.height
            : 16 / 10
        var size = CGSize(width: available.width, height: available.width / aspect)
        if size.height > available.height {
            size = CGSize(width: available.height * aspect, height: available.height)
        }
        return CGRect(
            x: cell.midX - size.width / 2,
            y: cell.minY + (available.height - size.height) / 2,
            width: size.width,
            height: size.height + Self.labelHeight
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let thumbFrame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.labelHeight))
        thumbnail.frame = thumbFrame
        titleLabel.frame = CGRect(x: 0, y: thumbFrame.maxY + 5, width: bounds.width, height: 18)

        let badgeSide: CGFloat = compact ? 26 : 34
        badge.frame = CGRect(
            x: thumbFrame.minX + 6, y: thumbFrame.maxY - badgeSide - 6,
            width: badgeSide, height: badgeSide
        )

        if let snapshot = entry.snapshot {
            // La foto va a tamaño real y se encoge con una transformación: así
            // se ve la ventana entera, no un recorte.
            let source = entry.frame.size
            guard source.width > 0, source.height > 0 else { return }
            let scale = min(thumbFrame.width / source.width, thumbFrame.height / source.height)
            snapshot.transform = .identity
            snapshot.bounds = CGRect(origin: .zero, size: source)
            snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
            snapshot.center = CGPoint(x: thumbFrame.width / 2, y: thumbFrame.height / 2)
        } else if let icon = thumbnail.viewWithTag(1) {
            let side = min(96, thumbFrame.height * 0.5)
            icon.frame = CGRect(
                x: (thumbFrame.width - side) / 2, y: (thumbFrame.height - side) / 2,
                width: side, height: side
            )
            badge.isHidden = true
        }
    }

    private func applySelection() {
        thumbnail.layer.borderWidth = isSelected ? 3 : 1
        thumbnail.layer.borderColor = (isSelected ? Tokens.Color.accent : Tokens.Color.border).desktopCGColor
        thumbnail.alpha = entry.isMinimized && !isSelected ? 0.75 : 1
        titleLabel.textColor = isSelected ? .white : UIColor.white.withAlphaComponent(0.8)
    }
}

/// El hueco de la instantánea. Tiene tipo propio para que el escritorio no
/// le ponga densidad ni filtro `.nearest` (`applyContentsScale`): a la foto
/// encogida le daría dientes de sierra.
@MainActor
final class OverviewThumbnail: UIView {}

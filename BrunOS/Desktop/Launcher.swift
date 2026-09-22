import UIKit

/// Lanzador: Cmd+P.
///
/// Se escribe para filtrar, se mueve con las flechas y se confirma con Intro,
/// como cualquier lanzador. **No recibe eventos del sistema**: las teclas se las
/// pasa el escritorio antes que al panel con foco, y los clics llegan por
/// geometría desde el cursor.
///
/// Busca en todo a la vez: máquinas SSH, marcadores e historial del navegador,
/// ubicaciones de ficheros y acciones del escritorio. Y lo que se escribe, si no
/// coincide con nada, se ofrece como dirección o como búsqueda web.
@MainActor
final class Launcher: UIView {

    struct Entry {
        var title: String
        var subtitle: String
        var symbol: String = "circle"
        var action: () -> Void
    }

    var onDismiss: (() -> Void)?

    /// Cuántas filas se enseñan como mucho. El historial puede tener cientos
    /// de entradas: con el filtro, las primeras nueve bastan.
    private static let maxRows = 9

    private let entries: [Entry]
    /// Lo que se ofrece según lo escrito: abrir la dirección, buscarla.
    private let dynamic: (String) -> [Entry]
    private var filtered: [Entry]
    private var query = ""
    private var selectedIndex = 0

    private let card = UIView()
    private let queryLabel = UILabel()
    private let hintLabel = UILabel()
    private var rows: [LauncherRow] = []

    init(entries: [Entry], dynamic: @escaping (String) -> [Entry] = { _ in [] }) {
        self.entries = entries
        self.dynamic = dynamic
        self.filtered = Array(entries.prefix(Self.maxRows))
        super.init(frame: .zero)

        // Oscurecer el escritorio: el lanzador es modal aunque no haya modales.
        backgroundColor = UIColor.black.withAlphaComponent(0.45)

        card.backgroundColor = Tokens.Color.panelElevated
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 1
        card.setThemedBorder(Tokens.Color.accent.withAlphaComponent(0.5))
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.5
        card.layer.shadowRadius = 24
        card.layer.shadowOffset = CGSize(width: 0, height: 8)
        addSubview(card)

        queryLabel.font = Tokens.mono(18)
        queryLabel.textColor = Tokens.Color.text
        card.addSubview(queryLabel)

        hintLabel.font = Tokens.sans(11)
        hintLabel.textColor = Tokens.Color.textSecondary
        hintLabel.text = "Máquinas, webs, carpetas y acciones · ↑↓ para moverte · Intro para abrir · Esc para salir"
        card.addSubview(hintLabel)

        rebuildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()

        let cardWidth = min(bounds.width * 0.5, 560)
        let rowHeight: CGFloat = 46
        let headerHeight: CGFloat = 52
        let footerHeight: CGFloat = 28
        let cardHeight = headerHeight + CGFloat(rows.count) * rowHeight + footerHeight

        card.frame = CGRect(
            x: (bounds.width - cardWidth) / 2,
            // Un poco por encima del centro: mirar al centro exacto de una
            // pantalla grande obliga a bajar la vista.
            y: max(40, bounds.height * 0.24),
            width: cardWidth,
            height: cardHeight
        )

        queryLabel.frame = CGRect(x: 16, y: 14, width: cardWidth - 32, height: 26)

        for (index, row) in rows.enumerated() {
            row.frame = CGRect(
                x: 8,
                y: headerHeight + CGFloat(index) * rowHeight,
                width: cardWidth - 16,
                height: rowHeight - 4
            )
        }

        hintLabel.frame = CGRect(
            x: 16,
            y: cardHeight - footerHeight + 4,
            width: cardWidth - 32,
            height: 16
        )
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = filtered.enumerated().map { index, entry in
            let row = LauncherRow()
            row.update(entry: entry, isSelected: index == selectedIndex)
            card.addSubview(row)
            return row
        }
        queryLabel.attributedText = queryText
        setNeedsLayout()
    }

    private var queryText: NSAttributedString {
        let text = NSMutableAttributedString(
            string: query.isEmpty ? "Abrir…" : query,
            attributes: [
                .font: Tokens.mono(18),
                .foregroundColor: query.isEmpty ? Tokens.Color.textSecondary : Tokens.Color.text,
            ]
        )
        text.append(NSAttributedString(
            string: "▌",
            attributes: [.font: Tokens.mono(18), .foregroundColor: Tokens.Color.accent]
        ))
        return text
    }

    // MARK: - Teclado

    /// Devuelve `true` si consumió la tecla.
    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }

        switch event.key.keyCode {
        case .keyboardEscape:
            onDismiss?()

        case .keyboardReturnOrEnter:
            let action = filtered.indices.contains(selectedIndex)
                ? filtered[selectedIndex].action
                : nil
            onDismiss?()
            action?()

        case .keyboardUpArrow:
            move(by: -1)

        case .keyboardDownArrow:
            move(by: 1)

        case .keyboardDeleteOrBackspace:
            guard !query.isEmpty else { break }
            query.removeLast()
            applyFilter()

        default:
            let characters = event.key.characters
            guard !characters.isEmpty, characters.first?.isNewline != true else { break }
            query += characters
            applyFilter()
        }
        return true
    }

    // MARK: - Ratón

    /// Clic dentro del lanzador. Devuelve `true` si lo consumió.
    ///
    /// **Todo lo que se ve tiene que poder pulsarse.** Una lista que sólo
    /// responde al teclado, con el ratón en la mano, es una lista rota.
    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        let inCard = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)

        guard card.frame.contains(point) else {
            // Pinchar fuera de la tarjeta cierra, como cualquier diálogo.
            if case .down = kind { onDismiss?() }
            return true
        }

        guard let index = rows.firstIndex(where: { $0.frame.contains(inCard) }) else { return true }

        switch kind {
        case .moved:
            // Resaltar lo que hay bajo el cursor, como en un menú.
            if selectedIndex != index {
                selectedIndex = index
                for (position, row) in rows.enumerated() {
                    row.update(entry: filtered[position], isSelected: position == index)
                }
            }
        case .down:
            let action = filtered.indices.contains(index) ? filtered[index].action : nil
            onDismiss?()
            action?()
        default:
            break
        }
        return true
    }

    private func move(by delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + filtered.count) % filtered.count
        for (index, row) in rows.enumerated() {
            row.update(entry: filtered[index], isSelected: index == selectedIndex)
        }
    }

    private func applyFilter() {
        // Filtro por partes: "ho la" encuentra "homelab" igual que "homelab".
        // Buscar sólo por prefijo obligaría a recordar cómo empieza cada nombre.
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let matches = entries.filter { entry in
            let haystack = (entry.title + " " + entry.subtitle).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
        // Lo que coincide va primero; abrir o buscar lo escrito, detrás. Si no
        // coincide nada, abrir o buscar es justo lo que se quiere.
        filtered = Array((matches + (query.isEmpty ? [] : dynamic(query))).prefix(Self.maxRows))
        selectedIndex = 0
        rebuildRows()
    }
}

/// Una fila del lanzador.
@MainActor
private final class LauncherRow: UIView {

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8

        iconView.contentMode = .center
        addSubview(iconView)

        titleLabel.font = Tokens.sans(15, weight: .medium)
        subtitleLabel.font = Tokens.mono(11)
        subtitleLabel.textColor = Tokens.Color.textSecondary

        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    func update(entry: Launcher.Entry, isSelected: Bool) {
        titleLabel.text = entry.title
        subtitleLabel.text = entry.subtitle
        iconView.image = UIImage(
            systemName: entry.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        )
        iconView.tintColor = isSelected ? Tokens.Color.accent : Tokens.Color.textSecondary
        backgroundColor = isSelected ? Tokens.Color.accent.withAlphaComponent(0.2) : .clear
        titleLabel.textColor = isSelected ? Tokens.Color.accent : Tokens.Color.text
        layer.borderWidth = isSelected ? 1 : 0
        layer.borderColor = Tokens.Color.accent.withAlphaComponent(0.5).desktopCGColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        iconView.frame = CGRect(x: 8, y: 0, width: 28, height: bounds.height)
        titleLabel.frame = CGRect(x: 42, y: 5, width: bounds.width - 54, height: 19)
        subtitleLabel.frame = CGRect(x: 42, y: 23, width: bounds.width - 54, height: 14)
    }
}

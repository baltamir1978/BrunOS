import UIKit

/// La lista que cae bajo la barra de direcciones al escribir, como la de
/// Safari: lo escrito, los favoritos y el historial que encajen.
///
/// **La primera fila es siempre lo que se ha escrito**, como dirección o como
/// búsqueda. Así Intro hace lo de siempre y las sugerencias no se ponen por
/// delante de lo que uno quería.
///
/// Como todo lo de la pantalla externa, se dibuja entera y resuelve los clics
/// por geometría.
@MainActor
final class AddressSuggestions: UIView {

    struct Item: Equatable {
        enum Kind { case address, search, bookmark, history }

        var kind: Kind
        var title: String
        var detail: String
        /// Lo que se carga al elegirla.
        var target: String

        var symbol: String {
            switch kind {
            case .address: "arrow.up.right"
            case .search: "magnifyingglass"
            case .bookmark: "star.fill"
            case .history: "clock"
            }
        }
    }

    private(set) var items: [Item] = []
    private(set) var selection = 0

    private static let rowHeight: CGFloat = 30
    static let maximumRows = 8

    private let card = CardView()
    private var rowFrames: [CGRect] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        card.backgroundColor = Tokens.Color.panelElevated
        card.layer.cornerRadius = 10
        card.layer.borderWidth = 1
        card.setThemedBorder(Tokens.Color.border)
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.35
        card.layer.shadowRadius = 14
        card.layer.shadowOffset = CGSize(width: 0, height: 5)
        // **La tarjeta dibuja su propio contenido.** Una vista pinta su
        // `draw(_:)` por debajo de sus subvistas, así que las filas dibujadas
        // en el fondo quedarían tapadas por la tarjeta opaca.
        card.drawContent = { [weak self] in self?.drawRows(in: $0) }
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    var isEmpty: Bool { items.isEmpty }

    /// Coloca la lista bajo la cápsula de direcciones y la rellena.
    func update(items: [Item], under addressFrame: CGRect, in width: CGFloat) {
        let clipped = Array(items.prefix(Self.maximumRows))
        if clipped != self.items { selection = 0 }
        self.items = clipped

        let height = CGFloat(clipped.count) * Self.rowHeight + 8
        let cardWidth = max(320, min(addressFrame.width, width - 16))
        card.frame = CGRect(
            x: min(max(8, addressFrame.minX), width - cardWidth - 8),
            y: addressFrame.maxY + 6,
            width: cardWidth,
            height: height
        )
        rowFrames = clipped.indices.map { index in
            CGRect(x: 4, y: 4 + CGFloat(index) * Self.rowHeight,
                   width: cardWidth - 8, height: Self.rowHeight)
        }
        isHidden = clipped.isEmpty
        card.setNeedsDisplay()
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + offset + items.count) % items.count
        card.setNeedsDisplay()
    }

    var selected: Item? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    /// Qué fila hay bajo un punto, en coordenadas del panel.
    func hit(at point: CGPoint) -> Int? {
        let local = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)
        return rowFrames.firstIndex { $0.contains(local) }
    }

    func hover(at point: CGPoint) {
        guard let index = hit(at: point), index != selection else { return }
        selection = index
        card.setNeedsDisplay()
    }

    func contains(_ point: CGPoint) -> Bool {
        !isHidden && card.frame.contains(point)
    }

    private func drawRows(in context: CGContext) {
        for (index, frame) in rowFrames.enumerated() {
            let item = items[index]
            if index == selection {
                context.setFillColor(Tokens.Color.accent.withAlphaComponent(0.22).desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
                context.fillPath()
            }

            let iconFrame = CGRect(x: frame.minX + 8, y: frame.midY - 7, width: 14, height: 14)
            if item.kind == .bookmark || item.kind == .history,
               let host = URL(string: item.target)?.host(),
               let icon = AppServices.shared.favicons.icon(for: host) {
                icon.draw(in: iconFrame)
            } else {
                drawSymbol(item.symbol, in: iconFrame, color: Tokens.Color.textSecondary)
            }

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: Tokens.sans(12.5),
                .foregroundColor: Tokens.Color.text,
            ]
            let title = item.title as NSString
            let titleWidth = min(title.size(withAttributes: titleAttributes).width, frame.width * 0.55)
            title.draw(
                in: CGRect(x: iconFrame.maxX + 9, y: frame.midY - 8, width: titleWidth, height: 16),
                withAttributes: titleAttributes
            )

            // El detalle a la derecha, en gris: la dirección completa, o «con
            // Google» en la fila de búsqueda.
            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: Tokens.sans(11),
                .foregroundColor: Tokens.Color.textSecondary,
            ]
            let detail = item.detail as NSString
            let detailX = iconFrame.maxX + 9 + titleWidth + 10
            detail.draw(
                in: CGRect(x: detailX, y: frame.midY - 7, width: max(0, frame.maxX - 8 - detailX), height: 14),
                withAttributes: detailAttributes
            )
        }
    }

    private func drawSymbol(_ name: String, in frame: CGRect, color: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let image = UIImage.crispSymbol(name, configuration: configuration, scale: layer.contentsScale)?
            .withTintColor(
                color.resolvedColor(with: UITraitCollection(userInterfaceStyle: DesktopTheme.style)),
                renderingMode: .alwaysOriginal
            )
        else { return }
        image.draw(at: CGPoint(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2))
    }

    // MARK: - De dónde salen

    /// Monta la lista para lo que se lleva escrito.
    ///
    /// Los favoritos van antes que el historial —son los que uno eligió
    /// guardar— y no se repite una dirección que ya esté en la lista.
    static func build(for text: String) -> [Item] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var items: [Item] = []
        let looksLikeAddress = !query.contains(" ") && query.contains(".")
        if looksLikeAddress {
            items.append(Item(kind: .address, title: query, detail: "Ir a la dirección", target: query))
        }
        items.append(Item(
            kind: .search,
            title: query,
            detail: "Buscar con \(SearchEngine.current.label)",
            target: query
        ))

        let history = AppServices.shared.history
        let needle = query.lowercased()
        var seen = Set(items.map(\.target))

        func matches(_ page: BrowserHistory.Page) -> Bool {
            page.url.lowercased().contains(needle) || page.title.lowercased().contains(needle)
        }

        for page in history.bookmarks where matches(page) && !seen.contains(page.url) {
            seen.insert(page.url)
            items.append(Item(kind: .bookmark, title: page.title, detail: shorten(page.url), target: page.url))
            if items.count >= 4 { break }
        }
        for page in history.visits where matches(page) && !seen.contains(page.url) {
            seen.insert(page.url)
            items.append(Item(kind: .history, title: page.title, detail: shorten(page.url), target: page.url))
            if items.count >= maximumRows { break }
        }
        return items
    }

    /// La dirección sin `https://` ni `www.`, como la enseña Safari.
    private static func shorten(_ address: String) -> String {
        var text = address
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text.count > 70 ? String(text.prefix(70)) + "…" : text
    }
}

import UIKit

/// El historial del navegador en una ventana, como «Mostrar todo el
/// historial» de Safari (Cmd+Y).
///
/// Agrupado por días, con un buscador que filtra según se escribe, y se puede
/// borrar una visita, la última hora, lo de hoy o todo. Se dibuja entero en la
/// tarjeta (`CardView`), como los ajustes: en la pantalla externa no hay
/// eventos del sistema, así que cada zona pulsable se apunta al dibujarla, en
/// el mismo cálculo, para que lo que se ve y lo que responde no se desalineen.
@MainActor
final class HistoryWindow: UIView {

    var onDismiss: (() -> Void)?
    /// Abrir una página: en la pestaña actual, o en otra con Cmd.
    var onOpen: ((URL, _ newTab: Bool) -> Void)?

    private enum Line {
        case day(String)
        case page(BrowserHistory.Page)
    }

    private struct Region {
        enum Action {
            case open(BrowserHistory.Page)
            case remove(BrowserHistory.Page)
            case clear(Clear)
            case close
        }
        var frame: CGRect
        var action: Action
    }

    private enum Clear: Equatable {
        case lastHour, today, all

        var title: String {
            switch self {
            case .lastHour: "Borrar la última hora"
            case .today: "Borrar hoy"
            case .all: "Borrar todo"
            }
        }
    }

    private let card = CardView()
    private var query = ""
    private var lines: [Line] = []
    /// Las páginas visibles en orden, para moverse con las flechas.
    private var pages: [BrowserHistory.Page] = []
    private var selected: Int?
    private var hoveredRegion: Int?
    private var regions: [Region] = []
    private var scrollOffset: CGFloat = 0
    private var contentHeight: CGFloat = 0
    /// «Borrar todo» pide un segundo clic: no se deshace.
    private var confirmingClearAll = false

    private static let rowHeight: CGFloat = 34
    private static let dayHeight: CGFloat = 30
    private static let headerHeight: CGFloat = 64
    private static let footerHeight: CGFloat = 52

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.35)

        card.backgroundColor = Tokens.Color.background
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1
        card.setThemedBorder(Tokens.Color.border)
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.35
        card.layer.shadowRadius = 30
        card.layer.shadowOffset = CGSize(width: 0, height: 12)
        card.drawContent = { [weak self] in self?.render(in: $0) }
        addSubview(card)

        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width * 0.62, 780)
        let height = min(bounds.height * 0.8, 820)
        card.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
        card.setNeedsDisplay()
    }

    // MARK: - Datos

    /// Filtra por partes, como el lanzador: «git bru» encuentra
    /// «github.com/bruno».
    private func rebuild() {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let visits = AppServices.shared.history.visits.filter { page in
            let haystack = (page.title + " " + page.url).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }

        lines = []
        pages = []
        var currentDay: Date?
        let calendar = Calendar.current
        for page in visits {
            let day = calendar.startOfDay(for: page.visited)
            if day != currentDay {
                lines.append(.day(Self.dayTitle(day)))
                currentDay = day
            }
            lines.append(.page(page))
            pages.append(page)
        }
        if let selected, selected >= pages.count { self.selected = pages.isEmpty ? nil : pages.count - 1 }
        card.setNeedsDisplay()
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "es_ES")))
        if calendar.isDateInToday(day) { return "Hoy · " + date }
        if calendar.isDateInYesterday(day) { return "Ayer · " + date }
        return date.prefix(1).uppercased() + date.dropFirst()
    }

    // MARK: - Dibujo

    private var listArea: CGRect {
        let size = card.bounds.size
        return CGRect(
            x: 0, y: Self.headerHeight,
            width: size.width, height: size.height - Self.headerHeight - Self.footerHeight
        )
    }

    /// Las coordenadas son de la tarjeta; `CardView` entrega el contexto en
    /// las de la ventana, así que se traslada primero.
    private func render(in context: CGContext) {
        context.saveGState()
        context.translateBy(x: card.frame.minX, y: card.frame.minY)
        defer { context.restoreGState() }

        regions = []
        let size = card.bounds.size

        ("Historial" as NSString).draw(
            at: CGPoint(x: 24, y: 20),
            withAttributes: [.font: Tokens.sans(20, weight: .semibold), .foregroundColor: Tokens.Color.text]
        )
        renderSearch(in: context, width: size.width)
        renderClose(in: context, width: size.width)

        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.fill(CGRect(x: 0, y: Self.headerHeight - 1, width: size.width, height: 1))

        renderList(in: context)

        context.fill(CGRect(x: 0, y: size.height - Self.footerHeight, width: size.width, height: 1))
        renderFooter(in: context, size: size)
    }

    private func renderSearch(in context: CGContext, width: CGFloat) {
        let box = CGRect(x: width - 24 - 44 - 300, y: 16, width: 300, height: 30)
        let path = UIBezierPath(roundedRect: box, cornerRadius: 8)
        context.setFillColor(Tokens.Color.panel.desktopCGColor)
        context.addPath(path.cgPath)
        context.fillPath()
        context.setStrokeColor(Tokens.Color.accent.withAlphaComponent(0.6).desktopCGColor)
        context.setLineWidth(1)
        context.addPath(path.cgPath)
        context.strokePath()

        drawSymbol("magnifyingglass", in: CGRect(x: box.minX + 9, y: box.midY - 7, width: 14, height: 14),
                   color: Tokens.Color.textSecondary)
        let text = NSMutableAttributedString(
            string: query.isEmpty ? "Buscar en el historial" : query,
            attributes: [
                .font: Tokens.sans(13),
                .foregroundColor: query.isEmpty ? Tokens.Color.textSecondary : Tokens.Color.text,
            ]
        )
        if !query.isEmpty {
            text.append(NSAttributedString(
                string: "▌", attributes: [.font: Tokens.sans(13), .foregroundColor: Tokens.Color.accent]
            ))
        }
        text.draw(in: CGRect(x: box.minX + 30, y: box.midY - 9, width: box.width - 40, height: 18))
    }

    private func renderClose(in context: CGContext, width: CGFloat) {
        let frame = CGRect(x: width - 24 - 28, y: 17, width: 28, height: 28)
        let index = regions.count
        regions.append(Region(frame: frame, action: .close))
        if hoveredRegion == index {
            context.setFillColor(Tokens.Color.textSecondary.withAlphaComponent(0.18).desktopCGColor)
            context.fillEllipse(in: frame)
        }
        drawSymbol("xmark", in: frame.insetBy(dx: 8, dy: 8), color: Tokens.Color.textSecondary)
    }

    private func renderList(in context: CGContext) {
        let area = listArea
        context.saveGState()
        context.clip(to: area)
        defer { context.restoreGState() }

        guard !lines.isEmpty else {
            let message = query.isEmpty ? "El historial está vacío." : "Nada coincide con «\(query)»."
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Tokens.sans(14), .foregroundColor: Tokens.Color.textSecondary,
            ]
            let size = (message as NSString).size(withAttributes: attributes)
            (message as NSString).draw(
                at: CGPoint(x: area.midX - size.width / 2, y: area.minY + 60),
                withAttributes: attributes
            )
            contentHeight = 0
            return
        }

        var y = area.minY + 8 - scrollOffset
        var pageIndex = 0
        for line in lines {
            switch line {
            case .day(let title):
                if y + Self.dayHeight > area.minY, y < area.maxY {
                    (title.uppercased() as NSString).draw(
                        at: CGPoint(x: 28, y: y + 11),
                        withAttributes: [
                            .font: Tokens.sans(10.5, weight: .semibold),
                            .foregroundColor: Tokens.Color.textSecondary,
                            .kern: 0.6,
                        ]
                    )
                }
                y += Self.dayHeight

            case .page(let page):
                let frame = CGRect(x: 16, y: y, width: area.width - 32, height: Self.rowHeight)
                if frame.maxY > area.minY, frame.minY < area.maxY {
                    renderRow(page, index: pageIndex, frame: frame, clip: area, context: context)
                }
                pageIndex += 1
                y += Self.rowHeight
            }
        }
        contentHeight = y + scrollOffset - area.minY + 8
    }

    private func renderRow(
        _ page: BrowserHistory.Page,
        index: Int,
        frame: CGRect,
        clip: CGRect,
        context: CGContext
    ) {
        // La zona de la fila sólo cuenta en la parte visible: si no, se podría
        // pulsar una fila escondida bajo la cabecera.
        let visible = frame.intersection(clip)
        let removeFrame = CGRect(x: frame.maxX - 30, y: frame.midY - 11, width: 22, height: 22)
        let removeIndex = regions.count
        if visible.contains(CGPoint(x: removeFrame.midX, y: removeFrame.midY)) {
            regions.append(Region(frame: removeFrame, action: .remove(page)))
        }
        let rowIndex = regions.count
        regions.append(Region(frame: visible, action: .open(page)))

        let hovered = hoveredRegion == rowIndex || hoveredRegion == removeIndex
        if selected == index || hovered {
            context.setFillColor(Tokens.Color.accent.withAlphaComponent(selected == index ? 0.22 : 0.12)
                .desktopCGColor)
            context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 7).cgPath)
            context.fillPath()
        }

        FaviconStore.drawSiteIcon(
            for: page.url,
            in: CGRect(x: frame.minX + 12, y: frame.midY - 8, width: 16, height: 16),
            context: context
        )

        let time = page.visited.formatted(date: .omitted, time: .shortened)
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.mono(11), .foregroundColor: Tokens.Color.textSecondary,
        ]
        let timeWidth = (time as NSString).size(withAttributes: timeAttributes).width
        let timeX = frame.maxX - 40 - timeWidth
        (time as NSString).draw(at: CGPoint(x: timeX, y: frame.midY - 7), withAttributes: timeAttributes)

        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let textX = frame.minX + 38
        let available = timeX - textX - 16
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(13.5), .foregroundColor: Tokens.Color.text, .paragraphStyle: truncating,
        ]
        let titleWidth = min((page.title as NSString).size(withAttributes: titleAttributes).width + 2,
                             available * 0.65)
        (page.title as NSString).draw(
            in: CGRect(x: textX, y: frame.midY - 9, width: titleWidth, height: 18),
            withAttributes: titleAttributes
        )
        let host = URL(string: page.url)?.host() ?? page.url
        (host as NSString).draw(
            in: CGRect(x: textX + titleWidth + 10, y: frame.midY - 8, width: available - titleWidth - 10, height: 16),
            withAttributes: [
                .font: Tokens.sans(12), .foregroundColor: Tokens.Color.textSecondary, .paragraphStyle: truncating,
            ]
        )

        // El aspa de borrar sólo con el cursor encima, como en Safari: una
        // columna de aspas en todas las filas es ruido.
        if hovered {
            if hoveredRegion == removeIndex {
                context.setFillColor(Tokens.Color.textSecondary.withAlphaComponent(0.2).desktopCGColor)
                context.fillEllipse(in: removeFrame)
            }
            drawSymbol("xmark", in: removeFrame.insetBy(dx: 6, dy: 6), color: Tokens.Color.textSecondary)
        }
    }

    private func renderFooter(in context: CGContext, size: CGSize) {
        let hint = "↑↓ para moverte · Intro abre · Cmd+Intro en otra pestaña · Cmd+⌫ borra · Esc cierra"
        (hint as NSString).draw(
            at: CGPoint(x: 24, y: size.height - Self.footerHeight / 2 - 7),
            withAttributes: [.font: Tokens.sans(11), .foregroundColor: Tokens.Color.textSecondary]
        )

        var x = size.width - 24
        for clear in [Clear.all, .today, .lastHour] {
            let title = clear == .all && confirmingClearAll ? "¿Seguro? Pulsa otra vez" : clear.title
            let attributes: [NSAttributedString.Key: Any] = [.font: Tokens.sans(12, weight: .medium)]
            let width = (title as NSString).size(withAttributes: attributes).width + 24
            let frame = CGRect(x: x - width, y: size.height - Self.footerHeight / 2 - 13, width: width, height: 26)
            x = frame.minX - 8

            let index = regions.count
            regions.append(Region(frame: frame, action: .clear(clear)))
            let destructive = clear == .all
            let tint = destructive ? UIColor(hex: 0xE05C4B) : Tokens.Color.text
            let path = UIBezierPath(roundedRect: frame, cornerRadius: 7).cgPath
            if destructive && confirmingClearAll {
                context.setFillColor(tint.desktopCGColor)
                context.addPath(path)
                context.fillPath()
            } else {
                context.setFillColor(Tokens.Color.panel.withAlphaComponent(hoveredRegion == index ? 1 : 0.7)
                    .desktopCGColor)
                context.addPath(path)
                context.fillPath()
                context.setStrokeColor(Tokens.Color.border.desktopCGColor)
                context.setLineWidth(1)
                context.addPath(path)
                context.strokePath()
            }
            (title as NSString).draw(
                at: CGPoint(x: frame.minX + 12, y: frame.midY - 8),
                withAttributes: [
                    .font: Tokens.sans(12, weight: .medium),
                    .foregroundColor: destructive && confirmingClearAll ? UIColor.white : tint,
                ]
            )
        }
    }

    private func drawSymbol(_ name: String, in frame: CGRect, color: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: frame.height, weight: .medium)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        else { return }
        let size = image.size
        let scale = min(frame.width / size.width, frame.height / size.height, 1)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        image.draw(in: CGRect(
            x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2,
            width: drawn.width, height: drawn.height
        ))
    }

    // MARK: - Ratón

    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        guard card.frame.contains(point) else {
            if case .down = kind { onDismiss?() }
            return true
        }
        let inCard = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)
        let index = regions.lastIndex { $0.frame.contains(inCard) }

        switch kind {
        case .moved:
            if index != hoveredRegion {
                hoveredRegion = index
                card.setNeedsDisplay()
            }

        case .down(let button):
            guard let index else { return true }
            perform(regions[index].action, newTab: button == .middle)

        case .scroll(let delta):
            let maxScroll = max(0, contentHeight - listArea.height)
            scrollOffset = min(max(scrollOffset - delta.dy, 0), maxScroll)
            hoveredRegion = nil
            card.setNeedsDisplay()

        case .up:
            break
        }
        return true
    }

    private func perform(_ action: Region.Action, newTab: Bool) {
        let history = AppServices.shared.history
        if case .clear(.all) = action {} else { confirmingClearAll = false }

        switch action {
        case .open(let page):
            guard let url = URL(string: page.url) else { return }
            onDismiss?()
            onOpen?(url, newTab)
        case .remove(let page):
            history.removeVisit(page)
            rebuild()
        case .clear(.lastHour):
            history.clearHistory(since: Date().addingTimeInterval(-3600))
            rebuild()
        case .clear(.today):
            history.clearHistory(since: Calendar.current.startOfDay(for: Date()))
            rebuild()
        case .clear(.all):
            if confirmingClearAll {
                confirmingClearAll = false
                history.clearHistory()
                rebuild()
            } else {
                confirmingClearAll = true
                card.setNeedsDisplay()
            }
        case .close:
            onDismiss?()
        }
    }

    // MARK: - Teclado

    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }
        let command = event.key.modifierFlags.contains(.command)

        switch event.key.keyCode {
        case .keyboardEscape:
            onDismiss?()
        case .keyboardReturnOrEnter:
            guard let selected, pages.indices.contains(selected) else { break }
            perform(.open(pages[selected]), newTab: command)
        case .keyboardDownArrow:
            move(by: 1)
        case .keyboardUpArrow:
            move(by: -1)
        case .keyboardDeleteOrBackspace where command:
            guard let selected, pages.indices.contains(selected) else { break }
            perform(.remove(pages[selected]), newTab: false)
        case .keyboardDeleteOrBackspace:
            guard !query.isEmpty else { break }
            query.removeLast()
            queryChanged()
        default:
            let characters = event.key.characters
            guard !command, !characters.isEmpty, characters.first?.isNewline != true else { break }
            query += characters
            queryChanged()
        }
        return true
    }

    private func queryChanged() {
        scrollOffset = 0
        selected = nil
        rebuild()
        if !pages.isEmpty { selected = 0 }
        card.setNeedsDisplay()
    }

    private func move(by delta: Int) {
        guard !pages.isEmpty else { return }
        let next = selected.map { $0 + delta } ?? (delta > 0 ? 0 : pages.count - 1)
        selected = min(max(next, 0), pages.count - 1)
        scrollToSelected()
        card.setNeedsDisplay()
    }

    /// Que la fila elegida con el teclado no se quede fuera de la vista.
    private func scrollToSelected() {
        guard let selected else { return }
        var y: CGFloat = 8
        var pageIndex = 0
        for line in lines {
            if case .page = line {
                if pageIndex == selected { break }
                pageIndex += 1
                y += Self.rowHeight
            } else {
                y += Self.dayHeight
            }
        }
        let area = listArea
        if y - scrollOffset < 0 {
            scrollOffset = max(0, y - Self.dayHeight)
        } else if y + Self.rowHeight - scrollOffset > area.height {
            scrollOffset = y + Self.rowHeight - area.height + 8
        }
    }
}

import UIKit

// MARK: - Modelo

/// Una sección de unos ajustes: «General», «Bloqueo de anuncios», «Máquinas».
///
/// El contenido se describe, no se construye: `build` devuelve los grupos y
/// filas que tocan **ahora**, y la ventana los vuelve a pedir después de cada
/// cambio. Así lo que se ve nunca se queda viejo y no hay que llevar la cuenta
/// de qué fila refrescar.
@MainActor
struct SettingsPage {
    var title: String
    var symbol: String
    var tint: UIColor
    var build: @MainActor () -> [SettingsGroup]
}

@MainActor
struct SettingsGroup {
    var header: String?
    var rows: [SettingsRow]
    /// La explicación de debajo. Lo que hace falta saber para usar algo va
    /// aquí, en la propia app, y no en un documento aparte.
    var footer: String?

    init(_ header: String? = nil, footer: String? = nil, rows: [SettingsRow]) {
        self.header = header
        self.rows = rows
        self.footer = footer
    }
}

@MainActor
struct SettingsRow {
    enum Control {
        case none
        /// Un dato que no se toca.
        case value(String)
        case toggle(Bool, (Bool) -> Void)
        /// Varias opciones: segmentado si caben, flechas si no.
        case choice([String], selected: Int, (Int) -> Void)
        case buttons([SettingsButton])
        /// El selector de fondos, con miniaturas. Ocupa la fila entera.
        case wallpapers
    }

    var title: String
    var subtitle: String?
    var symbol: String?
    var control: Control

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, _ control: Control = .none) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.control = control
    }
}

@MainActor
struct SettingsButton {
    enum Style { case normal, accent, destructive }

    var title: String
    var style: Style
    var action: () -> Void

    init(_ title: String, style: Style = .normal, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }
}

// MARK: - Ventana

/// Ajustes en la pantalla externa: los globales, desde la rueda del dock, y
/// los de cada panel, desde la rueda de su barra.
///
/// **Existe porque el iPhone se apaga.** Con monitor conectado, el teléfono
/// pasa a ser sólo superficie táctil: si tuviera controles, el clic izquierdo
/// —que AssistiveTouch convierte en un toque sobre el propio teléfono— acabaría
/// pulsándolos en vez de llegar al escritorio.
///
/// La forma es la de Ajustes del Sistema de macOS: secciones a la izquierda y
/// grupos redondeados a la derecha, con interruptores y selectores de verdad.
/// La primera versión era una lista de filas que cambiaban de valor al
/// pulsarlas, y ni se entendía qué se podía tocar ni dejaba cambiar casi nada.
///
/// Como todo lo de la pantalla externa, **no recibe eventos del sistema**: el
/// escritorio le pasa el cursor y las teclas, y se resuelve por geometría. Las
/// zonas pulsables se apuntan al dibujar, así que lo que se ve y lo que
/// responde salen del mismo cálculo y no pueden desalinearse.
@MainActor
final class SettingsWindow: UIView {

    var onDismiss: (() -> Void)?

    private let windowTitle: String
    private let windowSymbol: String
    private let pages: [SettingsPage]
    private var pageIndex: Int
    private var groups: [SettingsGroup] = []

    private let card = CardView()
    private var scrollOffset: CGFloat = 0
    private var contentHeight: CGFloat = 0

    /// Algo que se puede pulsar, en coordenadas de la tarjeta.
    private struct Region {
        var id: String
        var frame: CGRect
        var action: () -> Void
    }
    private var regions: [Region] = []
    private var hoveredID: String?

    private var observers: [NSObjectProtocol] = []

    init(title: String, symbol: String, pages: [SettingsPage], page: Int = 0, frame: CGRect) {
        self.windowTitle = title
        self.windowSymbol = symbol
        self.pages = pages
        self.pageIndex = min(max(page, 0), max(pages.count - 1, 0))
        super.init(frame: frame)

        backgroundColor = UIColor.black.withAlphaComponent(0.35)

        card.backgroundColor = Tokens.Color.background
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.35
        card.layer.shadowRadius = 30
        card.layer.shadowOffset = CGSize(width: 0, height: 12)
        card.drawContent = { [weak self] context in
            guard let self else { return }
            // `CardView` entrega el contexto en coordenadas de la ventana;
            // aquí todo se cuenta desde la esquina de la tarjeta.
            context.translateBy(x: self.card.frame.minX, y: self.card.frame.minY)
            self.render(in: context)
        }
        addSubview(card)

        // Lo que cambia por fuera —una máquina guardada en el editor, las
        // reglas propias recién compiladas, el modo del iPhone— se ve al
        // momento aunque la ventana esté abierta.
        let names: [Notification.Name] = [
            HostStore.didChangeNotification,
            ContentBlocker.didChangeNotification,
            DesktopTheme.didChangeNotification,
            TerminalTheme.didChangeNotification,
            WallpaperStore.didChangeNotification,
            ExternalDisplayManager.didChangeNotification,
            .brunosSettingsChanged,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }

        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Vuelve a pedir el contenido de la sección y lo repinta.
    func refresh() {
        guard pages.indices.contains(pageIndex) else { return }
        groups = pages[pageIndex].build()
        // El borde es un `CGColor` y no se entera solo del cambio de modo.
        card.layer.borderColor = Tokens.Color.border.desktopCGColor
        layoutRegions()
        card.setNeedsDisplay()
    }

    private func select(page index: Int) {
        guard index != pageIndex, pages.indices.contains(index) else { return }
        pageIndex = index
        scrollOffset = 0
        refresh()
    }

    // MARK: - Medidas

    private static let sidebarWidth: CGFloat = 214
    private static let contentTop: CGFloat = 66
    private static let groupSpacing: CGFloat = 20
    private static let wallpaperTile = CGSize(width: 132, height: 82)

    private var hasSidebar: Bool { pages.count > 1 }
    private var sidebarWidth: CGFloat { hasSidebar ? Self.sidebarWidth : 0 }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(max(bounds.width * 0.62, 640), 900, bounds.width - 40)
        let height = min(max(bounds.height * 0.78, 420), 660, bounds.height - 40)
        card.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
        layoutRegions()
        card.setNeedsDisplay()
    }

    /// Calcula las zonas pulsables sin dibujar: hacen falta antes del primer
    /// dibujado para que el hover y el clic respondan desde el principio.
    private func layoutRegions() {
        render(in: nil)
    }

    private var contentRect: CGRect {
        CGRect(
            x: sidebarWidth,
            y: Self.contentTop,
            width: card.bounds.width - sidebarWidth,
            height: card.bounds.height - Self.contentTop - 10
        )
    }

    // MARK: - Dibujo

    /// Dibuja la tarjeta entera y, de paso, apunta dónde está cada cosa
    /// pulsable. Con `context` a `nil` sólo calcula.
    private func render(in context: CGContext?) {
        regions = []
        let size = card.bounds.size
        guard size.width > 0 else { return }

        if hasSidebar { renderSidebar(in: context, height: size.height) }

        // Cabecera: título de la sección y aspa de cerrar.
        if context != nil {
            let page = pages.indices.contains(pageIndex) ? pages[pageIndex] : nil
            let title = hasSidebar ? (page?.title ?? "") : windowTitle
            (title as NSString).draw(
                at: CGPoint(x: sidebarWidth + 30, y: 22),
                withAttributes: [
                    .font: Tokens.sans(20, weight: .semibold),
                    .foregroundColor: Tokens.Color.text,
                ]
            )
        }
        renderClose(in: context, size: size)

        // Contenido, recortado y desplazable.
        let area = contentRect
        context?.saveGState()
        context?.clip(to: area)
        var y = area.minY - scrollOffset
        let x = area.minX + 30
        let width = area.width - 60

        for (groupIndex, group) in groups.enumerated() {
            y = renderGroup(group, index: groupIndex, x: x, y: y, width: width, clip: area, context: context)
            y += Self.groupSpacing
        }
        context?.restoreGState()

        contentHeight = y + scrollOffset - area.minY
        // Si ha encogido el contenido, que el scroll no se quede en el vacío.
        let maxScroll = max(0, contentHeight - area.height)
        if scrollOffset > maxScroll {
            scrollOffset = maxScroll
        }

        if let context, contentHeight > area.height {
            renderScrollIndicator(in: context, area: area)
        }
    }

    private func renderSidebar(in context: CGContext?, height: CGFloat) {
        if let context {
            let sidebar = CGRect(x: 0, y: 0, width: Self.sidebarWidth, height: height)
            let path = UIBezierPath(
                roundedRect: sidebar,
                byRoundingCorners: [.topLeft, .bottomLeft],
                cornerRadii: CGSize(width: 16, height: 16)
            )
            context.setFillColor(Tokens.Color.panelElevated.desktopCGColor)
            context.addPath(path.cgPath)
            context.fillPath()
            context.setFillColor(Tokens.Color.border.desktopCGColor)
            context.fill(CGRect(x: Self.sidebarWidth - 1, y: 0, width: 1, height: height))

            drawSymbol(windowSymbol, at: CGPoint(x: 28, y: 32), size: 15, color: Tokens.Color.accent)
            (windowTitle as NSString).draw(
                at: CGPoint(x: 44, y: 22),
                withAttributes: [
                    .font: Tokens.sans(15, weight: .semibold),
                    .foregroundColor: Tokens.Color.text,
                ]
            )
        }

        for (index, page) in pages.enumerated() {
            let frame = CGRect(x: 10, y: 62 + CGFloat(index) * 34, width: Self.sidebarWidth - 20, height: 30)
            let id = "page.\(index)"
            regions.append(Region(id: id, frame: frame) { [weak self] in self?.select(page: index) })
            guard let context else { continue }

            let isActive = index == pageIndex
            if isActive || hoveredID == id {
                let color = isActive
                    ? Tokens.Color.accent.withAlphaComponent(0.18)
                    : Tokens.Color.text.withAlphaComponent(0.06)
                context.setFillColor(color.desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 7).cgPath)
                context.fillPath()
            }

            // Icono en un cuadrado de color, como en Ajustes del Sistema: se
            // reconoce la sección antes de leerla.
            let badge = CGRect(x: frame.minX + 8, y: frame.midY - 11, width: 22, height: 22)
            context.setFillColor(page.tint.desktopCGColor)
            context.addPath(UIBezierPath(roundedRect: badge, cornerRadius: 6).cgPath)
            context.fillPath()
            drawSymbol(page.symbol, at: CGPoint(x: badge.midX, y: badge.midY), size: 11.5, color: .white)

            (page.title as NSString).draw(
                at: CGPoint(x: badge.maxX + 10, y: frame.midY - 9),
                withAttributes: [
                    .font: Tokens.sans(13.5, weight: isActive ? .medium : .regular),
                    .foregroundColor: Tokens.Color.text,
                ]
            )
        }
    }

    private func renderClose(in context: CGContext?, size: CGSize) {
        let frame = CGRect(x: size.width - 44, y: 18, width: 26, height: 26)
        regions.append(Region(id: "close", frame: frame) { [weak self] in self?.onDismiss?() })
        guard let context else { return }
        let hovered = hoveredID == "close"
        context.setFillColor((hovered
            ? Tokens.Color.text.withAlphaComponent(0.12)
            : Tokens.Color.text.withAlphaComponent(0.05)).desktopCGColor)
        context.fillEllipse(in: frame)
        drawSymbol("xmark", at: CGPoint(x: frame.midX, y: frame.midY), size: 10,
                   color: hovered ? Tokens.Color.text : Tokens.Color.textSecondary, weight: .bold)
    }

    private func renderScrollIndicator(in context: CGContext, area: CGRect) {
        let ratio = area.height / contentHeight
        let barHeight = max(30, area.height * ratio)
        let travel = area.height - barHeight
        let progress = scrollOffset / max(1, contentHeight - area.height)
        let bar = CGRect(x: area.maxX - 8, y: area.minY + travel * progress, width: 4, height: barHeight)
        context.setFillColor(Tokens.Color.textSecondary.withAlphaComponent(0.35).desktopCGColor)
        context.addPath(UIBezierPath(roundedRect: bar, cornerRadius: 2).cgPath)
        context.fillPath()
    }

    /// Un grupo: rótulo, caja redondeada con sus filas y la nota de debajo.
    /// Devuelve dónde acaba.
    private func renderGroup(
        _ group: SettingsGroup,
        index groupIndex: Int,
        x: CGFloat,
        y start: CGFloat,
        width: CGFloat,
        clip: CGRect,
        context: CGContext?
    ) -> CGFloat {
        var y = start

        if let header = group.header {
            if context != nil {
                (header.uppercased() as NSString).draw(
                    at: CGPoint(x: x + 4, y: y),
                    withAttributes: [
                        .font: Tokens.sans(10.5, weight: .semibold),
                        .foregroundColor: Tokens.Color.textSecondary,
                        .kern: 0.6,
                    ]
                )
            }
            y += 20
        }

        let heights = group.rows.map { rowHeight($0, width: width) }
        let boxHeight = heights.reduce(0, +)
        let box = CGRect(x: x, y: y, width: width, height: boxHeight)

        if let context, !group.rows.isEmpty {
            context.setFillColor(Tokens.Color.panel.desktopCGColor)
            context.addPath(UIBezierPath(roundedRect: box, cornerRadius: 10).cgPath)
            context.fillPath()
            context.setStrokeColor(Tokens.Color.border.withAlphaComponent(0.7).desktopCGColor)
            context.setLineWidth(1)
            context.addPath(UIBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10).cgPath)
            context.strokePath()
        }

        var rowY = y
        for (rowIndex, row) in group.rows.enumerated() {
            let frame = CGRect(x: x, y: rowY, width: width, height: heights[rowIndex])
            // Las filas que no se ven no apuntan zonas: si no, se podría pulsar
            // algo escondido bajo la cabecera.
            if frame.intersects(clip) {
                renderRow(row, id: "\(groupIndex).\(rowIndex)", frame: frame, clip: clip, context: context)
            }
            if let context, rowIndex > 0 {
                context.setFillColor(Tokens.Color.border.withAlphaComponent(0.6).desktopCGColor)
                context.fill(CGRect(x: x + 14, y: rowY, width: width - 14, height: 1))
            }
            rowY += heights[rowIndex]
        }
        y += boxHeight

        if let footer = group.footer {
            let attributes = footerAttributes
            let bounds = (footer as NSString).boundingRect(
                with: CGSize(width: width - 8, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: attributes,
                context: nil
            )
            if context != nil {
                (footer as NSString).draw(
                    with: CGRect(x: x + 4, y: y + 7, width: width - 8, height: ceil(bounds.height)),
                    options: [.usesLineFragmentOrigin],
                    attributes: attributes,
                    context: nil
                )
            }
            y += 7 + ceil(bounds.height)
        }
        return y
    }

    private var footerAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return [
            .font: Tokens.sans(11.5),
            .foregroundColor: Tokens.Color.textSecondary,
            .paragraphStyle: paragraph,
        ]
    }

    private func rowHeight(_ row: SettingsRow, width: CGFloat) -> CGFloat {
        if case .wallpapers = row.control {
            let count = AppServices.shared.wallpaper.available.count
            let tile = Self.wallpaperTile
            let columns = max(1, Int((width - 28 + 14) / (tile.width + 14)))
            let lines = (count + columns - 1) / columns
            return 16 + CGFloat(lines) * (tile.height + 34)
        }
        return row.subtitle == nil ? 42 : 54
    }

    // MARK: - Filas

    private func renderRow(_ row: SettingsRow, id: String, frame: CGRect, clip: CGRect, context: CGContext?) {
        if case .wallpapers = row.control {
            renderWallpapers(id: id, frame: frame, clip: clip, context: context)
            return
        }

        var textX = frame.minX + 14
        if let symbol = row.symbol {
            if context != nil {
                drawSymbol(symbol, at: CGPoint(x: textX + 8, y: frame.midY), size: 13,
                           color: Tokens.Color.textSecondary)
            }
            textX += 28
        }

        // El control primero: el título se recorta con lo que le deje.
        let controlLeft = renderControl(row.control, id: id, row: frame, right: frame.maxX - 14, context: context)
        let titleWidth = max(40, controlLeft - textX - 16)

        guard context != nil else { return }
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(13.5),
            .foregroundColor: Tokens.Color.text,
            .paragraphStyle: truncating,
        ]
        if let subtitle = row.subtitle {
            (row.title as NSString).draw(
                in: CGRect(x: textX, y: frame.minY + 9, width: titleWidth, height: 18),
                withAttributes: titleAttributes
            )
            (subtitle as NSString).draw(
                in: CGRect(x: textX, y: frame.minY + 28, width: titleWidth, height: 16),
                withAttributes: [
                    .font: Tokens.sans(11.5),
                    .foregroundColor: Tokens.Color.textSecondary,
                    .paragraphStyle: truncating,
                ]
            )
        } else {
            (row.title as NSString).draw(
                in: CGRect(x: textX, y: frame.midY - 9, width: titleWidth, height: 18),
                withAttributes: titleAttributes
            )
        }
    }

    private var truncating: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }

    /// Dibuja el control pegado a la derecha y devuelve dónde empieza.
    private func renderControl(
        _ control: SettingsRow.Control,
        id: String,
        row: CGRect,
        right: CGFloat,
        context: CGContext?
    ) -> CGFloat {
        switch control {
        case .none, .wallpapers:
            return right

        case .value(let text):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Tokens.mono(12),
                .foregroundColor: Tokens.Color.textSecondary,
                .paragraphStyle: truncating,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let width = min(size.width + 1, row.width * 0.55)
            let frame = CGRect(x: right - width, y: row.midY - size.height / 2, width: width, height: size.height)
            if context != nil {
                (text as NSString).draw(in: frame, withAttributes: attributes)
            }
            return frame.minX

        case .toggle(let isOn, let change):
            let frame = CGRect(x: right - 38, y: row.midY - 11, width: 38, height: 22)
            // Se puede pulsar la fila entera, no sólo el interruptor: es un
            // blanco mucho más fácil con un cursor.
            regions.append(Region(id: id, frame: row) { change(!isOn) })
            if let context {
                let track = isOn
                    ? Tokens.Color.accent
                    : Tokens.Color.textSecondary.withAlphaComponent(hoveredID == id ? 0.45 : 0.3)
                context.setFillColor(track.desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 11).cgPath)
                context.fillPath()
                let knob = CGRect(
                    x: isOn ? frame.maxX - 20 : frame.minX + 2,
                    y: frame.minY + 2, width: 18, height: 18
                )
                context.setShadow(offset: CGSize(width: 0, height: 1), blur: 2,
                                  color: UIColor.black.withAlphaComponent(0.25).cgColor)
                context.setFillColor(UIColor.white.cgColor)
                context.fillEllipse(in: knob)
                context.setShadow(offset: .zero, blur: 0, color: nil)
            }
            return frame.minX

        case .choice(let options, let selected, let change):
            return renderChoice(options, selected: selected, change: change, id: id, row: row, right: right,
                                context: context)

        case .buttons(let buttons):
            var x = right
            for (index, button) in buttons.enumerated().reversed() {
                let attributes: [NSAttributedString.Key: Any] = [.font: Tokens.sans(12, weight: .medium)]
                let size = (button.title as NSString).size(withAttributes: attributes)
                let frame = CGRect(x: x - size.width - 24, y: row.midY - 13, width: size.width + 24, height: 26)
                let buttonID = "\(id).b\(index)"
                regions.append(Region(id: buttonID, frame: frame, action: button.action))
                if let context {
                    drawButton(button, frame: frame, hovered: hoveredID == buttonID, context: context)
                }
                x = frame.minX - 8
            }
            return x
        }
    }

    private func drawButton(_ button: SettingsButton, frame: CGRect, hovered: Bool, context: CGContext) {
        let path = UIBezierPath(roundedRect: frame, cornerRadius: 7).cgPath
        let textColor: UIColor
        switch button.style {
        case .accent:
            context.setFillColor(Tokens.Color.accent.withAlphaComponent(hovered ? 0.85 : 1).desktopCGColor)
            context.addPath(path)
            context.fillPath()
            textColor = Tokens.Color.background
        case .normal, .destructive:
            context.setFillColor((hovered
                ? Tokens.Color.text.withAlphaComponent(0.08)
                : Tokens.Color.background).desktopCGColor)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(Tokens.Color.border.desktopCGColor)
            context.setLineWidth(1)
            context.addPath(UIBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 7).cgPath)
            context.strokePath()
            textColor = button.style == .destructive ? Tokens.Color.danger : Tokens.Color.text
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(12, weight: .medium),
            .foregroundColor: textColor,
        ]
        let size = (button.title as NSString).size(withAttributes: attributes)
        (button.title as NSString).draw(
            at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    /// Segmentado si las opciones caben en algo más de media fila; si no,
    /// flechas a los lados del valor, que valen para cualquier número de
    /// opciones.
    private func renderChoice(
        _ options: [String],
        selected: Int,
        change: @escaping (Int) -> Void,
        id: String,
        row: CGRect,
        right: CGFloat,
        context: CGContext?
    ) -> CGFloat {
        let font = Tokens.sans(12, weight: .semibold)
        let widths = options.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 22 }
        let total = widths.reduce(0, +) + 4

        if total <= row.width * 0.6 {
            let container = CGRect(x: right - total, y: row.midY - 14, width: total, height: 28)
            if let context {
                context.setFillColor(Tokens.Color.background.desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: container, cornerRadius: 8).cgPath)
                context.fillPath()
            }
            var x = container.minX + 2
            for (index, option) in options.enumerated() {
                let frame = CGRect(x: x, y: container.minY + 2, width: widths[index], height: 24)
                let segmentID = "\(id).s\(index)"
                regions.append(Region(id: segmentID, frame: frame) { change(index) })
                if let context {
                    let isSelected = index == selected
                    if isSelected || hoveredID == segmentID {
                        let fill = isSelected
                            ? Tokens.Color.accent.withAlphaComponent(0.18)
                            : Tokens.Color.text.withAlphaComponent(0.06)
                        context.setFillColor(fill.desktopCGColor)
                        context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
                        context.fillPath()
                    }
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: isSelected ? Tokens.sans(12, weight: .semibold) : Tokens.sans(12),
                        .foregroundColor: isSelected ? Tokens.Color.accent : Tokens.Color.text,
                    ]
                    let size = (option as NSString).size(withAttributes: attributes)
                    (option as NSString).draw(
                        at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
                        withAttributes: attributes
                    )
                }
                x += widths[index]
            }
            return container.minX
        }

        // Flechas: ‹ valor ›. El valor se lleva el ancho de la opción más
        // larga, para que las flechas no bailen al cambiar.
        let valueWidth = (widths.max() ?? 60) - 6
        let next = CGRect(x: right - 26, y: row.midY - 13, width: 26, height: 26)
        let value = CGRect(x: next.minX - valueWidth, y: row.midY - 13, width: valueWidth, height: 26)
        let previous = CGRect(x: value.minX - 26, y: row.midY - 13, width: 26, height: 26)
        let count = max(options.count, 1)
        regions.append(Region(id: "\(id).prev", frame: previous) { change((selected - 1 + count) % count) })
        regions.append(Region(id: "\(id).next", frame: value.union(next)) { change((selected + 1) % count) })

        if let context {
            let container = previous.union(next)
            context.setFillColor(Tokens.Color.background.desktopCGColor)
            context.addPath(UIBezierPath(roundedRect: container, cornerRadius: 8).cgPath)
            context.fillPath()
            for (frame, symbol, regionID) in [(previous, "chevron.left", "\(id).prev"),
                                              (next, "chevron.right", "\(id).next")] {
                if hoveredID == regionID {
                    context.setFillColor(Tokens.Color.text.withAlphaComponent(0.08).desktopCGColor)
                    context.addPath(UIBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), cornerRadius: 6).cgPath)
                    context.fillPath()
                }
                drawSymbol(symbol, at: CGPoint(x: frame.midX, y: frame.midY), size: 10,
                           color: Tokens.Color.textSecondary, weight: .semibold)
            }
            let text = options.indices.contains(selected) ? options[selected] : ""
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Tokens.sans(12, weight: .semibold),
                .foregroundColor: Tokens.Color.accent,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(x: value.midX - size.width / 2, y: value.midY - size.height / 2),
                withAttributes: attributes
            )
        }
        return previous.minX
    }

    private func renderWallpapers(id: String, frame: CGRect, clip: CGRect, context: CGContext?) {
        let store = AppServices.shared.wallpaper
        let tile = Self.wallpaperTile
        let columns = max(1, Int((frame.width - 28 + 14) / (tile.width + 14)))
        let spacing = columns > 1
            ? (frame.width - 28 - CGFloat(columns) * tile.width) / CGFloat(columns - 1)
            : 0

        for (index, wallpaper) in store.available.enumerated() {
            let tileFrame = CGRect(
                x: frame.minX + 14 + CGFloat(index % columns) * (tile.width + spacing),
                y: frame.minY + 14 + CGFloat(index / columns) * (tile.height + 34),
                width: tile.width,
                height: tile.height
            )
            guard tileFrame.intersects(clip) else { continue }
            let tileID = "\(id).w\(index)"
            regions.append(Region(id: tileID, frame: tileFrame.insetBy(dx: -4, dy: -4)) {
                store.current = wallpaper
            })
            guard let context else { continue }

            let isCurrent = wallpaper == store.current
            context.saveGState()
            UIBezierPath(roundedRect: tileFrame, cornerRadius: 8).addClip()
            store.thumbnail(for: wallpaper, size: tile).draw(in: tileFrame)
            context.restoreGState()

            context.setStrokeColor(Tokens.Color.border.desktopCGColor)
            context.setLineWidth(1)
            context.addPath(UIBezierPath(roundedRect: tileFrame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 8).cgPath)
            context.strokePath()

            if isCurrent || hoveredID == tileID {
                context.setStrokeColor((isCurrent
                    ? Tokens.Color.accent
                    : Tokens.Color.textSecondary.withAlphaComponent(0.6)).desktopCGColor)
                context.setLineWidth(isCurrent ? 2.5 : 1.5)
                context.addPath(UIBezierPath(roundedRect: tileFrame.insetBy(dx: -3, dy: -3), cornerRadius: 10).cgPath)
                context.strokePath()
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            (wallpaper.label as NSString).draw(
                in: CGRect(x: tileFrame.minX - 6, y: tileFrame.maxY + 7, width: tileFrame.width + 12, height: 16),
                withAttributes: [
                    .font: Tokens.sans(11.5, weight: isCurrent ? .semibold : .regular),
                    .foregroundColor: isCurrent ? Tokens.Color.text : Tokens.Color.textSecondary,
                    .paragraphStyle: paragraph,
                ]
            )
        }
    }

    private func drawSymbol(
        _ name: String,
        at center: CGPoint,
        size: CGFloat,
        color: UIColor,
        weight: UIImage.SymbolWeight = .regular
    ) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(
                color.resolvedColor(with: UITraitCollection(userInterfaceStyle: DesktopTheme.style)),
                renderingMode: .alwaysOriginal
            )
        else { return }
        image.draw(at: CGPoint(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2))
    }

    // MARK: - Entrada

    /// Devuelve `true` si consumió el evento: mientras está abierta, todo es
    /// suyo.
    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        guard card.frame.contains(point) else {
            if case .down = kind { onDismiss?() }
            return true
        }
        let local = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)
        // La última zona apuntada es la que está encima: un botón dentro de
        // una fila que también se puede pulsar entera.
        let region = regions.last { $0.frame.contains(local) }

        switch kind {
        case .moved:
            if hoveredID != region?.id {
                hoveredID = region?.id
                card.setNeedsDisplay()
            }
        case .down(let button) where button == .left:
            region?.action()
            refresh()
        case .scroll(let delta):
            let area = contentRect
            let maxScroll = max(0, contentHeight - area.height)
            scrollOffset = min(max(scrollOffset - delta.dy, 0), maxScroll)
            layoutRegions()
            card.setNeedsDisplay()
        default:
            break
        }
        return true
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }
        switch event.key.keyCode {
        case .keyboardEscape:
            onDismiss?()
        case .keyboardUpArrow where event.key.modifierFlags.contains(.command):
            select(page: pageIndex - 1)
        case .keyboardDownArrow where event.key.modifierFlags.contains(.command):
            select(page: pageIndex + 1)
        default:
            break
        }
        return true
    }
}

extension Notification.Name {
    /// Algo que enseñan los ajustes ha cambiado por una vía que no tiene
    /// notificación propia: una carpeta añadida desde el iPhone, por ejemplo.
    static let brunosSettingsChanged = Notification.Name("BrunOSSettingsChanged")
}

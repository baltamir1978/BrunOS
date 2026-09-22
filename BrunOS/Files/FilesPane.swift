import UIKit

/// Gestor de ficheros, estilo Finder: ubicaciones a la izquierda y la lista a
/// la derecha.
///
/// **Ni un `UITableView` ni un `UIButton`.** En la pantalla externa no hay
/// eventos del sistema: el escritorio entrega el cursor y las teclas, y aquí se
/// resuelve todo por geometría. Una tabla de UIKit no se enteraría de nada.
@MainActor
final class FilesPane: UIView, Pane {

    private static let sidebarWidth: CGFloat = 150
    private static let headerHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 26

    private let services = AppServices.shared

    private var items: [FileItem] = []
    private var path: String
    private var selectedIndex: Int?
    private var hoveredIndex: Int?
    private var scrollOffset: CGFloat = 0
    private var status: String?
    private var sort: Sort = .name

    private enum Sort {
        case name, size, date

        var label: String {
            switch self {
            case .name: "Nombre"
            case .size: "Tamaño"
            case .date: "Fecha"
            }
        }
    }

    private var rowFrames: [CGRect] = []
    private var sidebarFrames: [CGRect] = []
    private var sortFrames: [Sort: CGRect] = [:]

    var title: String {
        let provider = services.files.currentProvider
        let relative = path == provider.rootPath
            ? ""
            : " · " + (path as NSString).lastPathComponent
        return provider.name + relative
    }

    var view: UIView { self }

    override init(frame: CGRect) {
        path = services.files.currentProvider.rootPath
        super.init(frame: frame)

        backgroundColor = Tokens.Color.panel
        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = Tokens.Metric.focusBorderWidth
        layer.borderColor = Tokens.Color.border.desktopCGColor
        clipsToBounds = true
        contentMode = .redraw

        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Datos

    private func reload() {
        let provider = services.files.currentProvider
        let path = self.path
        status = nil

        Task { [weak self] in
            do {
                let listed = try await provider.list(path)
                guard let self else { return }
                self.items = self.sorted(listed)
                self.selectedIndex = self.items.isEmpty ? nil : 0
                self.scrollOffset = 0
                self.setNeedsLayout()
                self.setNeedsDisplay()
                AppServices.shared.desktop.notifyChange()
            } catch {
                self?.items = []
                self?.status = error.localizedDescription
                self?.setNeedsDisplay()
            }
        }
    }

    /// Las carpetas siempre primero, como en cualquier gestor: mezcladas con
    /// los ficheros cuesta encontrarlas.
    private func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return switch sort {
            case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: a.size > b.size
            case .date: (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            }
        }
    }

    // MARK: - Navegación

    private func open(_ item: FileItem) {
        if item.isDirectory {
            path = item.path
            reload()
        } else {
            preview(item)
        }
    }

    private func goUp() {
        guard let parent = services.files.currentProvider.parent(of: path) else { return }
        path = parent
        reload()
    }

    private func preview(_ item: FileItem) {
        services.desktopViewController?.presentQuickLook(for: item)
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeFrames()
        setNeedsDisplay()
    }

    private func recomputeFrames() {
        sidebarFrames = services.files.providers.indices.map { index in
            CGRect(
                x: 6, y: 34 + CGFloat(index) * 28,
                width: Self.sidebarWidth - 12, height: 26
            )
        }

        let listX = Self.sidebarWidth
        let listWidth = bounds.width - listX
        sortFrames = [
            .name: CGRect(x: listX + 34, y: 6, width: 140, height: 18),
            .size: CGRect(x: bounds.width - 190, y: 6, width: 70, height: 18),
            .date: CGRect(x: bounds.width - 118, y: 6, width: 110, height: 18),
        ]

        rowFrames = items.indices.map { index in
            CGRect(
                x: listX,
                y: Self.headerHeight + CGFloat(index) * Self.rowHeight - scrollOffset,
                width: listWidth,
                height: Self.rowHeight
            )
        }
    }

    // MARK: - Dibujo

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawSidebar(in: context)
        drawHeader(in: context)
        drawRows(in: context)
    }

    private func drawSidebar(in context: CGContext) {
        context.setFillColor(Tokens.Color.panelElevated.desktopCGColor)
        context.fill(CGRect(x: 0, y: 0, width: Self.sidebarWidth, height: bounds.height))
        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.fill(CGRect(x: Self.sidebarWidth - 1, y: 0, width: 1, height: bounds.height))

        ("UBICACIONES" as NSString).draw(
            at: CGPoint(x: 12, y: 12),
            withAttributes: [
                .font: Tokens.sans(9, weight: .semibold),
                .foregroundColor: Tokens.Color.textSecondary,
            ]
        )

        for (index, provider) in services.files.providers.enumerated() {
            guard index < sidebarFrames.count else { break }
            let frame = sidebarFrames[index]
            let isActive = provider === services.files.currentProvider

            if isActive {
                context.setFillColor(Tokens.Color.accent.withAlphaComponent(0.2).desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
                context.fillPath()
            }

            drawSymbol(
                provider.symbol,
                in: CGRect(x: frame.minX + 6, y: frame.midY - 8, width: 16, height: 16),
                color: isActive ? Tokens.Color.accent : Tokens.Color.textSecondary
            )
            (provider.name as NSString).draw(
                at: CGPoint(x: frame.minX + 28, y: frame.midY - 8),
                withAttributes: [
                    .font: Tokens.sans(13),
                    .foregroundColor: isActive ? Tokens.Color.text : Tokens.Color.textSecondary,
                ]
            )
        }
    }

    private func drawHeader(in context: CGContext) {
        let listX = Self.sidebarWidth
        context.setFillColor(Tokens.Color.panelElevated.desktopCGColor)
        context.fill(CGRect(x: listX, y: 0, width: bounds.width - listX, height: Self.headerHeight))
        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.fill(CGRect(
            x: listX, y: Self.headerHeight - 1,
            width: bounds.width - listX, height: 1
        ))

        for (kind, frame) in sortFrames {
            let isActive = kind == sort
            (kind.label as NSString).draw(
                at: CGPoint(x: frame.minX, y: frame.minY),
                withAttributes: [
                    .font: Tokens.sans(11, weight: isActive ? .semibold : .regular),
                    .foregroundColor: isActive ? Tokens.Color.accent : Tokens.Color.textSecondary,
                ]
            )
        }
    }

    private func drawRows(in context: CGContext) {
        if let status {
            (status as NSString).draw(
                in: CGRect(
                    x: Self.sidebarWidth + 16, y: Self.headerHeight + 16,
                    width: bounds.width - Self.sidebarWidth - 32, height: 60
                ),
                withAttributes: [
                    .font: Tokens.sans(13),
                    .foregroundColor: Tokens.Color.textSecondary,
                ]
            )
            return
        }

        if items.isEmpty {
            ("Carpeta vacía" as NSString).draw(
                at: CGPoint(x: Self.sidebarWidth + 16, y: Self.headerHeight + 16),
                withAttributes: [
                    .font: Tokens.sans(13),
                    .foregroundColor: Tokens.Color.textSecondary,
                ]
            )
            return
        }

        for (index, item) in items.enumerated() {
            guard index < rowFrames.count else { break }
            let frame = rowFrames[index]
            // Sólo se dibuja lo que se ve: una carpeta con mil ficheros no
            // tiene por qué costar mil dibujados.
            guard frame.maxY > Self.headerHeight, frame.minY < bounds.height else { continue }

            if index == selectedIndex {
                context.setFillColor(Tokens.Color.accent.withAlphaComponent(0.22).desktopCGColor)
                context.fill(frame)
            } else if index == hoveredIndex {
                context.setFillColor(Tokens.Color.text.withAlphaComponent(0.06).desktopCGColor)
                context.fill(frame)
            }

            drawSymbol(
                symbol(for: item),
                in: CGRect(x: frame.minX + 10, y: frame.midY - 8, width: 16, height: 16),
                color: item.isDirectory ? Tokens.Color.accent : Tokens.Color.textSecondary
            )

            (item.name as NSString).draw(
                in: CGRect(
                    x: frame.minX + 34, y: frame.midY - 8,
                    width: max(0, bounds.width - frame.minX - 230), height: 16
                ),
                withAttributes: [
                    .font: Tokens.sans(13),
                    .foregroundColor: Tokens.Color.text,
                ]
            )

            let meta: [NSAttributedString.Key: Any] = [
                .font: Tokens.mono(10),
                .foregroundColor: Tokens.Color.textSecondary,
            ]
            (item.sizeLabel as NSString).draw(
                at: CGPoint(x: bounds.width - 190, y: frame.midY - 6),
                withAttributes: meta
            )
            (item.modifiedLabel as NSString).draw(
                at: CGPoint(x: bounds.width - 118, y: frame.midY - 6),
                withAttributes: meta
            )
        }
    }

    private func symbol(for item: FileItem) -> String {
        switch item.kind {
        case .folder: "folder.fill"
        case .image: "photo"
        case .media: "play.rectangle"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        case .other: "doc"
        }
    }

    private func drawSymbol(_ name: String, in frame: CGRect, color: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(
                color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)),
                renderingMode: .alwaysOriginal
            )
        else { return }
        image.draw(at: CGPoint(
            x: frame.midX - image.size.width / 2,
            y: frame.midY - image.size.height / 2
        ))
    }

    // MARK: - Pane

    func setFocused(_ focused: Bool) {
        layer.borderColor = focused
            ? Tokens.Color.accent.desktopCGColor
            : Tokens.Color.border.desktopCGColor
    }

    func handlePointer(_ event: PointerEvent) {
        switch event.kind {
        case .moved:
            let index = rowFrames.firstIndex { $0.contains(event.location) }
            if hoveredIndex != index {
                hoveredIndex = index
                setNeedsDisplay()
            }

        case .down:
            if let index = sidebarFrames.firstIndex(where: { $0.contains(event.location) }) {
                services.files.select(index)
                path = services.files.currentProvider.rootPath
                reload()
                return
            }
            for (kind, frame) in sortFrames where frame.insetBy(dx: -6, dy: -6).contains(event.location) {
                sort = kind
                items = sorted(items)
                setNeedsDisplay()
                return
            }
            if let index = rowFrames.firstIndex(where: { $0.contains(event.location) }) {
                // Un clic selecciona; para abrir, Intro o la espaciadora. El
                // doble clic con un cursor sintético es poco fiable: depende de
                // que dos eventos lleguen lo bastante seguidos.
                selectedIndex = index
                setNeedsDisplay()
                AppServices.shared.desktop.notifyChange()
            }

        case .scroll(let delta):
            scroll(by: -delta.dy)

        case .up:
            break
        }
    }

    /// Menú del clic derecho.
    func contextMenuEntries(at location: CGPoint) -> [ContextMenu.Entry] {
        let index = rowFrames.firstIndex { $0.contains(location) }
        if let index { selectedIndex = index; setNeedsDisplay() }
        let item = index.flatMap { items.indices.contains($0) ? items[$0] : nil }
        let files = services.files

        var entries: [ContextMenu.Entry] = []

        if let item {
            if !item.isDirectory {
                entries.append(ContextMenu.Entry(title: "Vista previa", symbol: "eye") { [weak self] in
                    self?.preview(item)
                })
                entries.append(ContextMenu.Entry(
                    title: "Abrir en el navegador",
                    symbol: "safari"
                ) { [weak self] in
                    self?.openInBrowser(item)
                })
            } else {
                entries.append(ContextMenu.Entry(title: "Abrir", symbol: "folder") { [weak self] in
                    self?.open(item)
                })
            }
            entries.append(ContextMenu.Entry(title: "Copiar", symbol: "doc.on.doc") {
                files.copy(item)
            })
            entries.append(ContextMenu.Entry(title: "Cortar", symbol: "scissors") {
                files.cut(item)
            })
            entries.append(ContextMenu.Entry(title: "Renombrar", symbol: "pencil") { [weak self] in
                self?.startRename(item)
            })
            entries.append(ContextMenu.Entry(
                title: "Borrar",
                symbol: "trash",
                isDestructive: true
            ) { [weak self] in
                self?.confirmDelete(item)
            })
        }

        entries.append(ContextMenu.Entry(
            title: "Pegar",
            symbol: "doc.on.clipboard",
            isEnabled: files.clipboard != nil
        ) { [weak self] in
            self?.paste()
        })
        entries.append(ContextMenu.Entry(title: "Nueva carpeta", symbol: "folder.badge.plus") { [weak self] in
            self?.createFolder()
        })
        entries.append(ContextMenu.Entry(
            title: "Añadir ubicación…",
            symbol: "folder.badge.plus"
        ) {
            // iCloud, una carpeta de Archivos o el USB: en iOS las tres se
            // añaden igual, con el selector de carpetas del sistema.
            NotificationCenter.default.post(name: .brunosPickFolder, object: nil)
        })

        return entries
    }

    // MARK: - Operaciones

    private func openInBrowser(_ item: FileItem) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.services.files.currentProvider.localURL(for: item)
                self.services.desktopViewController?.openInBrowser(url)
            } catch {
                self.show(error)
            }
        }
    }

    private func paste() {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.status = "Copiando…"
                self.setNeedsDisplay()
                try await self.services.files.paste(into: self.path)
                self.reload()
            } catch {
                self.show(error)
            }
        }
    }

    private func startRename(_ item: FileItem) {
        services.desktopViewController?.presentPrompt(
            title: "Renombrar",
            value: item.name
        ) { [weak self] newName in
            guard let self, let newName, newName != item.name else { return }
            Task {
                do {
                    try await self.services.files.currentProvider.rename(item.path, to: newName)
                    self.reload()
                } catch {
                    self.show(error)
                }
            }
        }
    }

    private func createFolder() {
        services.desktopViewController?.presentPrompt(
            title: "Nueva carpeta",
            value: "Sin título"
        ) { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            let path = self.path.hasSuffix("/") ? self.path + name : self.path + "/" + name
            Task {
                do {
                    try await self.services.files.currentProvider.createDirectory(path)
                    self.reload()
                } catch {
                    self.show(error)
                }
            }
        }
    }

    /// Borrar **siempre pregunta**: no hay papelera de donde recuperarlo.
    private func confirmDelete(_ item: FileItem) {
        services.desktopViewController?.presentConfirm(
            title: "¿Borrar \(item.name)?",
            message: "No se puede deshacer: BrunOS no tiene papelera.",
            destructive: "Borrar"
        ) { [weak self] confirmed in
            guard let self, confirmed else { return }
            Task {
                do {
                    try await self.services.files.currentProvider.delete(item.path)
                    self.reload()
                } catch {
                    self.show(error)
                }
            }
        }
    }

    private func show(_ error: any Error) {
        status = error.localizedDescription
        setNeedsDisplay()
    }

    private func scroll(by amount: CGFloat) {
        let total = CGFloat(items.count) * Self.rowHeight
        let visible = bounds.height - Self.headerHeight
        guard total > visible else { return }
        scrollOffset = min(max(scrollOffset + amount, 0), total - visible)
        setNeedsLayout()
        setNeedsDisplay()
    }

    func handleKey(_ event: KeyEvent) {
        guard event.phase == .down else { return }

        switch event.key.keyCode {
        case .keyboardUpArrow:
            move(by: -1)
        case .keyboardDownArrow:
            move(by: 1)
        case .keyboardReturnOrEnter:
            if let index = selectedIndex, items.indices.contains(index) {
                open(items[index])
            }
        case .keyboardSpacebar:
            // La espaciadora es la vista previa, como en el Finder.
            if let index = selectedIndex, items.indices.contains(index) {
                preview(items[index])
            }
        case .keyboardDeleteOrBackspace:
            goUp()
        default:
            break
        }
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(max((selectedIndex ?? 0) + delta, 0), items.count - 1)
        selectedIndex = next
        // Que la selección no se vaya fuera de la vista al moverse con flechas.
        let rowTop = CGFloat(next) * Self.rowHeight
        let visible = bounds.height - Self.headerHeight
        if rowTop < scrollOffset {
            scrollOffset = rowTop
        } else if rowTop + Self.rowHeight > scrollOffset + visible {
            scrollOffset = rowTop + Self.rowHeight - visible
        }
        setNeedsLayout()
        setNeedsDisplay()
        AppServices.shared.desktop.notifyChange()
    }

    /// Vuelve a leer la carpeta. La usa el escritorio tras borrar o renombrar.
    func refresh() {
        reload()
    }
}

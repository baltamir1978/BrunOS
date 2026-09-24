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
    private static let headerHeight: CGFloat = 36
    private static let rowHeight: CGFloat = 26

    private let services = AppServices.shared

    /// Lo que se ve: la carpeta entera o, con Cmd+F, lo que coincide.
    private var items: [FileItem] = []
    /// La carpeta entera, ya ordenada.
    private var allItems: [FileItem] = []
    /// Cmd+F filtra por nombre. La barra va abajo, sobre la lista.
    private let findBar = FindBar()
    private var isFinding = false
    private var filter = ""
    private var path: String
    /// La ubicación de **esta** ventana, por su clave (`FileService.key(of:)`).
    /// Con la clave y no con el objeto: `rebuild()` crea los orígenes de nuevo.
    private var locationKey: String
    /// El elemento con el foco: el último pulsado, el que mueven las flechas
    /// y desde donde cuenta Mayús+clic.
    private var selectedIndex: Int?
    /// Todo lo seleccionado, con Cmd+clic, Mayús+clic o Cmd+A. Incluye
    /// siempre `selectedIndex`.
    private var selection: Set<Int> = []
    private var hoveredIndex: Int?
    private var scrollOffset: CGFloat = 0
    private var status: String?
    private var sort: Sort = .name
    private var mode = ViewMode.current {
        didSet { ViewMode.current = mode }
    }
    /// Miniaturas de las imágenes, por ruta. Sólo en local: por SFTP habría que
    /// descargar cada foto entera para enseñar un sello de 84 puntos.
    private var thumbnails: [String: UIImage] = [:]
    private var pendingThumbnails: Set<String> = []
    /// El último clic, para reconocer el doble clic.
    private var lastClick: (index: Int, time: Date, location: CGPoint)?
    private static let doubleClickInterval: TimeInterval = 0.5
    /// El botón de subir un nivel, en la cabecera.
    private var upFrame: CGRect = .zero

    /// Un clic sobre un elemento que todavía puede convertirse en arrastre.
    private var press: (index: Int, location: CGPoint)?
    /// Dónde caería lo que se está arrastrando, para marcarlo.
    private var dropHighlight: DropTarget?

    /// Dónde se puede soltar algo en este panel.
    enum DropTarget: Equatable {
        case folder(Int)
        case location(Int)
        case here
    }

    /// La copia en curso y cómo va.
    private var pasteTask: Task<Void, Never>?
    private var copyProgress: FileService.Progress?
    private var cancelCopyFrame: CGRect = .zero

    /// Qué dejar seleccionado cuando termine de leerse la carpeta.
    private var pendingSelection: String?

    /// Cómo se enseña la carpeta, como en el Finder.
    enum ViewMode: String, CaseIterable {
        case list, smallIcons, largeIcons

        private static let key = "files.viewMode"

        static var current: ViewMode {
            get {
                UserDefaults.standard.string(forKey: key)
                    .flatMap(ViewMode.init(rawValue:)) ?? .list
            }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }

        var label: String {
            switch self {
            case .list: "Lista"
            case .smallIcons: "Iconos pequeños"
            case .largeIcons: "Iconos grandes"
            }
        }

        var symbol: String {
            switch self {
            case .list: "list.bullet"
            case .smallIcons: "square.grid.3x3"
            case .largeIcons: "square.grid.2x2"
            }
        }

        /// Tamaño de cada casilla en las vistas de iconos.
        var cellSize: CGSize {
            switch self {
            case .list: .zero
            case .smallIcons: CGSize(width: 96, height: 92)
            case .largeIcons: CGSize(width: 140, height: 138)
            }
        }

        /// Lado del cuadrado donde va el icono o la miniatura.
        var iconSide: CGFloat {
            switch self {
            case .list: 16
            case .smallIcons: 46
            case .largeIcons: 84
            }
        }
    }

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

    /// Lo que ocupa cada elemento: una fila en la lista, una casilla en iconos.
    private var rowFrames: [CGRect] = []
    private var sidebarFrames: [CGRect] = []
    private var sortFrames: [Sort: CGRect] = [:]
    private var modeFrames: [ViewMode: CGRect] = [:]
    private var settingsFrame: CGRect = .zero
    private var hoveringControls = false
    private static let controlsX: CGFloat = 13
    private static var controlsMidY: CGFloat { headerHeight / 2 }
    /// Casillas por fila en las vistas de iconos. Lo usan las flechas.
    private var columns = 1

    /// Dónde empiezan las columnas de tamaño y fecha, medido desde la derecha.
    /// Dejan sitio al selector de vista, que va en la cabecera.
    private static let sizeColumnInset: CGFloat = 310
    private static let dateColumnInset: CGFloat = 238
    private static let gridPadding: CGFloat = 12

    /// El origen que enseña esta ventana. Si se quitó, el iPhone.
    private var provider: any FileProvider {
        services.files.provider(forKey: locationKey) ?? services.files.providers[0]
    }

    var title: String {
        let provider = self.provider
        let relative = path == provider.rootPath
            ? ""
            : " · " + (path as NSString).lastPathComponent
        return provider.name + relative
    }

    var view: UIView { self }

    override init(frame: CGRect) {
        // Una ventana nueva abre donde se estuvo la última vez.
        let start = AppServices.shared.files.currentProvider
        locationKey = FileService.key(of: start)
        path = start.rootPath
        super.init(frame: frame)

        backgroundColor = Tokens.Color.panel
        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = Tokens.Metric.focusBorderWidth
        layer.borderColor = Tokens.Color.border.desktopCGColor
        clipsToBounds = true
        contentMode = .redraw

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewModeChanged),
            name: Self.viewModeDidChange,
            object: nil
        )

        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    static let viewModeDidChange = Notification.Name("BrunOSFilesViewModeDidChange")

    @objc private func viewModeChanged() {
        setMode(ViewMode.current)
    }

    // MARK: - Datos

    private func reload() {
        let provider = self.provider
        let path = self.path
        status = nil

        Task { [weak self] in
            do {
                let listed = try await provider.list(path)
                guard let self else { return }
                self.allItems = self.sorted(listed)
                self.items = self.filtered(self.allItems)
                let wanted = self.pendingSelection
                self.pendingSelection = nil
                self.thumbnails = [:]
                self.pendingThumbnails = []
                self.selectOnly(wanted.flatMap { name in self.items.firstIndex { $0.name == name } }
                    ?? (self.items.isEmpty ? nil : 0))
                self.scrollOffset = 0
                self.setNeedsLayout()
                self.setNeedsDisplay()
                AppServices.shared.desktop.notifyTitleChange()
            } catch {
                self?.items = []
                self?.allItems = []
                self?.selectOnly(nil)
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
        guard let parent = provider.parent(of: path) else { return }
        path = parent
        reload()
    }

    private func preview(_ item: FileItem) {
        services.desktopViewController?.presentQuickLook(for: item, from: provider)
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()
        findBar.isHidden = !isFinding
        findBar.frame = CGRect(
            x: Self.sidebarWidth, y: bounds.height - FindBar.height,
            width: bounds.width - Self.sidebarWidth, height: FindBar.height
        )
        recomputeFrames()
        setNeedsDisplay()
    }

    // MARK: - Filtrar

    /// Cmd+F: filtra la carpeta por nombre mientras se escribe.
    func showFind() {
        if !isFinding {
            isFinding = true
            findBar.reset()
            if findBar.superview == nil {
                addSubview(findBar)
                findBar.placeholder = "Filtrar por nombre"
                findBar.onChange = { [weak self] text in self?.applyFilter(text) }
                findBar.onNext = { [weak self] in self?.move(by: 1) }
                findBar.onPrevious = { [weak self] in self?.move(by: -1) }
                findBar.onClose = { [weak self] in self?.hideFind() }
            }
        }
        setNeedsLayout()
    }

    private func hideFind() {
        isFinding = false
        applyFilter("")
        setNeedsLayout()
    }

    private func applyFilter(_ text: String) {
        filter = text
        items = filtered(allItems)
        selectOnly(items.isEmpty ? nil : 0)
        scrollOffset = 0
        findBar.status = text.isEmpty ? nil : (items.count == 1 ? "1 elemento" : "\(items.count) elementos")
        recomputeFrames()
        setNeedsDisplay()
    }

    private func filtered(_ list: [FileItem]) -> [FileItem] {
        guard !filter.isEmpty else { return list }
        return list.filter { $0.name.localizedStandardContains(filter) }
    }

    private func recomputeFrames() {
        sidebarFrames = services.files.providers.indices.map { index in
            CGRect(
                x: 6, y: 62 + CGFloat(index) * 28,
                width: Self.sidebarWidth - 12, height: 26
            )
        }

        let listX = Self.sidebarWidth
        let listWidth = bounds.width - listX
        upFrame = CGRect(x: listX + 6, y: (Self.headerHeight - 24) / 2, width: 24, height: 24)
        // «Nombre» ya no va en la cabecera: ahí va el nombre de la carpeta,
        // que es lo que se busca al mirar arriba. Se ordena por nombre al
        // volver a pulsar Tamaño o Fecha cuando ya están elegidos.
        sortFrames = [
            .size: CGRect(x: bounds.width - Self.sizeColumnInset, y: (Self.headerHeight - 18) / 2, width: 70, height: 18),
            .date: CGRect(x: bounds.width - Self.dateColumnInset, y: (Self.headerHeight - 18) / 2, width: 110, height: 18),
        ]

        settingsFrame = CGRect(x: bounds.width - 32, y: (Self.headerHeight - 24) / 2, width: 26, height: 24)
        modeFrames = [:]
        for (index, mode) in ViewMode.allCases.enumerated() {
            modeFrames[mode] = CGRect(
                x: bounds.width - 118 + CGFloat(index) * 27,
                y: (Self.headerHeight - 24) / 2, width: 24, height: 24
            )
        }

        switch mode {
        case .list:
            columns = 1
            rowFrames = items.indices.map { index in
                CGRect(
                    x: listX,
                    y: Self.headerHeight + CGFloat(index) * Self.rowHeight - scrollOffset,
                    width: listWidth,
                    height: Self.rowHeight
                )
            }

        case .smallIcons, .largeIcons:
            // Las casillas se estiran lo justo para llenar el ancho: con un
            // ancho fijo quedaría un hueco a la derecha que cambia al
            // redimensionar el panel y parece un error.
            let padding = Self.gridPadding
            let available = max(1, listWidth - 2 * padding)
            let cell = mode.cellSize
            columns = max(1, Int(available / cell.width))
            let width = available / CGFloat(columns)
            rowFrames = items.indices.map { index in
                CGRect(
                    x: listX + padding + CGFloat(index % columns) * width,
                    y: Self.headerHeight + padding
                        + CGFloat(index / columns) * cell.height - scrollOffset,
                    width: width,
                    height: cell.height
                )
            }
        }
    }

    /// Alto de todo el contenido, para saber hasta dónde se puede bajar.
    private var contentHeight: CGFloat {
        switch mode {
        case .list:
            CGFloat(items.count) * Self.rowHeight
        case .smallIcons, .largeIcons:
            CGFloat((items.count + columns - 1) / columns) * mode.cellSize.height
                + 2 * Self.gridPadding
        }
    }

    private func setMode(_ newMode: ViewMode) {
        guard newMode != mode else { return }
        mode = newMode
        scrollOffset = 0
        recomputeFrames()
        if let selectedIndex { reveal(selectedIndex) }
        setNeedsLayout()
        setNeedsDisplay()
    }

    // MARK: - Dibujo

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawSidebar(in: context)
        drawHeader(in: context)
        drawRows(in: context)
        drawDropHighlight(in: context)
        drawCopyProgress(in: context)
    }

    private func drawSidebar(in context: CGContext) {
        context.setFillColor(Tokens.Color.panelElevated.desktopCGColor)
        context.fill(CGRect(x: 0, y: 0, width: Self.sidebarWidth, height: bounds.height))
        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.fill(CGRect(x: Self.sidebarWidth - 1, y: 0, width: 1, height: bounds.height))

        WindowControls.draw(in: context, x: Self.controlsX, midY: Self.controlsMidY,
                            hovering: hoveringControls, scale: layer.contentsScale)

        ("UBICACIONES" as NSString).draw(
            at: CGPoint(x: 12, y: 44),
            withAttributes: [
                .font: Tokens.sans(10, weight: .semibold),
                .foregroundColor: Tokens.Color.textSecondary,
            ]
        )

        for (index, provider) in services.files.providers.enumerated() {
            guard index < sidebarFrames.count else { break }
            let frame = sidebarFrames[index]
            let isActive = FileService.key(of: provider) == locationKey
            // Un servidor de red desmontado, o un USB desenchufado, se queda
            // en la lista **apagado**: sigue ahí, pero se ve que no responde.
            // Desaparecer sin más parecía que la ubicación no se hubiera
            // añadido nunca.
            let isOffline = (provider as? ExternalFolderProvider)?.isAvailable == false

            if isActive {
                context.setFillColor(Tokens.Color.accent.withAlphaComponent(0.2).desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
                context.fillPath()
            }

            let tint = isActive ? Tokens.Color.accent : Tokens.Color.textSecondary
            drawSymbol(
                provider.symbol,
                in: CGRect(x: frame.minX + 6, y: frame.midY - 8, width: 16, height: 16),
                color: isOffline ? tint.withAlphaComponent(0.45) : tint
            )
            let label = isActive ? Tokens.Color.text : Tokens.Color.textSecondary
            (provider.name as NSString).draw(
                at: CGPoint(x: frame.minX + 28, y: frame.midY - 8),
                withAttributes: [
                    .font: Tokens.sans(13),
                    .foregroundColor: isOffline ? label.withAlphaComponent(0.45) : label,
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

        let canGoUp = provider.parent(of: path) != nil
        drawSymbol("chevron.left", in: upFrame,
                   color: canGoUp ? Tokens.Color.text : Tokens.Color.textSecondary.withAlphaComponent(0.35))
        drawSymbol("gearshape", in: settingsFrame, color: Tokens.Color.text.withAlphaComponent(0.72), pointSize: 13.5)

        for (mode, frame) in modeFrames {
            let isActive = mode == self.mode
            if isActive {
                context.setFillColor(Tokens.Color.accent.withAlphaComponent(0.2).desktopCGColor)
                context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 5).cgPath)
                context.fillPath()
            }
            drawSymbol(
                mode.symbol,
                in: frame,
                color: isActive ? Tokens.Color.accent : Tokens.Color.textSecondary
            )
        }

        // El nombre de la carpeta, como la barra de título del Finder.
        let folder = path == provider.rootPath
            ? provider.name
            : (path as NSString).lastPathComponent
        (folder as NSString).draw(
            in: CGRect(
                x: upFrame.maxX + 8, y: (Self.headerHeight - 20) / 2,
                width: max(0, bounds.width - Self.sizeColumnInset - upFrame.maxX - 20), height: 20
            ),
            withAttributes: [
                .font: Tokens.sans(14, weight: .semibold),
                .foregroundColor: Tokens.Color.text,
                .paragraphStyle: {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.lineBreakMode = .byTruncatingMiddle
                    return paragraph
                }(),
            ]
        )

        for (kind, frame) in sortFrames {
            let isActive = kind == sort
            (kind.label as NSString).draw(
                at: CGPoint(x: frame.minX, y: frame.minY),
                withAttributes: [
                    .font: Tokens.sans(12, weight: isActive ? .semibold : .regular),
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

        if mode != .list {
            drawGrid(in: context)
            return
        }

        for (index, item) in items.enumerated() {
            guard index < rowFrames.count else { break }
            let frame = rowFrames[index]
            // Sólo se dibuja lo que se ve: una carpeta con mil ficheros no
            // tiene por qué costar mil dibujados.
            guard frame.maxY > Self.headerHeight, frame.minY < bounds.height else { continue }

            if selection.contains(index) {
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
                    width: max(0, bounds.width - frame.minX - Self.sizeColumnInset - 40),
                    height: 16
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
                at: CGPoint(x: bounds.width - Self.sizeColumnInset, y: frame.midY - 6),
                withAttributes: meta
            )
            (item.modifiedLabel as NSString).draw(
                at: CGPoint(x: bounds.width - Self.dateColumnInset, y: frame.midY - 6),
                withAttributes: meta
            )
        }
    }

    /// Las vistas de iconos: icono o miniatura arriba y el nombre debajo, en
    /// dos líneas como mucho.
    private func drawGrid(in context: CGContext) {
        let side = mode.iconSide
        let fontSize: CGFloat = mode == .largeIcons ? 12 : 11

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle

        // Lo de debajo de la cabecera se recorta: al hacer scroll, una casilla
        // a medias no puede pintarse encima de los rótulos de ordenar.
        context.saveGState()
        context.clip(to: CGRect(
            x: Self.sidebarWidth, y: Self.headerHeight,
            width: bounds.width - Self.sidebarWidth,
            height: bounds.height - Self.headerHeight
        ))
        defer { context.restoreGState() }

        for (index, item) in items.enumerated() {
            guard index < rowFrames.count else { break }
            let frame = rowFrames[index]
            guard frame.maxY > Self.headerHeight, frame.minY < bounds.height else { continue }

            let iconFrame = CGRect(
                x: frame.midX - side / 2, y: frame.minY + 6,
                width: side, height: side
            )
            let labelFrame = CGRect(
                x: frame.minX + 6, y: iconFrame.maxY + 6,
                width: frame.width - 12, height: frame.maxY - iconFrame.maxY - 10
            )

            // El resalte abraza icono y nombre, no la casilla entera: así se
            // distingue qué está seleccionado aunque las casillas se toquen.
            let isSelected = selection.contains(index)
            if isSelected || index == hoveredIndex {
                let color = isSelected
                    ? Tokens.Color.accent.withAlphaComponent(0.22)
                    : Tokens.Color.text.withAlphaComponent(0.06)
                context.setFillColor(color.desktopCGColor)
                context.addPath(UIBezierPath(
                    roundedRect: frame.insetBy(dx: 4, dy: 2),
                    cornerRadius: 8
                ).cgPath)
                context.fillPath()
            }

            if let thumbnail = thumbnail(for: item) {
                let fitted = aspectFit(thumbnail.size, in: iconFrame)
                context.saveGState()
                UIBezierPath(roundedRect: fitted, cornerRadius: 4).addClip()
                thumbnail.draw(in: fitted)
                context.restoreGState()
            } else {
                drawSymbol(
                    symbol(for: item),
                    in: iconFrame,
                    color: item.isDirectory ? Tokens.Color.accent : Tokens.Color.textSecondary,
                    pointSize: side * 0.62
                )
            }

            (item.name as NSString).draw(
                with: labelFrame,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: Tokens.sans(fontSize),
                    .foregroundColor: Tokens.Color.text,
                    .paragraphStyle: paragraph,
                ],
                context: nil
            )
        }
    }

    private func aspectFit(_ size: CGSize, in frame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return frame }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: frame.midX - fitted.width / 2,
            y: frame.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// La miniatura, si ya está; si no, la pide y de momento va el icono.
    ///
    /// Sólo para ficheros locales, y a un tamaño fijo en píxeles: decodificar
    /// una foto de 48 megapíxeles para enseñarla a 84 puntos se come la memoria
    /// en cuanto hay unas cuantas en la carpeta.
    private func thumbnail(for item: FileItem) -> UIImage? {
        guard item.kind == .image, provider is LocalProvider else { return nil }
        if let image = thumbnails[item.path] { return image }
        guard !pendingThumbnails.contains(item.path) else { return nil }
        pendingThumbnails.insert(item.path)

        let path = item.path
        let side = ViewMode.largeIcons.iconSide * 3
        Task { [weak self] in
            let image = await UIImage(contentsOfFile: path)?
                .byPreparingThumbnail(ofSize: CGSize(width: side, height: side))
            guard let self, let image, self.pendingThumbnails.contains(path) else { return }
            self.thumbnails[path] = image
            self.scheduleThumbnailRedraw()
        }
        return nil
    }

    /// Una carpeta de fotos trae decenas de miniaturas casi a la vez: se
    /// repinta el panel una vez por tanda, no una por foto.
    private var thumbnailRedrawPending = false

    private func scheduleThumbnailRedraw() {
        guard !thumbnailRedrawPending else { return }
        thumbnailRedrawPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.thumbnailRedrawPending = false
            self.setNeedsDisplay()
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

    private func drawSymbol(
        _ name: String,
        in frame: CGRect,
        color: UIColor,
        pointSize: CGFloat = 12
    ) {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let image = UIImage.crispSymbol(name, configuration: configuration, scale: layer.contentsScale)?
            .withTintColor(
                color.resolvedColor(with: UITraitCollection(userInterfaceStyle: DesktopTheme.style)),
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
        if copyProgress != nil, cancelCopyFrame.contains(event.location) {
            if case .down = event.kind { pasteTask?.cancel() }
            return
        }
        if isFinding, findBar.frame.contains(event.location) {
            findBar.handlePointer(event.kind, at: CGPoint(
                x: event.location.x - findBar.frame.minX, y: event.location.y - findBar.frame.minY
            ))
            return
        }
        switch event.kind {
        case .moved:
            if let press, hypot(event.location.x - press.location.x, event.location.y - press.location.y) > 6,
               items.indices.contains(press.index) {
                self.press = nil
                lastClick = nil
                // Se arrastra todo lo seleccionado si se agarró por uno de
                // ellos; si no, sólo ése, como en el Finder.
                if !selection.contains(press.index) { selectOnly(press.index) }
                AppServices.shared.desktopViewController?.beginFileDrag(
                    selectedItems,
                    from: provider,
                    source: self
                )
                return
            }
            let inControls = WindowControls.groupContains(event.location, x: Self.controlsX, midY: Self.controlsMidY)
            if inControls != hoveringControls {
                hoveringControls = inControls
                setNeedsDisplay()
            }
            let index = itemIndex(at: event.location)
            if hoveredIndex != index {
                hoveredIndex = index
                setNeedsDisplay()
            }

        case .down:
            if let button = WindowControls.button(at: event.location, x: Self.controlsX, midY: Self.controlsMidY) {
                WindowControls.perform(button, on: self)
                return
            }
            if let index = sidebarFrames.firstIndex(where: { $0.contains(event.location) }) {
                showProvider(at: index)
                return
            }
            if settingsFrame.contains(event.location) {
                services.desktopViewController?.presentSettings(.files)
                return
            }
            for (mode, frame) in modeFrames where frame.contains(event.location) {
                setMode(mode)
                return
            }
            for (kind, frame) in sortFrames where frame.insetBy(dx: -6, dy: -6).contains(event.location) {
                sort = sort == kind ? .name : kind
                allItems = sorted(allItems)
                items = filtered(allItems)
                setNeedsDisplay()
                return
            }
            if let index = itemIndex(at: event.location) {
                // Doble clic: dos clics sobre el mismo elemento, seguidos y sin
                // apenas mover el ratón. El margen de tiempo es algo más
                // generoso que el de macOS porque los clics pasan por
                // AssistiveTouch y pueden llegar con un poco de retraso.
                let now = Date()
                let isDouble = lastClick.map {
                    $0.index == index
                        && now.timeIntervalSince($0.time) < Self.doubleClickInterval
                        && hypot($0.location.x - event.location.x, $0.location.y - event.location.y) < 6
                } ?? false

                if isDouble, items.indices.contains(index), event.modifiers.isDisjoint(with: [.command, .shift]) {
                    lastClick = nil
                    open(items[index])
                    return
                }
                lastClick = (index, now, event.location)
                if event.modifiers.contains(.command) {
                    // Cmd+clic: añade o quita uno, sin tocar los demás.
                    if selection.contains(index) {
                        selection.remove(index)
                        selectedIndex = selection.isEmpty ? nil : index
                    } else {
                        selection.insert(index)
                        selectedIndex = index
                    }
                } else if event.modifiers.contains(.shift), let anchor = selectedIndex {
                    // Mayús+clic: todo lo que hay entre el último y éste.
                    selection = Set(min(anchor, index)...max(anchor, index))
                } else {
                    // Un clic sobre algo ya seleccionado no suelta lo demás
                    // hasta ver si es un arrastre: si no, no se podría
                    // arrastrar más de uno.
                    if !selection.contains(index) { selectOnly(index) }
                    press = (index, event.location)
                    pendingSingleSelect = index
                }
                setNeedsDisplay()
                AppServices.shared.desktop.notifyTitleChange()
            } else if upFrame.contains(event.location) {
                goUp()
            } else if event.location.x >= Self.sidebarWidth, event.location.y > Self.headerHeight,
                      event.modifiers.isDisjoint(with: [.command, .shift]) {
                // Un clic en el hueco suelta la selección, como en el Finder.
                selectOnly(nil)
                setNeedsDisplay()
            }

        case .scroll(let delta):
            scroll(by: -delta.dy)

        case .up:
            // Clic sin arrastre sobre algo de una selección de varios: ahora
            // sí se queda sólo ése.
            if press != nil, let index = pendingSingleSelect, selection.count > 1 {
                selectOnly(index)
                setNeedsDisplay()
            }
            press = nil
            pendingSingleSelect = nil
        }
    }

    // MARK: - Selección

    /// Un clic sobre algo que ya estaba en una selección de varios: al
    /// soltar sin arrastrar, se queda sólo ése.
    private var pendingSingleSelect: Int?

    /// Deja seleccionado sólo uno, o nada.
    private func selectOnly(_ index: Int?) {
        selectedIndex = index
        selection = index.map { [$0] } ?? []
    }

    /// Lo seleccionado, en el orden de la carpeta.
    private var selectedItems: [FileItem] {
        selection.sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// Cmd+A.
    private func selectAll() {
        guard !items.isEmpty else { return }
        selection = Set(items.indices)
        if selectedIndex == nil { selectedIndex = 0 }
        setNeedsDisplay()
    }

    /// Cmd+C y el menú: lo seleccionado, al portapapeles de Ficheros.
    func copySelection() {
        services.files.copy(selectedItems, from: provider)
    }

    /// Cmd+X.
    func cutSelection() {
        services.files.cut(selectedItems, from: provider)
    }

    /// Cmd+V: lo copiado o cortado, a la carpeta que se ve.
    func pasteHere() {
        paste()
    }

    /// La cabecera vacía y la franja de arriba de la barra lateral, donde van
    /// los botones de ventana.
    func isDragArea(_ point: CGPoint) -> Bool {
        let buttons = [upFrame, settingsFrame] + Array(sortFrames.values) + Array(modeFrames.values)
        if buttons.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) { return false }
        if WindowControls.button(at: point, x: Self.controlsX, midY: Self.controlsMidY) != nil { return false }
        if point.x >= Self.sidebarWidth { return point.y < Self.headerHeight }
        return point.y < 28
    }

    /// El elemento bajo un punto. Lo que el scroll ha metido debajo de la
    /// cabecera no cuenta: ahí se está pulsando la cabecera.
    private func itemIndex(at point: CGPoint) -> Int? {
        guard point.y > Self.headerHeight else { return nil }
        return rowFrames.firstIndex { $0.contains(point) }
    }

    /// Menú del clic derecho.
    func contextMenuEntries(at location: CGPoint) -> [ContextMenu.Entry] {
        if location.x < Self.sidebarWidth {
            return sidebarMenuEntries(at: location)
        }
        let index = itemIndex(at: location)
        // Sobre algo de la selección, el menú es para toda la selección; sobre
        // otra cosa, se queda sólo ésa, como en el Finder.
        if let index, !selection.contains(index) { selectOnly(index) }
        if index != nil { setNeedsDisplay() }
        let item = index.flatMap { items.indices.contains($0) ? items[$0] : nil }
        let files = services.files
        let provider = self.provider
        let chosen = selectedItems

        var entries: [ContextMenu.Entry] = []

        if item != nil, chosen.count > 1 {
            let count = chosen.count
            entries.append(ContextMenu.Entry(title: "Copiar \(count) elementos", symbol: "doc.on.doc") {
                files.copy(chosen, from: provider)
            })
            entries.append(ContextMenu.Entry(title: "Cortar \(count) elementos", symbol: "scissors") {
                files.cut(chosen, from: provider)
            })
            entries.append(ContextMenu.Entry(
                title: "Borrar \(count) elementos",
                symbol: "trash",
                isDestructive: true
            ) { [weak self] in
                self?.confirmDelete(chosen)
            })
        } else if let item {
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
                if item.kind == .image {
                    entries.append(ContextMenu.Entry(
                        title: "Usar como fondo de escritorio",
                        symbol: "photo.on.rectangle"
                    ) { [weak self] in
                        self?.useAsWallpaper(item)
                    })
                }
            } else {
                entries.append(ContextMenu.Entry(title: "Abrir", symbol: "folder") { [weak self] in
                    self?.open(item)
                })
            }
            entries.append(ContextMenu.Entry(title: "Copiar", symbol: "doc.on.doc") {
                files.copy([item], from: provider)
            })
            entries.append(ContextMenu.Entry(title: "Cortar", symbol: "scissors") {
                files.cut([item], from: provider)
            })
            entries.append(ContextMenu.Entry(title: "Renombrar", symbol: "pencil") { [weak self] in
                self?.startRename(item)
            })
            entries.append(ContextMenu.Entry(
                title: "Borrar",
                symbol: "trash",
                isDestructive: true
            ) { [weak self] in
                self?.confirmDelete([item])
            })
        }

        let pasteCount = files.clipboard?.items.count ?? 0
        entries.append(ContextMenu.Entry(
            title: pasteCount > 1 ? "Pegar \(pasteCount) elementos" : "Pegar",
            symbol: "doc.on.clipboard",
            isEnabled: files.clipboard != nil
        ) { [weak self] in
            self?.paste()
        })
        entries.append(ContextMenu.Entry(title: "Nueva carpeta", symbol: "folder.badge.plus") { [weak self] in
            self?.createFolder()
        })
        if item == nil, !items.isEmpty {
            entries.append(ContextMenu.Entry(title: "Seleccionar todo", symbol: "checkmark.circle") {
                [weak self] in self?.selectAll()
            })
        }
        for kind in [Sort.name, .size, .date] where kind != sort {
            entries.append(ContextMenu.Entry(
                title: "Ordenar por \(kind.label.lowercased())",
                symbol: "arrow.up.arrow.down"
            ) { [weak self] in
                guard let self else { return }
                self.sort = kind
                self.allItems = self.sorted(self.allItems)
                self.items = self.filtered(self.allItems)
                self.setNeedsLayout()
                self.setNeedsDisplay()
            })
        }
        for mode in ViewMode.allCases where mode != self.mode {
            entries.append(ContextMenu.Entry(
                title: "Ver como \(mode.label.lowercased())",
                symbol: mode.symbol
            ) { [weak self] in
                self?.setMode(mode)
            })
        }
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

    /// Botón derecho sobre una ubicación de la barra lateral: quitarla, que
    /// antes sólo se podía desde Ajustes y las que ya no respondían se
    /// quedaban para siempre.
    private func sidebarMenuEntries(at location: CGPoint) -> [ContextMenu.Entry] {
        let files = services.files
        var entries: [ContextMenu.Entry] = []

        if let index = sidebarFrames.firstIndex(where: { $0.contains(location) }),
           files.providers.indices.contains(index) {
            let provider = files.providers[index]
            entries.append(ContextMenu.Entry(title: "Abrir", symbol: "folder") { [weak self] in
                self?.showProvider(at: index)
            })
            if let smb = provider as? SMBProvider {
                entries.append(ContextMenu.Entry(title: "Editar servidor…", symbol: "pencil") { [weak self] in
                    self?.services.desktopViewController?.presentSMBEditor(for: smb.server)
                })
            }
            if files.canRemove(provider) {
                let title = switch provider {
                case is SFTPProvider: "Quitar de Ficheros"
                case is SMBProvider: "Borrar servidor"
                default: "Quitar de la barra lateral"
                }
                entries.append(ContextMenu.Entry(title: title, symbol: "minus.circle", isDestructive: true) {
                    [weak self] in self?.removeLocation(provider)
                })
            }
        }

        if !files.unavailableFolders.isEmpty {
            entries.append(ContextMenu.Entry(
                title: "Quitar las que no responden",
                symbol: "xmark.circle",
                isDestructive: true
            ) { [weak self] in
                guard let self else { return }
                let before = self.provider
                self.services.files.removeUnavailable()
                self.afterLocationsChanged(previous: before)
            })
        }
        entries.append(ContextMenu.Entry(title: "Añadir ubicación…", symbol: "folder.badge.plus") {
            NotificationCenter.default.post(name: .brunosPickFolder, object: nil)
        })
        return entries
    }

    private func removeLocation(_ provider: any FileProvider) {
        let before = self.provider
        services.files.remove(provider)
        afterLocationsChanged(previous: before)
    }

    /// Si la ubicación que se estaba viendo ya no está, se vuelve al iPhone.
    private func afterLocationsChanged(previous: any FileProvider) {
        if services.files.provider(forKey: locationKey) == nil {
            showProvider(at: 0)
        }
        setNeedsLayout()
        setNeedsDisplay()
        services.desktop.notifyTitleChange()
    }

    // MARK: - Operaciones

    private func openInBrowser(_ item: FileItem) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.provider.localURL(for: item)
                self.services.desktopViewController?.openInBrowser(url)
            } catch {
                self.show(error)
            }
        }
    }

    /// Pone la imagen de fondo. Vale de cualquier origen: se descarga si hace
    /// falta y se copia a la carpeta de la app.
    private func useAsWallpaper(_ item: FileItem) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.provider.localURL(for: item)
                try self.services.wallpaper.setCustomImage(from: url)
            } catch {
                self.show(error)
            }
        }
    }

    private func paste() {
        guard pasteTask == nil else { return }
        copyProgress = FileService.Progress()
        setNeedsDisplay()
        pasteTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.services.files.paste(into: self.path, of: self.provider) { [weak self] progress in
                    self?.copyProgress = progress
                    self?.setNeedsDisplay()
                }
                self.finishPaste()
                self.reload()
                // Lo cortado ya no está en la ventana de donde salió.
                AppServices.shared.desktopViewController?.refreshFilesPanes()
            } catch is CancellationError {
                self.finishPaste()
                self.status = "Copia cancelada. Lo que ya se había copiado se queda."
                self.reload()
            } catch {
                self.finishPaste()
                self.show(error)
            }
        }
    }

    private func finishPaste() {
        pasteTask = nil
        copyProgress = nil
        setNeedsDisplay()
    }

    /// La barra de progreso de una copia, abajo de la lista, con su botón de
    /// cancelar.
    private func drawCopyProgress(in context: CGContext) {
        guard let progress = copyProgress else {
            cancelCopyFrame = .zero
            return
        }
        let panel = CGRect(
            x: Self.sidebarWidth + 10, y: bounds.height - 62,
            width: bounds.width - Self.sidebarWidth - 20, height: 52
        )
        context.setFillColor(Tokens.Color.panelElevated.desktopCGColor)
        context.addPath(UIBezierPath(roundedRect: panel, cornerRadius: 10).cgPath)
        context.fillPath()
        context.setStrokeColor(Tokens.Color.border.desktopCGColor)
        context.setLineWidth(1)
        context.addPath(UIBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10).cgPath)
        context.strokePath()

        let bytes: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let detail = progress.filesTotal == 0
            ? progress.current
            : progress.bytesTotal == 0
                ? "\(progress.filesDone) de \(progress.filesTotal)"
                : "\(progress.filesDone) de \(progress.filesTotal) · \(bytes(progress.bytesDone)) de \(bytes(progress.bytesTotal))"
        let verb = progress.isMove ? "Moviendo" : "Copiando"
        ("\(verb) \(progress.current.isEmpty ? "" : "«\(progress.current)»")" as NSString).draw(
            in: CGRect(x: panel.minX + 14, y: panel.minY + 8, width: panel.width - 130, height: 16),
            withAttributes: [.font: Tokens.sans(12, weight: .medium), .foregroundColor: Tokens.Color.text]
        )
        (detail as NSString).draw(
            at: CGPoint(x: panel.minX + 14, y: panel.minY + 26),
            withAttributes: [.font: Tokens.mono(10.5), .foregroundColor: Tokens.Color.textSecondary]
        )

        let track = CGRect(x: panel.minX + 14, y: panel.maxY - 9, width: panel.width - 124, height: 4)
        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.addPath(UIBezierPath(roundedRect: track, cornerRadius: 2).cgPath)
        context.fillPath()
        var filled = track
        filled.size.width = max(4, track.width * progress.fraction)
        context.setFillColor(Tokens.Color.accent.desktopCGColor)
        context.addPath(UIBezierPath(roundedRect: filled, cornerRadius: 2).cgPath)
        context.fillPath()

        cancelCopyFrame = CGRect(x: panel.maxX - 96, y: panel.midY - 13, width: 84, height: 26)
        context.setStrokeColor(Tokens.Color.border.desktopCGColor)
        context.addPath(UIBezierPath(roundedRect: cancelCopyFrame, cornerRadius: 7).cgPath)
        context.strokePath()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(12, weight: .medium), .foregroundColor: Tokens.Color.text,
        ]
        let size = ("Cancelar" as NSString).size(withAttributes: attributes)
        ("Cancelar" as NSString).draw(
            at: CGPoint(x: cancelCopyFrame.midX - size.width / 2, y: cancelCopyFrame.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func startRename(_ item: FileItem) {
        services.desktopViewController?.presentPrompt(
            title: "Renombrar",
            value: item.name
        ) { [weak self] newName in
            guard let self, let newName, newName != item.name else { return }
            Task {
                do {
                    try await self.provider.rename(item.path, to: newName)
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
                    try await self.provider.createDirectory(path)
                    self.reload()
                } catch {
                    self.show(error)
                }
            }
        }
    }

    /// Borrar **siempre pregunta**: no hay papelera de donde recuperarlo.
    private func confirmDelete(_ targets: [FileItem]) {
        guard let first = targets.first else { return }
        let provider = self.provider
        services.desktopViewController?.presentConfirm(
            title: targets.count == 1 ? "¿Borrar \(first.name)?" : "¿Borrar \(targets.count) elementos?",
            message: "No se puede deshacer: BrunOS no tiene papelera.",
            destructive: "Borrar"
        ) { [weak self] confirmed in
            guard let self, confirmed else { return }
            Task {
                do {
                    for item in targets {
                        try await self.services.files.deleteRecursively(item, from: provider)
                    }
                    self.reload()
                } catch {
                    self.show(error)
                    self.reload()
                }
            }
        }
    }

    private func show(_ error: any Error) {
        status = error.localizedDescription
        setNeedsDisplay()
    }

    private func scroll(by amount: CGFloat) {
        let total = contentHeight
        let visible = bounds.height - Self.headerHeight
        guard total > visible else { return }
        scrollOffset = min(max(scrollOffset + amount, 0), total - visible)
        setNeedsLayout()
        setNeedsDisplay()
    }

    func handleKey(_ event: KeyEvent) {
        guard event.phase == .down else { return }

        // Con el filtro abierto, las letras van a él; las flechas y la
        // espaciadora siguen moviéndose por la lista, como en el Finder.
        if isFinding {
            switch event.key.keyCode {
            case .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow:
                break
            case .keyboardReturnOrEnter where !items.isEmpty:
                break
            default:
                findBar.handleKey(event)
                return
            }
        }

        let flags = event.key.modifierFlags
        // Los de Cmd que no son del escritorio llegan aquí: Cmd+A, Cmd+X y
        // Cmd+⌫, como en el Finder. Cmd+C y Cmd+V pasan por `perform`.
        if flags.contains(.command) {
            switch event.key.keyCode {
            case .keyboardA: selectAll()
            case .keyboardX: cutSelection()
            case .keyboardDeleteOrBackspace: confirmDelete(selectedItems)
            default: break
            }
            return
        }
        let extend = flags.contains(.shift)

        switch event.key.keyCode {
        case .keyboardUpArrow:
            move(by: -columns, extending: extend)
        case .keyboardDownArrow:
            move(by: columns, extending: extend)
        case .keyboardLeftArrow where mode != .list:
            move(by: -1, extending: extend)
        case .keyboardRightArrow where mode != .list:
            move(by: 1, extending: extend)
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

    /// Con Mayús, la selección crece hasta donde se llega, como en el Finder.
    private func move(by delta: Int, extending: Bool = false) {
        guard !items.isEmpty else { return }
        let next = min(max((selectedIndex ?? 0) + delta, 0), items.count - 1)
        if extending {
            selection.insert(next)
            selectedIndex = next
        } else {
            selectOnly(next)
        }
        reveal(next)
        setNeedsLayout()
        setNeedsDisplay()
        AppServices.shared.desktop.notifyTitleChange()
    }

    /// Que la selección no se vaya fuera de la vista al moverse con flechas.
    private func reveal(_ index: Int) {
        let (top, height): (CGFloat, CGFloat) = switch mode {
        case .list:
            (CGFloat(index) * Self.rowHeight, Self.rowHeight)
        case .smallIcons, .largeIcons:
            (Self.gridPadding + CGFloat(index / columns) * mode.cellSize.height,
             mode.cellSize.height)
        }
        let visible = bounds.height - Self.headerHeight
        if top < scrollOffset {
            scrollOffset = max(0, top - (mode == .list ? 0 : Self.gridPadding))
        } else if top + height > scrollOffset + visible {
            scrollOffset = top + height - visible
        }
    }

    // MARK: - Soltar

    /// Qué hay bajo un punto a efectos de soltar: una carpeta de la lista, una
    /// ubicación de la barra lateral o la carpeta que se está viendo.
    func dropTarget(at point: CGPoint) -> DropTarget? {
        if let index = sidebarFrames.firstIndex(where: { $0.contains(point) }) {
            return .location(index)
        }
        guard point.x >= Self.sidebarWidth, point.y > Self.headerHeight else { return nil }
        if let index = itemIndex(at: point), items.indices.contains(index), items[index].isDirectory {
            return .folder(index)
        }
        return .here
    }

    func highlightDrop(_ target: DropTarget?) {
        guard target != dropHighlight else { return }
        dropHighlight = target
        setNeedsDisplay()
    }

    /// Suelta aquí algo arrastrado desde este panel o desde otro.
    ///
    /// Como en el Finder: **dentro del mismo origen se mueve, entre orígenes
    /// distintos se copia**. Arrastrar del iPhone a una máquina por SFTP no
    /// debería borrar nada del teléfono.
    func drop(_ dropped: [FileItem], from source: any FileProvider, at target: DropTarget) {
        highlightDrop(nil)
        let files = services.files
        let (provider, directory): (any FileProvider, String) = switch target {
        case .location(let index):
            (files.providers[index], files.providers[index].rootPath)
        case .folder(let index):
            (self.provider, items[index].path)
        case .here:
            (self.provider, path)
        }
        let move = source === provider
        // Soltarlo donde ya estaba no hace nada. Ni sobre sí mismo: una
        // carpeta de la selección soltada encima de ella.
        let moving = dropped.filter { item in
            !(move && ((item.path as NSString).deletingLastPathComponent == directory || item.path == directory))
        }
        guard !moving.isEmpty else { return }
        runTransfer(moving, from: source, to: provider, into: directory, move: move)
    }

    private func runTransfer(
        _ moving: [FileItem],
        from source: any FileProvider,
        to target: any FileProvider,
        into directory: String,
        move: Bool
    ) {
        guard pasteTask == nil else { return }
        copyProgress = FileService.Progress()
        setNeedsDisplay()
        pasteTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.services.files.transfer(
                    moving, from: source, to: target, into: directory, move: move
                ) { [weak self] progress in
                    self?.copyProgress = progress
                    self?.setNeedsDisplay()
                }
                self.finishPaste()
                self.reload()
                AppServices.shared.desktopViewController?.refreshFilesPanes()
            } catch is CancellationError {
                self.finishPaste()
                self.status = "Copia cancelada. Lo que ya se había copiado se queda."
                self.reload()
            } catch {
                self.finishPaste()
                self.show(error)
            }
        }
    }

    private func drawDropHighlight(in context: CGContext) {
        let frame: CGRect? = switch dropHighlight {
        case .folder(let index): rowFrames.indices.contains(index) ? rowFrames[index].insetBy(dx: 3, dy: 1) : nil
        case .location(let index): sidebarFrames.indices.contains(index) ? sidebarFrames[index] : nil
        case .here: CGRect(
            x: Self.sidebarWidth + 3, y: Self.headerHeight + 3,
            width: bounds.width - Self.sidebarWidth - 6, height: bounds.height - Self.headerHeight - 6
        )
        case nil: nil
        }
        guard let frame else { return }
        context.setFillColor(Tokens.Color.accent.withAlphaComponent(0.12).desktopCGColor)
        context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 7).cgPath)
        context.fillPath()
        context.setStrokeColor(Tokens.Color.accent.desktopCGColor)
        context.setLineWidth(2)
        context.addPath(UIBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), cornerRadius: 7).cgPath)
        context.strokePath()
    }

    /// Enseña la raíz de un origen. Lo usa el lanzador.
    func showProvider(at index: Int) {
        guard services.files.providers.indices.contains(index) else { return }
        // También queda como la última elegida: ahí abrirá la próxima ventana.
        services.files.select(index)
        let provider = services.files.providers[index]
        locationKey = FileService.key(of: provider)
        path = provider.rootPath
        reload()
        setNeedsDisplay()
    }

    /// El dictado o pegar, con el filtro abierto, van a él.
    func insertText(_ text: String) {
        guard isFinding else { return }
        findBar.insertText(text)
    }

    // MARK: - Sesión

    /// Qué ubicación y qué carpeta se estaban viendo.
    var sessionLocation: (location: String, path: String) {
        (locationKey, path)
    }

    /// Vuelve a la ubicación y la carpeta guardadas. Si la ubicación ya no
    /// está (se quitó), se queda en el iPhone.
    func restore(location: String, path: String) {
        guard services.files.provider(forKey: location) != nil else { return }
        locationKey = location
        self.path = path
        reload()
    }

    /// Enseña una carpeta del iPhone y, si se dice, deja marcado un fichero.
    /// Lo usa el aviso de descarga del navegador.
    func show(localDirectory directory: String, selecting name: String?) {
        guard let local = services.files.providers.first(where: { $0 is LocalProvider }) else { return }
        locationKey = FileService.key(of: local)
        path = directory
        pendingSelection = name
        reload()
    }

    /// Vuelve a leer la carpeta. La usa el escritorio tras borrar o renombrar.
    func refresh() {
        reload()
    }
}

import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Fotos: las imágenes y los vídeos de una carpeta, en rejilla, con visor y
/// reproductor. La quinta app del dock (Cmd+5).
///
/// **Se basa en una carpeta**, de cualquier ubicación de Ficheros: el iPhone,
/// iCloud, un USB, SFTP o SMB. Se navega por sus subcarpetas desde la propia
/// rejilla, se cambia de ubicación desde la cabecera, y desde Ficheros se abre
/// una carpeta con el botón derecho › «Abrir en Fotos».
///
/// Como todo en la pantalla externa, **no recibe eventos del sistema**: la
/// rejilla, la cabecera y los controles del vídeo se dibujan y se resuelven
/// por geometría.
@MainActor
final class PhotosPane: UIView, Pane {

    private static let headerHeight: CGFloat = 36
    private static let controlsX: CGFloat = 13
    private static var controlsMidY: CGFloat { headerHeight / 2 }
    private static let tileSide: CGFloat = 150
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 12
    /// Lo que dura cada foto en el pase de diapositivas.
    private static let slideDuration: TimeInterval = 4

    private let services = AppServices.shared

    /// La ubicación de Ficheros (`FileService.key(of:)`) y la carpeta.
    private var locationKey: String
    private var path: String

    /// Primero las subcarpetas, luego las fotos y los vídeos.
    private var folders: [FileItem] = []
    private var media: [FileItem] = []
    private var status: String?
    private var isLoading = false

    private var selected: Int?
    private var hovered: Int?
    private var hoveringControls = false
    private var scrollOffset: CGFloat = 0
    private var lastClick: (time: Date, index: Int)?

    /// La foto o el vídeo abierto, como índice en `media`. `nil` es la rejilla.
    private var viewerIndex: Int?
    private var isSlideshow = false
    private var slideTimer: Timer?

    // Cabecera.
    private var backFrame: CGRect = .zero
    private var locationFrame: CGRect = .zero
    private var slideshowFrame: CGRect = .zero
    private var gridButtonFrame: CGRect = .zero

    private var provider: any FileProvider {
        services.files.provider(forKey: locationKey) ?? services.files.providers[0]
    }

    var title: String {
        if let viewerIndex, media.indices.contains(viewerIndex) {
            return media[viewerIndex].name
        }
        let provider = self.provider
        return path == provider.rootPath ? provider.name : (path as NSString).lastPathComponent
    }

    var view: UIView { self }

    override init(frame: CGRect) {
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

        viewer.isHidden = true
        addSubview(viewer)

        NotificationCenter.default.addObserver(
            self, selector: #selector(providersChanged), name: FileService.providersDidChange, object: nil
        )
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    isolated deinit {
        slideTimer?.invalidate()
        viewer.stop()
    }

    @objc private func providersChanged() {
        if services.files.provider(forKey: locationKey) == nil {
            let first = services.files.providers[0]
            locationKey = FileService.key(of: first)
            path = first.rootPath
            reload()
        }
        setNeedsDisplay()
    }

    // MARK: - Datos

    private func reload(selecting name: String? = nil, openingViewer: Bool = false, selectingFolder: String? = nil) {
        let provider = self.provider
        let path = self.path
        closeViewer()
        status = nil
        isLoading = true
        folders = []
        media = []
        thumbnails.removeAllObjects()
        pendingThumbnails = []
        queuedThumbnails = []
        setNeedsDisplay()

        Task { [weak self] in
            do {
                let listed = try await provider.list(path)
                guard let self, self.path == path else { return }
                self.folders = listed
                    .filter { $0.isDirectory && !$0.name.hasPrefix(".") }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.media = listed
                    .filter { !$0.isDirectory && Self.isMedia($0) && !$0.name.hasPrefix(".") }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.isLoading = false
                self.scrollOffset = 0
                self.status = self.folders.isEmpty && self.media.isEmpty
                    ? "No hay fotos ni vídeos en esta carpeta."
                    : nil
                let wanted = name.flatMap { name in self.media.firstIndex { $0.name == name } }
                let folder = selectingFolder.flatMap { name in self.folders.firstIndex { $0.name == name } }
                if let wanted, openingViewer {
                    self.openViewer(at: wanted)
                } else if let folder {
                    self.selected = folder
                    self.scrollToSelection()
                } else {
                    self.selected = wanted.map { self.folders.count + $0 }
                        ?? (self.tileCount > 0 ? 0 : nil)
                }
                self.setNeedsDisplay()
                self.services.desktop.notifyTitleChange()
            } catch {
                guard let self else { return }
                self.isLoading = false
                self.status = error.localizedDescription
                self.setNeedsDisplay()
            }
        }
    }

    /// Imágenes y vídeos; el audio suelto no pinta nada en una galería.
    private static func isMedia(_ item: FileItem) -> Bool {
        guard let type = item.type else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    private static func isVideo(_ item: FileItem) -> Bool {
        item.type?.conforms(to: .movie) == true
    }

    private var tileCount: Int { folders.count + media.count }

    private func item(at tile: Int) -> FileItem? {
        if tile < folders.count { return folders[tile] }
        let index = tile - folders.count
        return media.indices.contains(index) ? media[index] : nil
    }

    // MARK: - Navegación

    private func open(tile: Int) {
        guard let item = item(at: tile) else { return }
        if item.isDirectory {
            path = item.path
            reload()
        } else {
            openViewer(at: tile - folders.count)
        }
    }

    private func openSelected() {
        if let selected { open(tile: selected) }
    }

    /// Al subir, queda marcada la carpeta de la que se venía.
    private func goUp() {
        let current = (path as NSString).lastPathComponent
        guard let parent = provider.parent(of: path) else { return }
        path = parent
        reload(selectingFolder: current)
    }

    private func showLocationMenu() {
        let files = services.files
        let entries = files.providers.map { provider in
            let key = FileService.key(of: provider)
            return ContextMenu.Entry(
                title: provider.name,
                symbol: key == locationKey ? "checkmark" : provider.symbol
            ) { [weak self] in
                guard let self else { return }
                self.locationKey = key
                self.path = provider.rootPath
                self.reload()
            }
        }
        let point = convert(CGPoint(x: locationFrame.minX, y: locationFrame.maxY + 4), to: nil)
        services.desktopViewController?.presentContextMenu(entries, at: point)
    }

    /// Abre una carpeta, y si se dice, una foto o un vídeo de ella. Lo usa
    /// «Abrir en Fotos» de Ficheros.
    func show(location: String, path: String, opening name: String? = nil) {
        guard services.files.provider(forKey: location) != nil else { return }
        locationKey = location
        self.path = path
        reload(selecting: name, openingViewer: name != nil)
    }

    // MARK: - Sesión

    var sessionLocation: (location: String, path: String) {
        (locationKey, path)
    }

    func restore(location: String, path: String) {
        guard services.files.provider(forKey: location) != nil else { return }
        locationKey = location
        self.path = path
        reload()
    }

    // MARK: - Rejilla

    private var gridArea: CGRect {
        CGRect(x: 0, y: Self.headerHeight, width: bounds.width, height: max(0, bounds.height - Self.headerHeight))
    }

    /// Columnas y lado de cada cuadro: se estiran para llenar el ancho.
    private var gridMetrics: (columns: Int, side: CGFloat) {
        let width = bounds.width - Self.padding * 2
        let columns = max(1, Int((width + Self.spacing) / (Self.tileSide + Self.spacing)))
        let side = (width - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns)
        return (columns, max(40, side))
    }

    private func tileFrame(_ index: Int) -> CGRect {
        let (columns, side) = gridMetrics
        let row = index / columns
        let column = index % columns
        return CGRect(
            x: Self.padding + CGFloat(column) * (side + Self.spacing),
            y: Self.headerHeight + Self.padding + CGFloat(row) * (side + Self.spacing) - scrollOffset,
            width: side,
            height: side
        )
    }

    private var contentHeight: CGFloat {
        let (columns, side) = gridMetrics
        let rows = (tileCount + columns - 1) / columns
        return Self.padding * 2 + CGFloat(rows) * (side + Self.spacing)
    }

    private func tile(at point: CGPoint) -> Int? {
        guard gridArea.contains(point) else { return nil }
        let (columns, side) = gridMetrics
        let x = point.x - Self.padding
        let y = point.y - Self.headerHeight - Self.padding + scrollOffset
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / (side + Self.spacing))
        let row = Int(y / (side + Self.spacing))
        guard column < columns else { return nil }
        let index = row * columns + column
        return index < tileCount && tileFrame(index).contains(point) ? index : nil
    }

    private func scroll(by delta: CGFloat) {
        let maxOffset = max(0, contentHeight - gridArea.height)
        scrollOffset = min(max(0, scrollOffset - delta), maxOffset)
        setNeedsDisplay()
    }

    private func scrollToSelection() {
        guard let selected else { return }
        let frame = tileFrame(selected)
        if frame.minY < gridArea.minY {
            scrollOffset -= gridArea.minY - frame.minY + Self.padding
        } else if frame.maxY > gridArea.maxY {
            scrollOffset += frame.maxY - gridArea.maxY + Self.padding
        }
        scrollOffset = min(max(0, scrollOffset), max(0, contentHeight - gridArea.height))
    }

    private func moveSelection(by delta: Int) {
        guard tileCount > 0 else { return }
        let current = selected ?? 0
        selected = max(0, min(current + delta, tileCount - 1))
        scrollToSelection()
        setNeedsDisplay()
    }

    // MARK: - Miniaturas

    /// A tamaño fijo en píxeles: decodificar una foto de 48 megapíxeles para
    /// enseñarla en un cuadro de 150 puntos se come la memoria. `NSCache` las
    /// suelta sola si falta.
    private let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 60 * 1024 * 1024
        return cache
    }()
    private var pendingThumbnails: Set<String> = []
    /// Las que esperan turno, las más recientes (las que se ven) primero.
    private var queuedThumbnails: [FileItem] = []
    private var runningThumbnails = 0
    /// Por SFTP o SMB cada miniatura es bajar la foto entera: pocas a la vez.
    private static let maxRunningThumbnails = 3
    /// Lo que no se baja sólo para una miniatura.
    private static let maxThumbnailSource: Int64 = 60 * 1024 * 1024
    private var failedThumbnails: Set<String> = []

    private func thumbnail(for item: FileItem) -> UIImage? {
        if let image = thumbnails.object(forKey: item.path as NSString) { return image }
        guard !pendingThumbnails.contains(item.path), !failedThumbnails.contains(item.path) else { return nil }
        pendingThumbnails.insert(item.path)
        queuedThumbnails.append(item)
        startThumbnails()
        return nil
    }

    private func startThumbnails() {
        while runningThumbnails < Self.maxRunningThumbnails, let item = queuedThumbnails.popLast() {
            // Si ya no se ve (se ha desplazado la rejilla), se deja para
            // cuando vuelva a dibujarse.
            let index = media.firstIndex(of: item).map { folders.count + $0 }
            guard let index, tileFrame(index).intersects(gridArea.insetBy(dx: 0, dy: -300)) else {
                pendingThumbnails.remove(item.path)
                continue
            }
            runningThumbnails += 1
            let provider = self.provider
            let pixels = gridMetrics.side * layer.contentsScale
            Task { [weak self] in
                let image = await Self.makeThumbnail(for: item, from: provider, maxPixels: pixels)
                guard let self else { return }
                self.runningThumbnails -= 1
                self.pendingThumbnails.remove(item.path)
                if let image {
                    let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                    self.thumbnails.setObject(image, forKey: item.path as NSString, cost: cost)
                    self.scheduleRedraw()
                } else {
                    self.failedThumbnails.insert(item.path)
                }
                self.startThumbnails()
            }
        }
    }

    private static func makeThumbnail(
        for item: FileItem,
        from provider: any FileProvider,
        maxPixels: CGFloat
    ) async -> UIImage? {
        if isVideo(item) {
            return await videoThumbnail(for: item, from: provider, maxPixels: maxPixels)
        }
        guard item.size <= maxThumbnailSource,
              let url = try? await provider.localURL(for: item)
        else { return nil }
        return await Task.detached(priority: .utility) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return UIImage(cgImage: image)
        }.value
    }

    /// Un fotograma del principio. En local, del fichero; por SFTP o SMB, por
    /// trozos con `MediaStreamer`, sin bajar el vídeo entero. De iCloud no:
    /// habría que copiarlo entero antes.
    private nonisolated static func videoThumbnail(
        for item: FileItem,
        from provider: any FileProvider,
        maxPixels: CGFloat
    ) async -> UIImage? {
        let asset: AVURLAsset
        var streamer: MediaStreamer?
        if provider is LocalProvider {
            asset = AVURLAsset(url: URL(fileURLWithPath: item.path))
        } else if let remote = provider as? any RangeReadableProvider, item.size > 0 {
            let stream = MediaStreamer(provider: remote, item: item)
            guard let made = stream.makeAsset(fileName: item.name) else { return nil }
            asset = made
            streamer = stream
        } else {
            return nil
        }
        defer { streamer?.cancelAll() }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        guard let result = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else {
            return nil
        }
        return UIImage(cgImage: result.image)
    }

    /// Una carpeta trae decenas de miniaturas casi a la vez: se repinta una
    /// vez por tanda.
    private var redrawPending = false

    private func scheduleRedraw() {
        guard !redrawPending else { return }
        redrawPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.redrawPending = false
            self.setNeedsDisplay()
        }
    }

    // MARK: - Visor

    private let viewer = PhotoViewer()

    private func openViewer(at index: Int) {
        guard media.indices.contains(index) else { return }
        viewerIndex = index
        selected = folders.count + index
        viewer.isHidden = false
        viewer.show(media[index], from: provider, position: "\(index + 1) de \(media.count)")
        viewer.onFinished = { [weak self] in self?.videoFinished() }
        setNeedsLayout()
        setNeedsDisplay()
        services.desktop.notifyTitleChange()
        if isSlideshow { scheduleSlide() }
    }

    private func closeViewer() {
        guard viewerIndex != nil else { return }
        stopSlideshow()
        viewerIndex = nil
        viewer.stop()
        viewer.isHidden = true
        scrollToSelection()
        setNeedsDisplay()
        services.desktop.notifyTitleChange()
    }

    private func step(_ delta: Int) {
        guard let viewerIndex, !media.isEmpty else { return }
        // En el pase da la vuelta; a mano, se para en los extremos.
        let next = isSlideshow
            ? (viewerIndex + delta + media.count) % media.count
            : max(0, min(viewerIndex + delta, media.count - 1))
        guard next != viewerIndex else { return }
        openViewer(at: next)
    }

    // MARK: - Pase de diapositivas

    private func toggleSlideshow() {
        if isSlideshow {
            stopSlideshow()
        } else {
            guard !media.isEmpty else { return }
            isSlideshow = true
            if viewerIndex == nil {
                let start = selected.map { $0 - folders.count }.flatMap { media.indices.contains($0) ? $0 : nil } ?? 0
                openViewer(at: start)
            } else {
                scheduleSlide()
            }
        }
        setNeedsDisplay()
    }

    private func stopSlideshow() {
        isSlideshow = false
        slideTimer?.invalidate()
        slideTimer = nil
        setNeedsDisplay()
    }

    /// Las fotos, 4 segundos; los vídeos, hasta que terminan.
    private func scheduleSlide() {
        slideTimer?.invalidate()
        slideTimer = nil
        guard isSlideshow, let viewerIndex, !Self.isVideo(media[viewerIndex]) else { return }
        slideTimer = Timer.scheduledTimer(withTimeInterval: Self.slideDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.step(1) }
        }
    }

    private func videoFinished() {
        if isSlideshow { step(1) }
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()
        viewer.frame = gridArea
        recomputeHeader()
        setNeedsDisplay()
    }

    private func recomputeHeader() {
        let size: CGFloat = 26
        let y = (Self.headerHeight - size) / 2
        backFrame = CGRect(x: Self.controlsX + WindowControls.width + 10, y: y, width: size, height: size)
        slideshowFrame = CGRect(x: bounds.width - size - 8, y: y, width: size, height: size)
        gridButtonFrame = viewerIndex != nil
            ? CGRect(x: slideshowFrame.minX - size - 2, y: y, width: size, height: size)
            : .zero
        let locationRight = (viewerIndex != nil ? gridButtonFrame.minX : slideshowFrame.minX) - 6
        let name = provider.name as NSString
        let width = min(220, name.size(withAttributes: [.font: Tokens.sans(12)]).width + 34)
        locationFrame = CGRect(x: locationRight - width, y: y, width: width, height: size)
    }

    // MARK: - Dibujo

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        recomputeHeader()

        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.fill(CGRect(x: 0, y: Self.headerHeight - 1, width: bounds.width, height: 1))

        WindowControls.draw(in: context, x: Self.controlsX, midY: Self.controlsMidY,
                            hovering: hoveringControls, scale: layer.contentsScale)

        let canGoBack = viewerIndex != nil || provider.parent(of: path) != nil
        drawSymbol("chevron.left", in: backFrame,
                   color: canGoBack ? Tokens.Color.text : Tokens.Color.textSecondary.withAlphaComponent(0.4),
                   size: 13)

        let titleX = backFrame.maxX + 8
        (title as NSString).draw(
            in: CGRect(x: titleX, y: (Self.headerHeight - 20) / 2,
                       width: max(0, locationFrame.minX - titleX - 8), height: 20),
            withAttributes: [
                .font: Tokens.sans(14, weight: .semibold),
                .foregroundColor: Tokens.Color.text,
                .paragraphStyle: Self.truncating,
            ]
        )

        // La ubicación, como un botón con su icono.
        let pill = UIBezierPath(roundedRect: locationFrame, cornerRadius: 6)
        context.setFillColor(Tokens.Color.panelElevated.desktopCGColor)
        context.addPath(pill.cgPath)
        context.fillPath()
        drawSymbol(provider.symbol, in: CGRect(x: locationFrame.minX + 4, y: locationFrame.minY, width: 20,
                                               height: locationFrame.height),
                   color: Tokens.Color.textSecondary, size: 11)
        (provider.name as NSString).draw(
            in: CGRect(x: locationFrame.minX + 26, y: locationFrame.midY - 8,
                       width: locationFrame.width - 30, height: 16),
            withAttributes: [
                .font: Tokens.sans(12),
                .foregroundColor: Tokens.Color.text,
                .paragraphStyle: Self.truncating,
            ]
        )

        if viewerIndex != nil {
            drawSymbol("square.grid.2x2", in: gridButtonFrame, color: Tokens.Color.text, size: 13)
        }
        drawSymbol(isSlideshow ? "pause.rectangle" : "play.rectangle.on.rectangle", in: slideshowFrame,
                   color: isSlideshow ? Tokens.Color.accent : Tokens.Color.text, size: 13)

        guard viewerIndex == nil else { return }
        drawGrid(in: context)
    }

    private static let truncating: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }()

    private static let centeredTruncating: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.alignment = .center
        return paragraph
    }()

    private func drawGrid(in context: CGContext) {
        let area = gridArea
        if let message = status ?? (isLoading ? "Cargando…" : nil) {
            (message as NSString).draw(
                in: CGRect(x: 20, y: area.midY - 10, width: area.width - 40, height: 40),
                withAttributes: [
                    .font: Tokens.sans(13),
                    .foregroundColor: Tokens.Color.textSecondary,
                    .paragraphStyle: Self.centeredTruncating,
                ]
            )
            return
        }

        context.saveGState()
        context.clip(to: area)
        for index in 0..<tileCount {
            let frame = tileFrame(index)
            guard frame.intersects(area), let item = item(at: index) else { continue }
            let shape = UIBezierPath(roundedRect: frame, cornerRadius: 6)

            if item.isDirectory {
                context.setFillColor(Tokens.Color.panelElevated.desktopCGColor)
                context.addPath(shape.cgPath)
                context.fillPath()
                drawSymbol("folder.fill", in: frame.insetBy(dx: 0, dy: 18).offsetBy(dx: 0, dy: -10),
                           color: Tokens.Color.accentAlt, size: frame.width * 0.28)
                (item.name as NSString).draw(
                    in: CGRect(x: frame.minX + 8, y: frame.maxY - 30, width: frame.width - 16, height: 18),
                    withAttributes: [
                        .font: Tokens.sans(12, weight: .medium),
                        .foregroundColor: Tokens.Color.text,
                        .paragraphStyle: Self.centeredTruncating,
                    ]
                )
            } else {
                context.saveGState()
                context.addPath(shape.cgPath)
                context.clip()
                context.setFillColor(Tokens.Color.background.desktopCGColor)
                context.fill(frame)
                if let image = thumbnail(for: item) {
                    image.draw(in: Self.aspectFill(image.size, in: frame))
                } else {
                    drawSymbol(Self.isVideo(item) ? "film" : "photo", in: frame,
                               color: Tokens.Color.textSecondary, size: 22)
                }
                if Self.isVideo(item) {
                    // Un triángulo con sombra, como en Fotos.
                    context.setShadow(offset: .zero, blur: 4, color: UIColor.black.withAlphaComponent(0.6).cgColor)
                    drawSymbol("play.fill", in: CGRect(x: frame.minX + 6, y: frame.maxY - 26, width: 20, height: 20),
                               color: .white, size: 12)
                }
                context.restoreGState()
            }

            if index == hovered, index != selected {
                context.setFillColor(UIColor.white.withAlphaComponent(0.08).cgColor)
                context.addPath(shape.cgPath)
                context.fillPath()
            }
            if index == selected {
                context.setStrokeColor(Tokens.Color.accent.desktopCGColor)
                context.setLineWidth(3)
                context.addPath(UIBezierPath(roundedRect: frame.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 5).cgPath)
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    private static func aspectFill(_ size: CGSize, in frame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return frame }
        let scale = max(frame.width / size.width, frame.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: frame.midX - fitted.width / 2, y: frame.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
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

    // MARK: - Pane

    func setFocused(_ focused: Bool) {
        layer.borderColor = (focused ? Tokens.Color.accent : Tokens.Color.border).desktopCGColor
    }

    func isDragArea(_ point: CGPoint) -> Bool {
        guard point.y < Self.headerHeight else { return false }
        for frame in [backFrame, locationFrame, slideshowFrame, gridButtonFrame]
        where frame.insetBy(dx: -4, dy: -4).contains(point) {
            return false
        }
        return WindowControls.button(at: point, x: Self.controlsX, midY: Self.controlsMidY) == nil
    }

    func handlePointer(_ event: PointerEvent) {
        let location = event.location
        switch event.kind {
        case .moved:
            let inControls = WindowControls.groupContains(location, x: Self.controlsX, midY: Self.controlsMidY)
            let hit = viewerIndex == nil ? tile(at: location) : nil
            if inControls != hoveringControls || hit != hovered {
                hoveringControls = inControls
                hovered = hit
                setNeedsDisplay()
            }
            if viewerIndex != nil {
                viewer.hover(at: convert(location, to: viewer))
            }

        case .down(let button):
            guard button == .left else { return }
            if let control = WindowControls.button(at: location, x: Self.controlsX, midY: Self.controlsMidY) {
                WindowControls.perform(control, on: self)
                return
            }
            if backFrame.insetBy(dx: -4, dy: -4).contains(location) {
                viewerIndex != nil ? closeViewer() : goUp()
                return
            }
            if gridButtonFrame != .zero, gridButtonFrame.insetBy(dx: -4, dy: -4).contains(location) {
                closeViewer()
                return
            }
            if slideshowFrame.insetBy(dx: -4, dy: -4).contains(location) {
                toggleSlideshow()
                return
            }
            if locationFrame.contains(location) {
                showLocationMenu()
                return
            }
            if viewerIndex != nil {
                switch viewer.action(at: convert(location, to: viewer)) {
                case .previous: step(-1)
                case .next: step(1)
                case .handled, .none: break
                }
                return
            }
            guard let index = tile(at: location) else { return }
            let now = Date()
            let isDouble = lastClick.map { $0.index == index && now.timeIntervalSince($0.time) < 0.5 } ?? false
            lastClick = (now, index)
            selected = index
            setNeedsDisplay()
            if isDouble {
                lastClick = nil
                open(tile: index)
            }

        case .up:
            break

        case .scroll(let delta):
            if viewerIndex == nil { scroll(by: delta.dy) }
        }
    }

    func handleKey(_ event: KeyEvent) {
        guard event.phase == .down else { return }
        let key = event.key
        let flags = key.modifierFlags

        if viewerIndex != nil {
            switch key.keyCode {
            case .keyboardLeftArrow where flags.contains(.shift): viewer.seek(by: -10)
            case .keyboardRightArrow where flags.contains(.shift): viewer.seek(by: 10)
            case .keyboardLeftArrow, .keyboardUpArrow: step(-1)
            case .keyboardRightArrow, .keyboardDownArrow: step(1)
            case .keyboardHome: openViewer(at: 0)
            case .keyboardEnd: openViewer(at: media.count - 1)
            case .keyboardSpacebar: viewer.togglePlayback()
            case .keyboardEscape, .keyboardDeleteOrBackspace, .keyboardReturnOrEnter: closeViewer()
            case .keyboardM: viewer.toggleMute()
            default: break
            }
            return
        }

        guard tileCount > 0 || key.keyCode == .keyboardDeleteOrBackspace else { return }
        let columns = gridMetrics.columns
        switch key.keyCode {
        case .keyboardUpArrow where flags.contains(.command): goUp()
        case .keyboardDownArrow where flags.contains(.command): openSelected()
        case .keyboardLeftArrow: moveSelection(by: -1)
        case .keyboardRightArrow: moveSelection(by: 1)
        case .keyboardUpArrow: moveSelection(by: -columns)
        case .keyboardDownArrow: moveSelection(by: columns)
        case .keyboardHome: moveSelection(by: -tileCount)
        case .keyboardEnd: moveSelection(by: tileCount)
        case .keyboardReturnOrEnter, .keyboardSpacebar: openSelected()
        case .keyboardDeleteOrBackspace: goUp()
        default: break
        }
    }
}

// MARK: - Visor

/// La foto o el vídeo abierto, a todo lo que da el panel, sobre negro.
///
/// La foto va en un `UIImageView` (los GIF, animados); el vídeo, en un
/// `AVPlayerLayer`, con una barra abajo que se dibuja aquí: reproducir o
/// pausar, el tiempo y la línea para saltar. Por SFTP o SMB el vídeo se ve
/// mientras llega (`MediaStreamer`), como en la vista previa de Ficheros.
@MainActor
final class PhotoViewer: UIView {

    enum Action { case previous, next, handled, none }

    /// Termina un vídeo: el pase de diapositivas pasa al siguiente.
    var onFinished: (() -> Void)?

    private let imageView = UIImageView()
    private let playerView = UIView()
    private let playerLayer = AVPlayerLayer()
    private let bar = PlayerBar()
    private let statusLabel = UILabel()

    private var player: AVPlayer?
    private var streamer: MediaStreamer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var position = ""
    private var itemName = ""

    /// Zonas de los lados para ir a la anterior o la siguiente.
    private var previousFrame: CGRect { CGRect(x: 0, y: 0, width: 70, height: bounds.height - barHeight) }
    private var nextFrame: CGRect {
        CGRect(x: bounds.width - 70, y: 0, width: 70, height: bounds.height - barHeight)
    }
    private var barHeight: CGFloat { player == nil ? 0 : PlayerBar.height }
    private var hoverSide: Action = .none

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        contentMode = .redraw

        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        playerLayer.videoGravity = .resizeAspect
        playerView.layer.addSublayer(playerLayer)
        addSubview(playerView)

        bar.isHidden = true
        addSubview(bar)

        statusLabel.font = Tokens.sans(13)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        addSubview(statusLabel)

        // Las flechas de los lados, encima de todo.
        arrows.isUserInteractionEnabled = false
        arrows.backgroundColor = .clear
        addSubview(arrows)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    private let arrows = ViewerArrows()

    func show(_ item: FileItem, from provider: any FileProvider, position: String) {
        stop()
        self.position = position
        itemName = item.name
        imageView.image = nil
        imageView.stopAnimating()
        imageView.animationImages = nil
        statusLabel.isHidden = false
        statusLabel.text = provider is LocalProvider ? "" : "Bajando…"

        let isVideo = item.type?.conforms(to: .movie) == true
        if isVideo, item.size > 0, let remote = provider as? any RangeReadableProvider {
            let streamer = MediaStreamer(provider: remote, item: item)
            if let asset = streamer.makeAsset(fileName: item.name) {
                self.streamer = streamer
                statusLabel.text = "Conectando con el servidor…"
                play(AVPlayerItem(asset: asset))
                return
            }
        }

        loadTask = Task { [weak self] in
            do {
                let url = try await provider.localURL(for: item)
                guard let self, !Task.isCancelled else { return }
                if isVideo {
                    self.play(AVPlayerItem(url: url))
                } else {
                    await self.showImage(url, name: item.name)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.statusLabel.text = error.localizedDescription
            }
        }
    }

    private func showImage(_ url: URL, name: String) async {
        let isGIF = (name as NSString).pathExtension.lowercased() == "gif"
        // A lo que da la pantalla y no más: una foto de 48 megapíxeles a
        // tamaño completo son casi 200 MB de memoria.
        let pixels = max(bounds.width, bounds.height) * layer.contentsScale * 1.5
        let decoded: (UIImage?, [UIImage], TimeInterval) = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (nil, [], 0) }
            if isGIF, CGImageSourceGetCount(source) > 1 {
                var frames: [UIImage] = []
                var total: TimeInterval = 0
                for index in 0..<CGImageSourceGetCount(source) {
                    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
                    frames.append(UIImage(cgImage: image))
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                    let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                        ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                    total += delay < 0.011 ? 0.1 : delay
                }
                return (nil, frames, total)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return (nil, [], 0)
            }
            return (UIImage(cgImage: image), [], 0)
        }.value

        guard itemName == name else { return }
        let (image, frames, duration) = decoded
        if !frames.isEmpty {
            imageView.animationImages = frames
            imageView.animationDuration = duration
            imageView.startAnimating()
        } else if let image {
            imageView.image = image
        } else {
            statusLabel.text = "No se pudo abrir la imagen."
            return
        }
        statusLabel.isHidden = true
    }

    private func play(_ playerItem: AVPlayerItem) {
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        playerLayer.player = player
        bar.isHidden = false
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBar() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinished?() }
        }
        player.play()
        setNeedsLayout()
    }

    private func refreshBar() {
        guard let player, let item = player.currentItem else { return }
        let current = player.currentTime().seconds
        let duration = item.duration.seconds
        if current > 0 { statusLabel.isHidden = true }
        bar.update(
            isPlaying: player.timeControlStatus != .paused,
            isMuted: player.isMuted,
            current: current.isFinite ? current : 0,
            duration: duration.isFinite ? duration : 0
        )
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        streamer?.cancelAll()
        streamer = nil
        player = nil
        playerLayer.player = nil
        bar.isHidden = true
        imageView.stopAnimating()
    }

    func togglePlayback() {
        guard let player else { return }
        player.timeControlStatus == .paused ? player.play() : player.pause()
        refreshBar()
    }

    func toggleMute() {
        player?.isMuted.toggle()
        refreshBar()
    }

    func seek(by seconds: Double) {
        guard let player else { return }
        let target = max(0, player.currentTime().seconds + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func hover(at point: CGPoint) {
        let side: Action = previousFrame.contains(point) ? .previous : nextFrame.contains(point) ? .next : .none
        guard side != hoverSide else { return }
        hoverSide = side
        arrows.highlighted = side
    }

    /// Qué hace un clic: los lados pasan de foto; la barra del vídeo, lo suyo;
    /// sobre el vídeo, pausa y sigue.
    func action(at point: CGPoint) -> Action {
        if player != nil, bar.frame.contains(point) {
            switch bar.hit(at: convert(point, to: bar)) {
            case .playPause: togglePlayback()
            case .mute: toggleMute()
            case .seek(let fraction):
                if let player, let duration = player.currentItem?.duration.seconds, duration.isFinite {
                    player.seek(to: CMTime(seconds: duration * fraction, preferredTimescale: 600))
                }
            case .none: break
            }
            return .handled
        }
        if previousFrame.contains(point) { return .previous }
        if nextFrame.contains(point) { return .next }
        if player != nil {
            togglePlayback()
            return .handled
        }
        return .none
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
        imageView.frame = content
        playerView.frame = content
        playerLayer.frame = playerView.bounds
        statusLabel.frame = content.insetBy(dx: 30, dy: 0)
        bar.frame = CGRect(x: 0, y: bounds.height - PlayerBar.height, width: bounds.width, height: PlayerBar.height)
        arrows.frame = content
        arrows.position = position
    }
}

/// Las flechas de los lados del visor y el «3 de 42» de arriba.
@MainActor
final class ViewerArrows: UIView {

    var highlighted: PhotoViewer.Action = .none {
        didSet { setNeedsDisplay() }
    }

    var position = "" {
        didSet { if position != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    override func draw(_ rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.mono(11),
            .foregroundColor: UIColor.white.withAlphaComponent(0.7),
        ]
        let size = (position as NSString).size(withAttributes: attributes)
        (position as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: 10), withAttributes: attributes)

        let sides: [(PhotoViewer.Action, String, CGFloat)] = [
            (.previous, "chevron.left", 35),
            (.next, "chevron.right", bounds.width - 35),
        ]
        for (action, symbol, x) in sides {
            let alpha: CGFloat = highlighted == action ? 0.9 : 0.25
            let configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
            guard let image = UIImage.crispSymbol(symbol, configuration: configuration, scale: layer.contentsScale)?
                .withTintColor(UIColor.white.withAlphaComponent(alpha), renderingMode: .alwaysOriginal)
            else { continue }
            image.draw(at: CGPoint(x: x - image.size.width / 2, y: bounds.midY - image.size.height / 2))
        }
    }
}

/// La barra del reproductor: reproducir/pausa, tiempo, línea y sonido.
@MainActor
final class PlayerBar: UIView {

    static let height: CGFloat = 40

    enum Hit { case playPause, mute, seek(Double), none }

    private var isPlaying = false
    private var isMuted = false
    private var current: Double = 0
    private var duration: Double = 0

    private var playFrame: CGRect { CGRect(x: 8, y: 7, width: 26, height: 26) }
    private var muteFrame: CGRect { CGRect(x: bounds.width - 34, y: 7, width: 26, height: 26) }
    private var timelineFrame: CGRect {
        CGRect(x: 150, y: bounds.midY - 3, width: max(0, muteFrame.minX - 160), height: 6)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    func update(isPlaying: Bool, isMuted: Bool, current: Double, duration: Double) {
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.current = current
        self.duration = duration
        setNeedsDisplay()
    }

    func hit(at point: CGPoint) -> Hit {
        if playFrame.insetBy(dx: -4, dy: -4).contains(point) { return .playPause }
        if muteFrame.insetBy(dx: -4, dy: -4).contains(point) { return .mute }
        let line = timelineFrame.insetBy(dx: 0, dy: -10)
        if line.contains(point), timelineFrame.width > 0 {
            return .seek(min(max(0, (point.x - timelineFrame.minX) / timelineFrame.width), 1))
        }
        return .none
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawSymbol(isPlaying ? "pause.fill" : "play.fill", in: playFrame)
        drawSymbol(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", in: muteFrame)

        let time = "\(Self.format(current)) / \(Self.format(duration))" as NSString
        time.draw(
            at: CGPoint(x: playFrame.maxX + 10, y: bounds.midY - 7),
            withAttributes: [.font: Tokens.mono(11), .foregroundColor: UIColor.white.withAlphaComponent(0.8)]
        )

        let line = timelineFrame
        context.setFillColor(UIColor.white.withAlphaComponent(0.2).cgColor)
        context.addPath(UIBezierPath(roundedRect: line, cornerRadius: 3).cgPath)
        context.fillPath()
        if duration > 0 {
            let progress = line.width * min(max(current / duration, 0), 1)
            context.setFillColor(Tokens.Color.accent.desktopCGColor)
            context.addPath(UIBezierPath(roundedRect: CGRect(x: line.minX, y: line.minY, width: progress,
                                                             height: line.height), cornerRadius: 3).cgPath)
            context.fillPath()
        }
    }

    private func drawSymbol(_ name: String, in frame: CGRect) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let image = UIImage.crispSymbol(name, configuration: configuration, scale: layer.contentsScale)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        else { return }
        image.draw(at: CGPoint(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2))
    }
}

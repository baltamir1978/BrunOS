import PDFKit
import UIKit

/// Las páginas de un PDF, una debajo de otra, **dibujadas por BrunOS** a la
/// densidad exacta del monitor.
///
/// Con `PDFView` no salía nítido (Bruno, 24-sep-2026): PDFKit decide a qué
/// resolución pinta sus trozos, y dentro de un lienzo escalado no acertaba.
/// Aquí cada página se dibuja con `PDFPage.draw(with:to:)` a los píxeles que
/// ocupa de verdad (ancho visible × `contentsScale`), y se guarda ya pintada
/// hasta que cambia el ancho o el zoom.
@MainActor
final class PDFPagesView: UIView {

    private let document: PDFDocument
    /// Cuánto se ha bajado, en puntos.
    private var offset: CGFloat = 0
    /// Cuánto se ha movido a los lados, con zoom de más del ancho.
    private var offsetX: CGFloat = 0
    /// 1 es el ancho de la vista; Cmd + / − lo cambian.
    private(set) var zoom: CGFloat = 1
    /// Páginas ya dibujadas, para el ancho con que se dibujaron.
    private var rendered: [Int: UIImage] = [:]
    private var renderedWidth: CGFloat = 0
    private var renderedScale: CGFloat = 0

    private static let gap: CGFloat = 12
    private static let margin: CGFloat = 12

    /// Avisa al cambiar la página que se ve, para la cabecera.
    var onPageChange: ((Int, Int) -> Void)?
    private var lastReportedPage = -1

    init(document: PDFDocument) {
        self.document = document
        super.init(frame: .zero)
        backgroundColor = Tokens.Color.background
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    var pageCount: Int { document.pageCount }

    // MARK: - Geometría

    private var pageWidth: CGFloat {
        max(50, (bounds.width - 2 * Self.margin) * zoom)
    }

    /// El tamaño de una página en pantalla, con su proporción.
    private func size(of index: Int) -> CGSize {
        guard let page = document.page(at: index) else { return .zero }
        let box = page.bounds(for: .mediaBox)
        // Una página girada se ve con el ancho y el alto cambiados.
        let rotated = page.rotation % 180 != 0
        let width = rotated ? box.height : box.width
        let height = rotated ? box.width : box.height
        guard width > 0 else { return .zero }
        return CGSize(width: pageWidth, height: pageWidth * height / width)
    }

    /// Dónde empieza cada página, desde arriba del todo.
    private func top(of index: Int) -> CGFloat {
        var y = Self.margin
        for i in 0..<index { y += size(of: i).height + Self.gap }
        return y
    }

    private var contentHeight: CGFloat {
        top(of: document.pageCount) - Self.gap + Self.margin
    }

    private var maxOffset: CGFloat { max(0, contentHeight - bounds.height) }

    /// La página que ocupa el centro de la vista.
    var currentPage: Int {
        let middle = offset + bounds.height / 2
        var y = Self.margin
        for index in 0..<document.pageCount {
            let height = size(of: index).height
            if middle < y + height + Self.gap { return index }
            y += height + Self.gap
        }
        return max(0, document.pageCount - 1)
    }

    // MARK: - Moverse

    func scroll(by delta: CGFloat, horizontally deltaX: CGFloat = 0) {
        offset = min(max(offset - delta, 0), maxOffset)
        offsetX = min(max(offsetX - deltaX, -maxOffsetX), maxOffsetX)
        changed()
    }

    /// Con zoom, lo que la página se sale por cada lado.
    private var maxOffsetX: CGFloat {
        max(0, (pageWidth + 2 * Self.margin - bounds.width) / 2)
    }

    func go(toPage index: Int) {
        let clamped = min(max(index, 0), document.pageCount - 1)
        offset = min(max(top(of: clamped) - Self.margin, 0), maxOffset)
        changed()
    }

    func setZoom(_ value: CGFloat) {
        let page = currentPage
        zoom = min(max(value, 0.25), 6)
        go(toPage: page)
    }

    private func changed() {
        offset = min(offset, maxOffset)
        offsetX = min(max(offsetX, -maxOffsetX), maxOffsetX)
        setNeedsDisplay()
        let page = currentPage
        if page != lastReportedPage {
            lastReportedPage = page
            onPageChange?(page + 1, document.pageCount)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        changed()
    }

    // MARK: - Dibujo

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(Tokens.Color.background.desktopCGColor)
        context.fill(bounds)

        // Otro ancho u otra densidad (el escritorio la pone al colgar la
        // vista, a veces después del primer dibujo): se vuelve a pintar.
        let width = pageWidth
        if width != renderedWidth || layer.contentsScale != renderedScale {
            rendered.removeAll()
            renderedWidth = width
            renderedScale = layer.contentsScale
        }

        var y = Self.margin - offset
        for index in 0..<document.pageCount {
            let pageSize = size(of: index)
            defer { y += pageSize.height + Self.gap }
            guard y + pageSize.height > 0 else { continue }
            if y > bounds.height { break }

            let frame = CGRect(x: (bounds.width - pageSize.width) / 2 - offsetX, y: y,
                               width: pageSize.width, height: pageSize.height)
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6,
                              color: UIColor.black.withAlphaComponent(0.25).cgColor)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(frame)
            context.setShadow(offset: .zero, blur: 0)
            image(for: index, size: pageSize)?.draw(in: frame)
        }
        trimCache()
    }

    /// La página dibujada a los píxeles que ocupa de verdad.
    private func image(for index: Int, size: CGSize) -> UIImage? {
        if let cached = rendered[index] { return cached }
        guard let page = document.page(at: index), size.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(layer.contentsScale, 1)
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // PDF va con el origen abajo: se da la vuelta y se escala la caja
            // de la página al tamaño en pantalla.
            let box = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let boxWidth = rotated ? box.height : box.width
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: size.width / boxWidth, y: -size.width / boxWidth)
            page.draw(with: .mediaBox, to: context)
        }
        rendered[index] = image
        return image
    }

    /// Sólo se guardan las páginas cerca de la que se ve: un PDF de 300
    /// páginas dibujadas a 4K no cabe en memoria.
    private func trimCache() {
        let current = currentPage
        for index in rendered.keys where abs(index - current) > 4 {
            rendered[index] = nil
        }
    }
}

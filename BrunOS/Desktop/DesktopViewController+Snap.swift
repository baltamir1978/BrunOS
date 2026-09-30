import UIKit

// Sacado de `DesktopViewController`, que pasaba de 2.600 líneas (punto 4 de la
// 0.2.0). Las propiedades con estado siguen allí: una extensión no puede
// guardarlas.

// MARK: - Encajar ventanas

extension DesktopViewController {

    /// Adónde va una ventana soltada en un borde, como en macOS y Windows:
    /// a media pantalla en los lados, a un cuarto en las esquinas y a toda
    /// arriba. Bruno pidió mitades y cuartos (24-sep-2026).
    enum Snap {
        case left, right, full
        case topLeft, topRight, bottomLeft, bottomRight
    }


    /// El cursor no sale del escritorio, así que «en el borde» es tocarlo.
    ///
    /// Las esquinas son generosas (120 puntos a lo largo del borde): acertar
    /// el píxel exacto de una esquina con un ratón es imposible. Eran 80, y
    /// con el ratón que no llegaba al 6 % de arriba del monitor (unos 86
    /// puntos), las esquinas de arriba eran inalcanzables.
    func snapTarget(at position: CGPoint) -> Snap? {
        let edge: CGFloat = 3
        let corner: CGFloat = 120
        let atLeft = position.x <= edge
        let atRight = position.x >= logicalSize.width - 1 - edge
        let atTop = position.y <= edge
        let atBottom = position.y >= logicalSize.height - 1 - edge
        let nearTop = position.y <= corner
        let nearBottom = position.y >= logicalSize.height - corner
        let nearLeft = position.x <= corner
        let nearRight = position.x >= logicalSize.width - corner

        if (atLeft && nearTop) || (atTop && nearLeft) { return .topLeft }
        if (atRight && nearTop) || (atTop && nearRight) { return .topRight }
        if (atLeft && nearBottom) || (atBottom && nearLeft) { return .bottomLeft }
        if (atRight && nearBottom) || (atBottom && nearRight) { return .bottomRight }
        if atLeft { return .left }
        if atRight { return .right }
        if atTop { return .full }
        return nil
    }

    func snapFrame(_ snap: Snap) -> CGRect {
        // Hasta abajo del todo: el dock se aparta (ver `dockIsCovered`).
        var area = tileArea
        area.size.height = logicalSize.height - Tokens.Metric.tileGap / 2 - area.minY
        let gap = Tokens.Metric.tileGap
        let half = (area.width - gap) / 2
        let halfHeight = (area.height - gap) / 2
        let left = area.minX
        let right = area.maxX - half
        let top = area.minY
        let bottom = area.maxY - halfHeight
        return switch snap {
        case .left: CGRect(x: left, y: top, width: half, height: area.height)
        case .right: CGRect(x: right, y: top, width: half, height: area.height)
        case .full: area
        case .topLeft: CGRect(x: left, y: top, width: half, height: halfHeight)
        case .topRight: CGRect(x: right, y: top, width: half, height: halfHeight)
        case .bottomLeft: CGRect(x: left, y: bottom, width: half, height: halfHeight)
        case .bottomRight: CGRect(x: right, y: bottom, width: half, height: halfHeight)
        }
    }

    /// Al encajar una ventana, las que ya estaban encajadas donde cae le
    /// hacen sitio, como en Windows: con dos mitades, soltar una tercera en
    /// una esquina deja la de esa mitad en el cuarto que queda (Bruno,
    /// 24-sep-2026). Una a pantalla entera pasa a la otra mitad. Sólo se tocan
    /// las que están exactamente encajadas; las colocadas a mano se respetan.
    func makeRoom(for snap: Snap, placed id: PaneID) {
        let workspace = services.desktop.active
        let area = snapFrame(.full)
        /// Dónde está encajada una ventana, **con tolerancia**: la primera
        /// versión exigía el marco exacto, y en cuanto se redimensionaba una
        /// mitad junto a la otra, o venía de una sesión con el hueco de antes,
        /// ya no la reconocía y no hacía sitio (Bruno, 24-sep-2026). Cuenta
        /// como mitad la que está pegada a ese lado, ocupa casi todo el alto y
        /// no llega a tres cuartos del ancho; como entera, la que ocupa casi
        /// todo.
        func snapped(_ frame: CGRect) -> Snap? {
            let edge: CGFloat = 24
            let tall = frame.height >= area.height * 0.85
            let wide = frame.width >= area.width * 0.85
            if tall, wide { return .full }
            guard tall, frame.width <= area.width * 0.75 else { return nil }
            if abs(frame.minX - area.minX) <= edge { return .left }
            if abs(frame.maxX - area.maxX) <= edge { return .right }
            return nil
        }
        for (other, frame) in workspace.floating where other != id {
            guard let current = snapped(frame) else { continue }
            let next: Snap? = switch (snap, current) {
            case (.topLeft, .left): .bottomLeft
            case (.bottomLeft, .left): .topLeft
            case (.topRight, .right): .bottomRight
            case (.bottomRight, .right): .topRight
            case (.left, .full): .right
            case (.right, .full): .left
            default: nil
            }
            guard let next else { continue }
            if zoomRestore[other] == nil { zoomRestore[other] = frame }
            workspace.setFloatingFrame(other, snapFrame(next))
        }
    }

    /// El hueco donde va a quedar, detrás de la ventana que se arrastra.
    func updateSnapPreview(_ snap: Snap?, below window: UIView?) {
        guard let snap else {
            if let preview = snapPreview {
                snapPreview = nil
                UIView.animate(withDuration: 0.12, animations: { preview.alpha = 0 }) { _ in
                    preview.removeFromSuperview()
                }
            }
            return
        }
        let frame = snapFrame(snap)
        if let preview = snapPreview {
            guard preview.frame != frame else { return }
            UIView.animate(withDuration: 0.15) { preview.frame = frame }
            return
        }
        let preview = UIView(frame: frame.insetBy(dx: frame.width * 0.05, dy: frame.height * 0.05))
        preview.backgroundColor = Tokens.Color.accent.withAlphaComponent(0.14)
        preview.layer.cornerRadius = Tokens.Metric.paneCornerRadius
        preview.layer.borderWidth = 1.5
        preview.setThemedBorder(Tokens.Color.accent.withAlphaComponent(0.6))
        preview.isUserInteractionEnabled = false
        preview.alpha = 0
        if let window, window.superview === canvas {
            canvas.insertSubview(preview, belowSubview: window)
        } else {
            canvas.addSubview(preview)
        }
        snapPreview = preview
        UIView.animate(withDuration: 0.15) {
            preview.alpha = 1
            preview.frame = frame
        }
    }


    /// Maximizar una flotante: ocupa el área del mosaico, o la pantalla entera
    /// con `fullScreen`. Si ya lo estaba, vuelve a su tamaño.
    func toggleZoom(_ id: PaneID, fullScreen: Bool) {
        let workspace = services.desktop.active
        guard let frame = workspace.floating[id] else { return }
        if let previous = zoomRestore[id] {
            zoomRestore[id] = nil
            workspace.setFloatingFrame(id, previous)
        } else {
            zoomRestore[id] = frame
            workspace.setFloatingFrame(id, fullScreen ? CGRect(origin: .zero, size: logicalSize) : tileArea)
        }
    }
}
